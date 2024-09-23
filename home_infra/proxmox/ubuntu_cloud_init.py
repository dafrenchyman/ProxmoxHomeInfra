import pulumi
import pulumi_command

from home_infra.proxmox.proxmox import Proxmox
from pulumi_mrsharky.remote import RunCommandsOnHost


class UbuntuCloudInit:

    def __int__(self, proxmox: Proxmox):
        self.proxmox = proxmox

    def _create_ubuntu_cloud_init_images(self):
        pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox.proxmox_ip,
            port=22,
            user=self.proxmox.pulumi_username,
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
