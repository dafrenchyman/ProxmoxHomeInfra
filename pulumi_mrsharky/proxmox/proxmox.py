import json
import os
import re
from typing import Any

import pulumi
import pulumi_command
import pulumi_tls
from pulumi import Input, Output
from pulumi.dynamic import CreateResult, ResourceProvider, UpdateResult

from home_infra.utils.pulumi_extras import PulumiExtras
from pulumi_mrsharky.remote import RunCommandsOnHost

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


class ProxmoxArgs(object):
    proxmox_ip: Input[str]
    proxmox_pass: Input[str]
    node_name: Input[str]
    private_key: Input[pulumi_tls.PrivateKey]
    remove_enterprise_repo: Input[bool]
    proxmox_pulumi_username: Input[str]

    def __init__(
        self,
        proxmox_ip: str,
        proxmox_pass: str,
        private_key: pulumi_tls.PrivateKey,
        remove_enterprise_repo: bool = False,
        proxmox_pulumi_username: str = "pulumi",
    ) -> None:
        self.proxmox_ip = proxmox_ip
        self.proxmox_pass = proxmox_pass
        self.private_key = private_key
        self.remove_enterprise_repo = remove_enterprise_repo
        self.proxmox_pulumi_username = proxmox_pulumi_username
        return


class ResourceProviderProxmox(ResourceProvider):
    def _process_inputs(self, props) -> ProxmoxArgs:
        proxmox_args = ProxmoxArgs(
            proxmox_ip=props.get("proxmox_ip"),
            proxmox_pass=props.get("proxmox_pass"),
            private_key=props.get("private_key"),
            remove_enterprise_repo=bool(props.get("remove_enterprise_repo")),
            proxmox_pulumi_username=props.get("proxmox_pulumi_username"),
        )
        return proxmox_args

    def create(self, props) -> CreateResult:
        # Get the input arguments
        arguments = self._process_inputs(props)

        # Create a unique_id
        id = "something"

        # Remove Enterprise Repo
        if arguments.remove_enterprise_repo:
            self.remove_enterprise_repo = self._remove_enterprise_repo(arguments)

        # Setup pulumi user
        self.setup_pulumi_user = self._setup_pulumi_user(id=id, arguments=arguments)

        # Setup API Token
        self._setup_api_token(
            node_name=self.node_name, username=self.proxmox_pulumi_username
        )

        results = {
            "node_name": arguments.node_name,
            "vm_id": arguments.vm_id,
            "wait": arguments.wait,
        }

        # return proxmox_connection.host, results

        return CreateResult(id_=id, outs=results)

    def delete(self, id: str, props: Any) -> None:
        return

    def update(self, id: str, old_props: Any, new_props: Any) -> UpdateResult:
        self.delete(id=id, props=old_props)
        _, results = self._common_create(new_props)
        return UpdateResult(outs=results)

    def _remove_enterprise_repo(self, arguments: ProxmoxArgs) -> None:
        remove_enterprise_repo = PulumiExtras.run_command_on_remote_host(
            resource_name="ProxmoxRemoveEnterpriseRepo",
            connection=pulumi_command.remote.ConnectionArgs(
                host=arguments.proxmox_ip,
                port=22,
                user="root",
                password=arguments.proxmox_pass,
            ),
            create=(
                "sed -i 's/deb https/# deb https/g' /etc/apt/sources.list.d/pve-enterprise.list && "
                "sed -i 's/deb https/# deb https/g' /etc/apt/sources.list.d/ceph.list "
            ),
            delete=(
                "sed -i 's/# deb https/deb https/g' /etc/apt/sources.list.d/pve-enterprise.list && "
                "sed -i 's/# deb https/deb https/g' /etc/apt/sources.list.d/ceph.list "
            ),
            opts=pulumi.ResourceOptions(depends_on=[arguments.private_key]),
        )
        return remove_enterprise_repo

    def _setup_pulumi_user(self, id: str, arguments: ProxmoxArgs) -> None:
        proxmox_connection = pulumi_command.remote.ConnectionArgs(
            host=arguments.proxmox_ip,
            port=22,
            user="root",
            password=arguments.proxmox_pass,
        )

        # Install sudo
        install_sudo = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{id}InstallSudo",
            connection=proxmox_connection,
            create="apt-get update && apt-get install -y sudo",
            delete="apt-get purge -y sudo",
            opts=pulumi.ResourceOptions(
                depends_on=[self.remove_enterprise_repo, arguments.private_key]
            ),
        )

        # Create the pulumi user
        create_pulumi_user = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{id}CreatePulumiUser",
            connection=proxmox_connection,
            create=f"useradd --create-home -s /bin/bash {arguments.proxmox_pulumi_username}",
            delete=f"userdel --remove {arguments.proxmox_pulumi_username}",
            opts=pulumi.ResourceOptions(
                depends_on=[arguments.private_key, install_sudo]
            ),
        )

        # Add ssh key
        add_pulumi_ssh_key = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{id}AddSshKeyForPulumiUser",
            connection=proxmox_connection,
            create=arguments.private_key.public_key_openssh.apply(
                lambda key: (
                    f"mkdir -p /home/{arguments.proxmox_pulumi_username}/.ssh/ && "
                    f"echo '{key}' >> /home/{arguments.proxmox_pulumi_username}/.ssh/authorized_keys"
                )
            ),
            # TODO: Come up with good delete
            delete=None,
            opts=pulumi.ResourceOptions(
                depends_on=[arguments.private_key, create_pulumi_user]
            ),
        )

        # Add pulumi to sudo
        add_pulumi_to_sudo = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{id}AddPulumiToSudo",
            connection=proxmox_connection,
            create=(
                "mkdir -p /etc/sudoers.d/ && "
                f"echo '{arguments.proxmox_pulumi_username} ALL=(ALL) NOPASSWD: ALL' > "
                f"/etc/sudoers.d/{arguments.proxmox_pulumi_username} && "
                f"chown root:root /etc/sudoers.d/{arguments.proxmox_pulumi_username} && "
                f"chmod 440 /etc/sudoers.d/{arguments.proxmox_pulumi_username}"
            ),
            delete=(f"rm /etc/sudoers.d/{arguments.proxmox_pulumi_username}"),
            opts=pulumi.ResourceOptions(
                depends_on=[arguments.private_key, add_pulumi_ssh_key]
            ),
        )

        # Reboot
        reboot_after_sudo = PulumiExtras.reboot_remote_host(
            resource_name=f"{id}RebootAfterSudo",
            connection=proxmox_connection,
            opts=pulumi.ResourceOptions(
                depends_on=[arguments.private_key, add_pulumi_to_sudo],
            ),
        )
        return reboot_after_sudo

    def _setup_api_token(self, id: str, arguments: ProxmoxArgs) -> None:
        pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=arguments.proxmox_ip,
            port=22,
            user=arguments.proxmox_pulumi_username,
            private_key=arguments.private_key.private_key_pem,
        )

        # Add a pulumi user
        create_api_user = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{id}CreatePulumiApiUser{arguments.node_name}",
            connection=pulumi_connection,
            create=(
                f"sudo pveum user add {arguments.proxmox_pulumi_username}@{arguments.node_name} && "
                f"sudo pveum aclmod / -user {arguments.proxmox_pulumi_username}@{arguments.node_name} "
                + "-role Administrator"
            ),
            delete=f"sudo pveum user delete {arguments.proxmox_pulumi_username}@{arguments.node_name}",
            opts=pulumi.ResourceOptions(parent=self.setup_pulumi_user, depends_on=[]),
        )

        # Create token
        create_token = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{id}CreatePulumiApiToken",
            connection=pulumi_connection,
            create=(
                f"sudo pveum user token add {arguments.proxmox_pulumi_username}@{arguments.node_name} "
                + "provider --privsep=0 --expire 0 --output-format json"
            ),
            delete=f"sudo pveum user token remove {arguments.proxmox_pulumi_username}@{arguments.node_name} provider",
            opts=pulumi.ResourceOptions(parent=create_api_user, depends_on=[]),
        )
        pulumi_api_token = Proxmox.get_api_token(create_token.stdout)

        pulumi.export(f"{id}_API_TOKEN", pulumi_api_token)

        return


