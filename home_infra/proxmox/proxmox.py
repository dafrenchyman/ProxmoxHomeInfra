import json
import os
import re

import pulumi
import pulumi_command
import pulumi_tls
from pulumi import Output

from home_infra.utils.pulumi_extras import PulumiExtras
from pulumi_mrsharky.proxmox.get_ip_of_vm import GetIpOfVm, GetIpOfVmArgs
from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnectionArgs
from pulumi_mrsharky.proxmox.start_vm import StartVm, StartVmArgs
from pulumi_mrsharky.remote import RunCommandsOnHost
from pulumi_mrsharky.remote.save_file_on_remote_host import SaveFileOnRemoteHost

IOMMU_GRUB = {
    "intel": "quiet intel_iommu=on iommu=pt",
    "amd": "quiet amd_iommu=on iommu=pt",
}

# GPU VFIO (whitespace matters)
GPU_VFIO = {
    "amd": """softdep radeon pre: vfio-pci
softdep amdgpu pre: vfio-pci""",
    "intel": """softdep snd_hda_intel pre: vfio-pci
softdep snd_hda_codec_hdmi pre: vfio-pci
softdep i915 pre: vfio-pci""",
    "nvidia": """softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidiafb pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
softdep drm pre: vfio-pci""",
}
# GPU Blaclist (whitespace matters)
GPU_BLACKLIST = {
    "amd": """blacklist radeon
blacklist amdgpu""",
    "nvidia": """blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm""",
    "intel": """snd_hda_intel
snd_hda_codec_hdmi
i915""",
}


