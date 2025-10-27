from typing import Dict, List, Optional

import pulumi
import pulumi_command
from pulumi import Resource

from home_infra.utils.pulumi_extras import PulumiExtras
from pulumi_mrsharky.proxmox.proxmox_base import ProxmoxBase
from pulumi_mrsharky.proxmox.start_vm import StartVm, StartVmArgs
from pulumi_mrsharky.remote import RunCommandsOnHost, SaveFileOnRemoteHost


class ProxmoxNixOS:
    def __init__(
        self,
        resource_name_prefix: str,
        proxmox_base: ProxmoxBase,
        nixos_template_id: int = 9001,
        template_storage_volume_name: str = "local-lvm",
    ):
        self.resource_name_prefix = resource_name_prefix
        self.proxmox_base = proxmox_base
        self.nixos_template_id = nixos_template_id
        self.template_storage_volume_name = template_storage_volume_name

        # Create the template image
        self.template_resource = self._create_nixos_template(
            resource_name=f"{self.resource_name_prefix}NixOSTemplate",
            template_id=self.nixos_template_id,
            storage_vol_name=template_storage_volume_name,
        )

        # Resource lookup
        self.resource_lookup: Dict[str, Dict[str, Resource]] = {}
        self.finished_setup: Dict[str, Resource] = {}

        return

    def _create_nixos_template(
        self,
        resource_name: str,
        template_id: int,
        storage_vol_name: str,
        opts: Optional[pulumi.ResourceOptions] = None,
    ) -> pulumi.Resource:

        create_script = [
            "sudo wget --continue --output-document=/var/lib/vz/template/iso/nixos-25.05-cloud-init.img "
            + "https://mrsharky.com/extras/nixos-25.05-cloud-init.img ",
            f"sudo qm create {template_id} --memory 2048 --core 2 --cpu cputype=host,flags=+aes "
            + "--name nixos-25.05-kvm --net0 virtio,bridge=vmbr0",
            f"sudo qm importdisk {template_id} /var/lib/vz/template/iso/nixos-25.05-cloud-init.img "
            + f"{storage_vol_name}",
            f"sudo qm set {template_id} --scsihw virtio-scsi-pci --scsi0 {storage_vol_name}:vm-{template_id}-disk-0",
            f"sudo qm set {template_id} --ide2 {storage_vol_name}:cloudinit",
            f"sudo qm set {template_id} --boot c --bootdisk scsi0",
            # f"sudo qm set {template_id} --serial0 socket --vga serial0",
            # f"sudo qm set {template_id} --machine q35",
            # f"sudo qm set {template_id} --bios ovmf",
            # f"sudo qm set {template_id} --efidisk0
            #   file={storage_volume_name}:vm-9001-disk-1,efitype=4m,format=raw,pre-enrolled-keys=0,size=1M",
            # f"sudo qm set {template_id} --efidisk0
            #   {storage_volume_name}:{template_id}/vm-{template_id}-disk-0,efitype=4m"
            # f"sudo qm set {template_id} --efidisk0 {storage_volume_name}:4,efitype=4m,format=raw,size=1M",
            f"sudo qm set {template_id} --ipconfig0 ip=dhcp",
            f"sudo qm template {template_id}",
        ]

        delete_script = [
            f"sudo qm destroy {template_id} --destroy-unreferenced-disks 1 --purge 1"
        ]

        create_script = " && ".join(create_script)
        delete_script = " && ".join(delete_script)

        create_nixos_cloud_init_image = PulumiExtras.run_command_on_remote_host(
            resource_name=resource_name,
            connection=self.proxmox_base.pulumi_connection,
            create=create_script,
            delete=delete_script,
            opts=pulumi.ResourceOptions(
                parent=self.proxmox_base.enable_iommu,
                delete_before_replace=True,
            ),
        )

        return create_nixos_cloud_init_image

    def create_vm(
        self,
        resource_name: str,
        vm_name: str,
        vm_description: str,
        vm_id: int,
        ip_v4: str,
        ip_v4_gw: str,
        ip_v4_cidr: int = 24,
        bios: Optional[str] = None,
        cpu_cores: Optional[int] = None,
        cpu_type: Optional[str] = None,
        kvm: Optional[bool] = None,
        disk_space_in_gb: Optional[int] = None,
        start_on_boot: Optional[bool] = None,
        hardware_passthrough: Optional[List[str]] = None,
        machine: Optional[str] = None,
        memory: Optional[int] = None,
        drive_config: Optional[str] = None,
        extra_args: Optional[str] = None,
        enable_agent: Optional[bool] = None,
    ):
        if resource_name in self.resource_lookup:
            raise Exception(f"VM resource '{resource_name}' already exists")
        else:
            self.resource_lookup[resource_name] = {}

        # Process inputs (and set defaults)
        if bios is None:
            bios = "seabios"
        if cpu_type is None:
            cpu_type = "host"
        if cpu_cores is None:
            cpu_cores = 4
        if disk_space_in_gb is None:
            disk_space_in_gb = 32
        if start_on_boot is None:
            start_on_boot = False
        if hardware_passthrough is None:
            hardware_passthrough = []
        if kvm is None:
            kvm = True
        if drive_config is None:
            drive_config = "{}"
        if machine is None:
            machine = "i440fx"
        if memory is None:
            memory = 2048
        if enable_agent is None:
            enable_agent = True

        # Some inputs need to be strings to be used
        on_boot = "0"
        if start_on_boot:
            on_boot = "1"
        kvm_status = "0"
        if kvm:
            kvm_status = "1"

        # Save file with private key on proxmox for use into this image

        # NOTE: Can't use the next line as proxmox_api_username is an output. Will need to
        #       make a full resource for this in the future
        # key_path = f"/home/{self.proxmox_base.proxmox_api_username}/proxmox_key_vm={vm_id}.pem"

        key_path = f"/home/pulumi/proxmox_key_vm={vm_id}.pem"
        save_key_resource_name = (
            f"{self.resource_name_prefix}_{resource_name}_nixosSshKey"
        )
        save_key = SaveFileOnRemoteHost(
            resource_name=save_key_resource_name,
            connection=self.proxmox_base.pulumi_connection,
            file_contents=self.proxmox_base.private_key.public_key_openssh,
            file_location=key_path,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.template_resource,
                delete_before_replace=True,
            ),
        )
        self.resource_lookup[resource_name][save_key_resource_name] = save_key

        # Create the VM
        create_script = [
            # Clone the nixos template
            f"qm clone {self.nixos_template_id} {vm_id} --name {vm_name} "
            + f'--description "{vm_description}" --full 1',
            # Set options on the template
            f"qm set {vm_id} --kvm {kvm_status} --ciuser ops",
            f"qm set {vm_id} --cpu {cpu_type}",
            f"qm set {vm_id} --bios {bios}",
            f"qm set {vm_id} --cores {cpu_cores}",
            f"qm set {vm_id} --balloon 0 --memory {memory}",
            f"qm set {vm_id} --scsi0 local-lvm:vm-{vm_id}-disk-0,ssd=1",
            f"qm set {vm_id} --machine {machine}",  # Set the machine
            f"qm set {vm_id} --onboot {on_boot}",
            f"qm disk resize {vm_id} scsi0 {disk_space_in_gb}G",
            f"qm set {vm_id} --sshkeys {key_path}",  # Set the SSH key
            # Set cloud-init IP
            f"qm set {vm_id} --ipconfig0 ip={ip_v4}/{ip_v4_cidr},gw={ip_v4_gw}",
        ]

        if extra_args is not None and len(extra_args) > 0:
            create_script.append(f'qm set {vm_id} --args "{extra_args}"')

        if enable_agent:  # Enable qemu agent
            create_script.append(f"qm set {vm_id} --agent 1")

        # qm set 501 --hostpci0 host=0000:10:00.0,pcie=1,rombar=0,pci=assign

        # Add hardware passthrough (if applicable)
        for idx, hardware in enumerate(hardware_passthrough):
            # Set the PCI card (notice it's 0000:02:00 and NOT 0000:02:00.0)
            # Serial Attached SCSI controller: Broadcom / LSI SAS2008 PCI-Express Fusion-MPT SAS-2 [Falcon] (rev 03)
            # qm set 300 --hostpci0 host=0000:02:00,rombar=1
            create_script.append(f"qm set {vm_id} --hostpci{idx} host={hardware}")

        delete_script = [
            f"qm shutdown {vm_id}",
            f"qm wait {vm_id}",
            f"qm destroy {vm_id}",
        ]

        create_vm_resource_name = (
            f"{self.resource_name_prefix}_{resource_name}_proxmoxCreateNixos"
        )
        create_vm = RunCommandsOnHost(
            resource_name=create_vm_resource_name,
            connection=self.proxmox_base.pulumi_connection,
            create=create_script,
            delete=delete_script,
            update=delete_script + create_script,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=save_key,
                delete_before_replace=True,
            ),
        )
        self.resource_lookup[resource_name][create_vm_resource_name] = create_vm

        # Start the VM and pause for 60 seconds
        start_vm_resource_name = (
            f"{self.resource_name_prefix}_{resource_name}_StartNixos"
        )
        start_vm = StartVm(
            resource_name=start_vm_resource_name,
            start_vm_args=StartVmArgs(
                proxmox_connection_args=self.proxmox_base.proxmox_connection_args,
                node_name=self.proxmox_base.node_name,
                vm_id=vm_id,
                wait=60,
            ),
            opts=pulumi.ResourceOptions(
                parent=create_vm,
            ),
        )
        self.resource_lookup[resource_name][start_vm_resource_name] = start_vm

        ####################################
        # update the nix-channel on the VM
        ####################################
        nix_connection = pulumi_command.remote.ConnectionArgs(
            host=ip_v4,
            port=22,
            user="ops",
            private_key=self.proxmox_base.private_key.private_key_pem,
        )

        create_script = [
            "nix-channel --add https://nixos.org/channels/nixos-25.05 nixos",
            "nix-channel --update",
            # "nix-channel --remove nixos",
            # "nix-channel --add https://nixos.org/channels/nixos-25.05 nixos",
            # "nixos-rebuild switch --show-trace"
            # "nix-channel --update",
        ]
        update_channel_resource_name = (
            f"{self.resource_name_prefix}_{resource_name}_UpdateChannel"
        )
        update_channel = RunCommandsOnHost(
            resource_name=update_channel_resource_name,
            connection=nix_connection,
            create=create_script,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=start_vm,
            ),
        )
        self.resource_lookup[resource_name][
            update_channel_resource_name
        ] = update_channel

        # Finished setup
        self.finished_setup[resource_name] = start_vm

        return (start_vm, nix_connection)
