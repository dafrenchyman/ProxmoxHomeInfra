from proxmoxer import ProxmoxAPI

from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnection


def main_old():
    prox = ProxmoxAPI(
        host="192.168.10.10",
        user="root@pam",
        token_name="provider",
        token_value="<TOKEN>",
        verify_ssl=False,
    )

    users = prox.access.users.get()
    _ = prox.nodes.get()
    _ = prox.nodes("pve").qemu.get()
    prox.nodes("pve").hardware.pci.get()
    prox.nodes("pve").disks.get()
    prox.nodes("pve").disks.list.get()

    print(users)


def main():
    proxmox = ProxmoxConnection(
        host="192.168.10.10",
        api_user="root@pam",
        ssh_user="root",
        ssh_password="<PASS>",
        api_token_name="provider",
        api_token_value="<TOKEN>",
    )

    # proxmox.attach_drive_to_vm(
    #     node_name="pve",
    #     vm_id=100,
    #     drive_id="ata-WDC_WD20EARS-00MVWB0_WD-WCAZA5714667",
    #     ssd_emulation=False,
    # )
    # proxmox.remove_drive_from_vm(node_name="pve", vm_id=100, interface="scsi1")

    proxmox.create_group("test")
    proxmox.create_user_api(userid="test", realm="pam", groups="test")
    proxmox.create_api_token(userid="test", realm="pam", token_id="test")

    # proxmox.start_vm(node_name="pve", vm_id=100)


if __name__ == "__main__":
    main()
