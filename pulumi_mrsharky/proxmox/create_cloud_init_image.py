import pulumi
import pulumi_command
import pulumi_tls

from pulumi_mrsharky.remote import RunCommandsOnHost


def create_cloud_init_image(
    proxmox_ip: str,
    proxmox_private_key: pulumi_tls.PrivateKey,
    reboot_after_isolating_gpu,
):
    pulumi_connection = pulumi_command.remote.ConnectionArgs(
        host=proxmox_ip,
        port=22,
        user="pulumi",
        private_key=proxmox_private_key.private_key_pem,
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

    _ = RunCommandsOnHost(
        resource_name="proxmoxCreateUbuntuCloudInitImages",
        connection=pulumi_connection,
        create=script,
        use_sudo=True,
        opts=pulumi.ResourceOptions(
            depends_on=[
                reboot_after_isolating_gpu,
            ]
        ),
    )
    return
