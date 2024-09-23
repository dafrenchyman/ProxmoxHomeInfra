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
        template_storage_volume_name: str = "local-zfs",
    ):
        self.resource_name_prefix = resource_name_prefix
        self.proxmox_base = proxmox_base
        self.nixos_template_id = nixos_template_id
        self.template_storage_volume_name = template_storage_volume_name

        # Create the template image
        self.template_resource = self._create_nixos_template(
            resource_name=f"{self.resource_name_prefix}NixOSTemplate",
            template_id=self.nixos_template_id,
            storage_volume_name=template_storage_volume_name,
        )

        # Resource lookup
        self.resource_lookup: Dict[str, Dict[str, Resource]] = {}
        self.finished_setup: Dict[str, Resource] = {}

        return

    def _create_nixos_template(
        self,
        resource_name: str,
        template_id: int,
        storage_volume_name: str,
        opts: Optional[pulumi.ResourceOptions] = None,
    ) -> pulumi.Resource:

        create_script = [
            "sudo wget --continue --output-document=/var/lib/vz/template/iso/nixos-23.11-cloud-init.img "
            + "https://mrsharky.com/extras/nixos-23.11-cloud-init.img ",
            f"sudo qm create {template_id} --memory 2048 --core 2 --cpu cputype=host,flags=+aes "
            + "--name nixos-23.11-kvm --net0 virtio,bridge=vmbr0",
            f"sudo qm importdisk {template_id} /var/lib/vz/template/iso/nixos-23.11-cloud-init.img "
            + "{storage_volume_name}",
            f"sudo qm set {template_id} --scsihw virtio-scsi-pci --scsi0 {storage_volume_name}:vm-9001-disk-0",
            f"sudo qm set {template_id} --ide2 {storage_volume_name}:cloudinit",
            f"sudo qm set {template_id} --boot c --bootdisk scsi0",
            f"sudo qm set {template_id} --serial0 socket --vga serial0",
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
        memory: int = 16384,
        cpu_cores: int = 4,
        disk_space_in_gb: int = 1000,
        start_on_boot: bool = False,
        hardware_passthrough: List[str] = None,
        drive_config: str = None,
    ):
        if resource_name in self.resource_lookup:
            raise Exception(f"VM resource '{resource_name}' already exists")
        else:
            self.resource_lookup[resource_name] = {}
        # Process inputs
        if hardware_passthrough is None:
            hardware_passthrough = []
        if drive_config is None:
            drive_config = "{}"

        on_boot = "0"
        if start_on_boot:
            on_boot = "1"

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
            f"qm set {vm_id} --kvm 1 --ciuser ops",
            f"qm set {vm_id} --cores {cpu_cores}",
            f"qm set {vm_id} --balloon 0 --memory {memory}",
            f"qm set {vm_id} --scsi0 local-zfs:vm-{vm_id}-disk-0,ssd=1",
            f"qm set {vm_id} --agent 1",
            f"qm set {vm_id} --onboot {on_boot}",
            f"qm disk resize {vm_id} scsi0 {disk_space_in_gb}G",
            # Set the SSH key
            f"qm set {vm_id} --sshkeys {key_path}",
            # Set cloud-init IP
            f"qm set {vm_id} --ipconfig0 ip={ip_v4}/{ip_v4_cidr},gw={ip_v4_gw}",
        ]

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
            "nix-channel --add https://nixos.org/channels/nixos-23.11 nixos",
            "nix-channel --update",
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