class Proxmox:
    def __init__(
        self,
        resource_name: str,
        proxmox_ip: str,
        proxmox_pass: str,
        node_name: str,
        private_key: pulumi_tls.PrivateKey,
        remove_enterprise_repo: bool = False,
        proxmox_pulumi_username: str = "pulumi",
    ) -> None:
        """
        Sources:
        - https://forum.proxmox.com/threads/pci-gpu-passthrough-on-proxmox-ve-8-installation-and-configuration.130218/
        - https://www.youtube.com/watch?v=4G9d5COhOvI&t=19s
        - https://registry.terraform.io/providers/bpg/proxmox/latest/docs
        :param proxmox_ip:
        :param proxmox_pass:
        """

        # Save all the input arguments
        self.proxmox_ip = proxmox_ip
        self.proxmox_pass = proxmox_pass
        self.node_name = node_name
        self.private_key = private_key
        self.remove_enterprise_repo = remove_enterprise_repo
        self.proxmox_pulumi_username = proxmox_pulumi_username

        return

    def run(self) -> None:

        # Setup IOMMU for GPU Passthrough
        self._setup_iommu()

        # Setup Ubuntu Cloud Init image
        self._create_ubuntu_cloud_init_images()

        # Setup Nixos Cloud Init image
        self._create_nixos_cloud_init_images()

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
