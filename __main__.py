"""A Python Pulumi program"""

import pulumi

from home_infra.proxmox.proxmox import Proxmox
from pulumi_mrsharky.nixos_samba.nixos_samba_server import NixosSambaServer


def main():
    config = pulumi.Config()

    # Common settings
    proxmox_ip = config.require("proxmox_ip")
    proxmox_pass = config.require("proxmox_pass")
    samba_hardware = config.require("samba_hardware")

    # Setup proxmox
    proxmox = Proxmox(proxmox_ip=proxmox_ip, proxmox_pass=proxmox_pass)
    proxmox.run()

    # Setup Nixos Samba Server
    _ = NixosSambaServer(
        proxmox_ip=proxmox_ip,
        proxmox_username="pulumi",
        proxmox_node_name="pve",
        proxmox_private_key=proxmox.private_key,
        proxmox_api_token=proxmox.pulumi_api_token,
        nixos_template_vm_id=9000,
        proxmox_api_token_name="provider",
        nix_hardware_configuration=samba_hardware,
    )
    return


if __name__ == "__main__":
    main()