class Proxmox:
    def __init__(
        self,
        proxmox_ip: str,
        proxmox_pass: str,
        cpu: str = "intel",
        gpu: str = "nvidia",
    ) -> None:
        """
        Sources:
        - https://forum.proxmox.com/threads/pci-gpu-passthrough-on-proxmox-ve-8-installation-and-configuration.130218/
        - https://www.youtube.com/watch?v=4G9d5COhOvI&t=19s
        - https://registry.terraform.io/providers/bpg/proxmox/latest/docs
        :param proxmox_ip:
        :param proxmox_pass:
        """
        self.cpu = cpu
        self.gpu = gpu
        self.proxmox_ip = proxmox_ip
        self.proxmox_pass = proxmox_pass
        self.current_path = os.path.dirname(os.path.abspath(__file__))

        #
        self.proxmox_private_key_file = "~/.ssh/proxmox_private_key.pem"
        return

    def run(self) -> None:
        # Create a new TLS private key
        self.private_key = pulumi_tls.PrivateKey(
            resource_name="proxmoxPrivateKey", algorithm="RSA", rsa_bits=4096
        )

        # Save the private key to temporary file
        self.private_key.private_key_pem.apply(
            lambda private_key_pem: Proxmox.text_to_file(
                text=private_key_pem, filename=self.proxmox_private_key_file
            )
        )

        # Export the private key and public key
        pulumi.export("private_key", self.private_key.private_key_pem)
        pulumi.export("public_key", self.private_key.public_key_openssh)

        # Remove Enterprise Repo
        self._remove_enterprise_repo()

        # Setup pulumi user
        self._setup_pulumi_user()

        # Setup IOMMU for GPU Passthrough
        self._setup_iommu()

        # Setup API Token
        self._setup_api_token()

        # Setup Ubuntu Cloud Init image
        self._create_ubuntu_cloud_init_images()

        # Setup Nixos Cloud Init image
        self._create_nixos_cloud_init_images()

        self._create_nixos_samba_server()

        return

    def _remove_enterprise_repo(self) -> None:
        self.remove_enterprise_repo = PulumiExtras.run_command_on_remote_host(
            resource_name="ProxmoxRemoveEnterpriseRepo",
            connection=pulumi_command.remote.ConnectionArgs(
                host=self.proxmox_ip,
                port=22,
                user="root",
                password=self.proxmox_pass,
            ),
            create=(
                "sed -i 's/deb https/# deb https/g' /etc/apt/sources.list.d/pve-enterprise.list && "
                "sed -i 's/deb https/# deb https/g' /etc/apt/sources.list.d/ceph.list "
            ),
            delete=(
                "sed -i 's/# deb https/deb https/g' /etc/apt/sources.list.d/pve-enterprise.list && "
                "sed -i 's/# deb https/deb https/g' /etc/apt/sources.list.d/ceph.list "
            ),
        )
        return

    def _setup_pulumi_user(self) -> None:
        proxmox_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user="root",
            password=self.proxmox_pass,
        )

        # Install sudo
        self.install_sudo = PulumiExtras.run_command_on_remote_host(
            resource_name="ProxmoxInstallSudo",
            connection=proxmox_connection,
            create="apt-get update && apt-get install -y sudo",
            delete="apt-get purge -y sudo",
            opts=pulumi.ResourceOptions(
                depends_on=[self.remove_enterprise_repo, self.private_key]
            ),
        )

        # Create the pulumi user
        self.create_pulumi_user = PulumiExtras.run_command_on_remote_host(
            resource_name="ProxmoxCreatePulumiUser",
            connection=proxmox_connection,
            create="useradd --create-home -s /bin/bash pulumi",
            delete="userdel --remove pulumi",
            opts=pulumi.ResourceOptions(
                depends_on=[self.private_key, self.install_sudo]
            ),
        )

        # Add ssh key
        self.add_pulumi_ssh_key = PulumiExtras.run_command_on_remote_host(
            resource_name="ProxmoxAddSshKeyForPulumiUser",
            connection=proxmox_connection,
            create=self.private_key.public_key_openssh.apply(
                lambda key: (
                    "mkdir -p /home/pulumi/.ssh/ && "
                    f"echo '{key}' >> /home/pulumi/.ssh/authorized_keys"
                )
            ),
            # TODO: Come up with good delete
            delete=None,
            opts=pulumi.ResourceOptions(
                depends_on=[self.private_key, self.create_pulumi_user]
            ),
        )

        # Add pulumi to sudo
        self.add_pulumi_to_sudo = PulumiExtras.run_command_on_remote_host(
            resource_name="ProxmoxAddPulumiToSudo",
            connection=proxmox_connection,
            create=(
                "mkdir -p /etc/sudoers.d/ && "
                "echo 'pulumi ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/pulumi && "
                "chown root:root /etc/sudoers.d/pulumi && "
                "chmod 440 /etc/sudoers.d/pulumi"
            ),
            delete=("rm /etc/sudoers.d/pulumi"),
            opts=pulumi.ResourceOptions(
                depends_on=[self.private_key, self.add_pulumi_ssh_key]
            ),
        )

        # Reboot
        self.reboot_after_sudo = PulumiExtras.reboot_remote_host(
            resource_name="ProxmoxRebootAfterSudo",
            connection=proxmox_connection,
            opts=pulumi.ResourceOptions(
                depends_on=[self.private_key, self.add_pulumi_to_sudo],
            ),
        )
        return

    def _setup_iommu(self) -> None:
        pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user="pulumi",
            private_key=self.private_key.private_key_pem,
        )

        # Get pci_ids
        self.get_gpu_pci_ids = pulumi_command.remote.Command(
            resource_name="proxmoxGetGpuIds",
            connection=pulumi_connection,
            create="lspci -nn",
            opts=pulumi.ResourceOptions(
                depends_on=[
                    self.add_pulumi_ssh_key,
                    self.reboot_after_sudo,
                    self.private_key,
                ]
            ),
        )

        pulumi.export(
            "gpu_pci_id",
            self.get_gpu_pci_ids.stdout.apply(
                lambda stdout: Proxmox.pci_ids_reg_ex(stdout)
            ),
        )

        """
        root@pve:~# efibootmgr -v
        EFI variables are not supported on this system.
        """

        # Modify grub command line
        self.modify_grub = PulumiExtras.run_command_on_remote_host(
            resource_name="proxmoxModifyGrub",
            connection=pulumi_connection,
            create=(
                r"sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/"
                rf"c\GRUB_CMDLINE_LINUX_DEFAULT=\"{IOMMU_GRUB[self.cpu]}\"' /etc/default/grub && "
                "sudo chmod 644 /etc/default/grub && "
                "sudo update-grub && "
                "sudo update-initramfs -u -k all"
            ),
            delete=(
                r"sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/"
                r"c\GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"' /etc/default/grub && "
                "sudo chmod 644 /etc/default/grub && "
                "sudo update-grub && "
                "sudo update-initramfs -u -k all"
            ),
            opts=pulumi.ResourceOptions(
                depends_on=[
                    self.add_pulumi_ssh_key,
                    self.reboot_after_sudo,
                    self.private_key,
                ]
            ),
        )

        # Reboot
        self.reboot_after_grub = PulumiExtras.reboot_remote_host(
            resource_name="ProxmoxRebootAfterGrub",
            connection=pulumi_connection,
            seconds_to_wait_for_reboot=140,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.modify_grub,
                depends_on=[],
            ),
        )

        # Add vfio modules
        self.add_vfio_conf = PulumiExtras.save_file_on_remote_host(
            resource_name="proxmoxCreateVfioConf",
            connection=pulumi_connection,
            file_contents="vfio\nvfio_iommu_type1\nvfio_pci",
            file_location="/etc/modules-load.d/vfio.conf",
            use_sudo=True,
            opts=pulumi.ResourceOptions(parent=self.reboot_after_grub, depends_on=[]),
        )

        self.gpu_vfio_update_initramfs = PulumiExtras.run_command_on_remote_host(
            resource_name="proxmoxGpuVfioUpdateInitramfs",
            connection=pulumi_connection,
            create="sudo update-initramfs -u -k all",
            delete="sudo update-initramfs -u -k all",
            opts=pulumi.ResourceOptions(parent=self.add_vfio_conf, depends_on=[]),
        )

        # Reboot
        self.reboot_after_gpu_vfio = PulumiExtras.reboot_remote_host(
            resource_name="ProxmoxRebootAfterGpuVfio",
            connection=pulumi_connection,
            use_sudo=True,
            seconds_to_wait_for_reboot=140,
            opts=pulumi.ResourceOptions(
                parent=self.gpu_vfio_update_initramfs,
                depends_on=[],
            ),
        )

        if self.gpu == "nvidia":
            self.kvm_modulesPulumiExtras = PulumiExtras.save_file_on_remote_host(
                resource_name="proxmoxCreateNvidiaKvmModulesConf",
                connection=pulumi_connection,
                file_contents="options kvm ignore_msrs=1 report_ignored_msrs=0",
                file_location="/etc/modprobe.d/kvm.conf",
                use_sudo=True,
                opts=pulumi.ResourceOptions(
                    parent=self.reboot_after_gpu_vfio, depends_on=[]
                ),
            )

        # Isolate GPU
        blacklist = False
        if blacklist:
            file_contents = pulumi.Output.all(
                gpu_ids=self.get_gpu_pci_ids.stdout.apply(
                    lambda stdout: Proxmox.pci_ids_reg_ex(stdout)
                ),
                gpu_vfio=GPU_BLACKLIST[self.gpu],
            ).apply(
                lambda args: (
                    f"options vfio-pci ids={args['gpu_ids']}\n{args['gpu_vfio']} "
                )
            )
            self.isolate_gpu = PulumiExtras.save_file_on_remote_host(
                resource_name="proxmoxBlacklistGpu",
                connection=pulumi_connection,
                file_contents=file_contents,
                file_location="/etc/modprobe.d/blacklist.conf",
                use_sudo=True,
                opts=pulumi.ResourceOptions(
                    depends_on=[
                        self.get_gpu_pci_ids,
                        self.reboot_after_gpu_vfio,
                    ]
                ),
            )
        else:
            file_contents = pulumi.Output.all(
                gpu_ids=self.get_gpu_pci_ids.stdout.apply(
                    lambda stdout: Proxmox.pci_ids_reg_ex(stdout)
                ),
                gpu_vfio=GPU_VFIO[self.gpu],
            ).apply(
                lambda args: (
                    f"options vfio-pci ids={args['gpu_ids']}\n{args['gpu_vfio']} "
                )
            )
            self.isolate_gpu = PulumiExtras.save_file_on_remote_host(
                resource_name="proxmoxCreateModprobVfioConf",
                connection=pulumi_connection,
                file_contents=file_contents,
                file_location="/etc/modprobe.d/vfio.conf",
                use_sudo=True,
                opts=pulumi.ResourceOptions(
                    depends_on=[
                        self.get_gpu_pci_ids,
                        self.reboot_after_gpu_vfio,
                    ]
                ),
            )

        # Reboot
        self.reboot_after_isolating_gpu = PulumiExtras.reboot_remote_host(
            resource_name="ProxmoxRebootAfterGpuIsolated",
            connection=pulumi_connection,
            seconds_to_wait_for_reboot=140,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.isolate_gpu,
                depends_on=[],
            ),
        )

        return

    def _setup_api_token(self) -> None:
        pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user="pulumi",
            private_key=self.private_key.private_key_pem,
        )

        # Add a pulumi user
        self.create_api_user = PulumiExtras.run_command_on_remote_host(
            resource_name="proxmoxCreatePulumiApiUser",
            connection=pulumi_connection,
            create=(
                "sudo pveum user add pulumi@pve && "
                "sudo pveum aclmod / -user pulumi@pve -role Administrator"
            ),
            delete="sudo pveum user delete pulumi@pve",
            opts=pulumi.ResourceOptions(
                parent=self.reboot_after_isolating_gpu, depends_on=[]
            ),
        )

        # Create token

        self.create_token = PulumiExtras.run_command_on_remote_host(
            resource_name="proxmoxCreatePulumiApiToken",
            connection=pulumi_connection,
            create=(
                "sudo pveum user token add pulumi@pve provider --privsep=0 --expire 0 --output-format json"
            ),
            delete="sudo pveum user token remove pulumi@pve provider",
            opts=pulumi.ResourceOptions(parent=self.create_api_user, depends_on=[]),
        )
        self.pulumi_api_token = Proxmox.get_api_token(self.create_token.stdout)

        pulumi.export("API_TOKEN_2", self.pulumi_api_token)

        return

    def _create_ubuntu_cloud_init_images(self):
        pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user="pulumi",
            private_key=self.private_key.private_key_pem,
        )

        script = [
            "wget https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img",
            "qm create 9000 --memory 2048 --core 2 --name ubuntu-cloud-jammy-kvm --net0 virtio,bridge=vmbr0",
            "qm importdisk 9000 jammy-server-cloudimg-amd64-disk-kvm.img local-lvm",
            "qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0",
            "qm set 9000 --ide2 local-lvm:cloudinit",
            "qm set 9000 --boot c --bootdisk scsi0",
            "qm set 9000 --serial0 socket --vga serial0",
            "qm set 9000 --ipconfig0 ip=dhcp",
            "qm template 9000",
        ]

        self.create_ubuntu_cloud_init_images = RunCommandsOnHost(
            resource_name="proxmoxCreateUbuntuCloudInitImages",
            connection=pulumi_connection,
            create=script,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                depends_on=[
                    self.reboot_after_isolating_gpu,
                ]
            ),
        )

    def _create_nixos_cloud_init_images(self):
        pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user="pulumi",
            private_key=self.private_key.private_key_pem,
        )

        if True:
            script = [
                "sudo wget https://mrsharky.com/extras/nixos-23.11-cloud-init.img",
                "sudo qm create 9001 --memory 2048 --core 2 --name nixos-23.11-kvm --net0 virtio,bridge=vmbr0",
                "sudo qm importdisk 9001 nixos-23.11-cloud-init.img local-lvm",
                "sudo qm set 9001 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9001-disk-0",
                "sudo qm set 9001 --ide2 local-lvm:cloudinit",
                "sudo qm set 9001 --boot c --bootdisk scsi0",
                "sudo qm set 9001 --serial0 socket --vga serial0",
                "sudo qm set 9001 --ipconfig0 ip=dhcp",
                "sudo qm template 9001",
            ]

            script = " && ".join(script)
            self.create_nixos_cloud_init_image = (
                PulumiExtras.run_command_on_remote_host(
                    resource_name="proxmoxCreateNixosCloudInitImages",
                    connection=pulumi_connection,
                    create=script,
                    opts=pulumi.ResourceOptions(
                        depends_on=[
                            self.reboot_after_isolating_gpu,
                        ]
                    ),
                )
            )
        else:
            script = [
                "wget https://mrsharky.com/extras/nixos-23.11-cloud-init.img",
                "qm create 9001 --memory 2048 --core 2 --name nixos-23.11-kvm --net0 virtio,bridge=vmbr0",
                "qm importdisk 9001 nixos-23.11-cloud-init.img local-lvm",
                "qm set 9001 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9001-disk-0",
                "qm set 9001 --ide2 local-lvm:cloudinit",
                "qm set 9001 --boot c --bootdisk scsi0",
                "qm set 9001 --serial0 socket --vga serial0",
                "qm set 9001 --ipconfig0 ip=dhcp",
                "qm template 9001",
            ]

            self.create_nixos_cloud_init_image = RunCommandsOnHost(
                resource_name="proxmoxCreateNixosCloudInitImages",
                connection=pulumi_connection,
                create=script,
                use_sudo=True,
                opts=pulumi.ResourceOptions(
                    depends_on=[
                        self.reboot_after_isolating_gpu,
                    ]
                ),
            )

    def _create_nixos_samba_server(
        self,
        memory: int = 16384,
        cpu_cores: int = 4,
        disk_space_in_gb: int = 1000,
        vm_id: int = 300,
    ):
        pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user="pulumi",
            private_key=self.private_key.private_key_pem,
        )

        # Save file with private key on proxmox for use into this image
        key_path = "/home/pulumi/proxmox_key.pem"
        save_key = SaveFileOnRemoteHost(
            resource_name="nixos_ssh_key",
            connection=pulumi_connection,
            file_contents=self.private_key.public_key_openssh,
            file_location=key_path,
            opts=pulumi.ResourceOptions(
                parent=self.create_nixos_cloud_init_image,
                depends_on=[
                    self.create_nixos_cloud_init_image,
                    self.reboot_after_isolating_gpu,
                ],
            ),
        )

        script = [
            # Clone the nixos template
            f'qm clone 9001 {vm_id} --name nixos-fileserver --description "Nixos Fileserver" --full 1',
            # Set options on the template
            f"qm set {vm_id} --kvm 1 --ciuser ops",
            f"qm set {vm_id} --cores {cpu_cores}",
            f"qm set {vm_id} --balloon 0 --memory {memory}",
            f"qm set {vm_id} --scsi0 local-lvm:vm-{vm_id}-disk-0,ssd=1",
            f"qm set {vm_id} --agent 1",
            f"qm set {vm_id} --onboot 1"
            f"qm disk resize {vm_id} scsi0 {disk_space_in_gb}G",
            # Set the PCI card (notice it's 0000:02:00 and NOT 0000:02:00.0)
            # Serial Attached SCSI controller: Broadcom / LSI SAS2008 PCI-Express Fusion-MPT SAS-2 [Falcon] (rev 03)
            f"qm set {vm_id} --hostpci0 host=0000:02:00,rombar=1",
            # Set the SSH key
            f"qm set {vm_id} --sshkeys {key_path}",
        ]

        self.create_nixos_smb_vm = RunCommandsOnHost(
            resource_name="proxmoxCreateNixosSambaServer",
            connection=pulumi_connection,
            create=script,
            delete=[f"qm destroy {vm_id}"],
            update=[f"qm destroy {vm_id}"] + script,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=save_key,
                depends_on=[
                    self.create_nixos_cloud_init_image,
                    # save_key,
                    self.reboot_after_isolating_gpu,
                ],
            ),
        )

        # Start VM
        proxmox_connection_args = ProxmoxConnectionArgs(
            host=self.proxmox_ip,
            api_user="pulumi@pve",
            ssh_user="pulumi",
            ssh_port=22,
            ssh_private_key=self.private_key.private_key_pem,
            api_token_name="provider",
            api_token_value=self.pulumi_api_token,
            api_verify_ssl=False,
        )

        # Start the VM and pause for 60 seconds
        self.nixos_samba_server_start_vm = StartVm(
            resource_name="StartNixOsSambaServer",
            start_vm_args=StartVmArgs(
                proxmox_connection_args=proxmox_connection_args,
                node_name="pve",
                vm_id=vm_id,
                wait=60,
            ),
            opts=pulumi.ResourceOptions(
                parent=self.create_nixos_smb_vm,
                depends_on=[
                    # self.create_nixos_smb_vm,
                ],
            ),
        )

        # Get IP of VM
        self.nixos_samba_server_ip = GetIpOfVm(
            resource_name="GetIpOfNixosSambaServer",
            get_ip_of_vm_args=GetIpOfVmArgs(
                proxmox_connection_args=proxmox_connection_args,
                node_name="pve",
                vm_id=vm_id,
            ),
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_server_start_vm,
                depends_on=[
                    self.nixos_samba_server_start_vm,
                ],
            ),
        )

        pulumi.export("nixos_samba_ip", self.nixos_samba_server_ip.ip)

        # Create ssh connection to nix samba server
        nix_samba_connection = pulumi_command.remote.ConnectionArgs(
            host=self.nixos_samba_server_ip.ip,
            port=22,
            user="ops",
            private_key=self.private_key.private_key_pem,
        )

        # update the nix-channel on the VM
        script = [
            "nix-channel --add https://nixos.org/channels/nixos-23.11 nixos",
            "nix-channel --update",
        ]
        self.nixos_samba_update_channel = RunCommandsOnHost(
            resource_name="nixSambaUpdateChannel",
            connection=nix_samba_connection,
            create=script,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_server_ip,
                depends_on=[
                    self.private_key,
                ],
            ),
        )

        # Save the configuration.nix file
        configuration_nix_file = (
            f"{os.path.dirname(__file__)}/nix_samba/configuration.nix"
        )
        with open(configuration_nix_file, "r") as file:
            configuration_nix = file.read()
        configuration_path = "/etc/nixos/configuration.nix"
        self.nixos_samba_configuration_nix = SaveFileOnRemoteHost(
            resource_name="nixSambaConfigurationNix",
            connection=nix_samba_connection,
            file_contents=configuration_nix,
            file_location=configuration_path,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_update_channel,
                depends_on=[
                    self.private_key,
                ],
            ),
        )

        # Rebuild switch
        self.nixos_samba_update_channel = RunCommandsOnHost(
            resource_name="nixSambaRebuildSwitch",
            connection=nix_samba_connection,
            create=[
                "nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix"
            ],
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_server_ip,
                depends_on=[
                    self.private_key,
                ],
            ),
        )

        return

    @staticmethod
    def get_api_token(input: Output) -> pulumi.Output[str]:
        output = input.apply(lambda input: json.loads(input).get("value"))
        return output

    @staticmethod
    def text_to_file(text: str, filename) -> None:
        if os.path.isfile(filename):
            os.remove(filename)
        with open(filename, "w", 0o600) as file:
            os.chmod(filename, 0o600)
            file.write(text)
        return

    @staticmethod
    def pci_ids_reg_ex(stdout: str) -> str:
        pattern = re.compile(r"\[([a-z0-9]{4}:[a-z0-9]{4})\]")
        pci_ids = []
        for line in stdout.splitlines():
            if "NVIDIA Corporation" in line and (
                "VGA" in line or "Audio device" in line
            ):
                match = pattern.search(line)
                if match:
                    pci_ids.append(match.group(1))
        pci_ids_str = ",".join(pci_ids)
        return pci_ids_str

    @staticmethod
    def get_pci_ids(lspci_cmd_output) -> pulumi.Output[str]:
        pci_ids = lspci_cmd_output.stdout.apply(
            lambda stdout: Proxmox.pci_ids_reg_ex(stdout)
        )
        return pci_ids
