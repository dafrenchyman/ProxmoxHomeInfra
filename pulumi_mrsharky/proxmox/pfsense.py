from typing import Optional, Union

import pulumi
import pulumi_command
from pulumi import Output, ResourceOptions

from home_infra.utils.pulumi_extras import PulumiExtras
from pulumi_mrsharky.pfsense.resource_provider_pfsense import PfsenseApiConnectionArgs
from pulumi_mrsharky.pfsense.update_user import PfsenseUpdateUser, PfsenseUpdateUserArgs
from pulumi_mrsharky.proxmox import AddIsoImage, AddIsoImageArgs
from pulumi_mrsharky.proxmox.proxmox_base import ProxmoxBase
from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnectionArgs

PFSENSE_ISO = "https://sgpfiles.netgate.com/mirror/downloads/pfSense-CE-2.7.2-RELEASE-amd64.iso.gz"
ORIGINAL_PFSENSE_PASS = "pfsense"


class PfSense:
    @staticmethod
    def add_iso_image_to_proxmox(
        proxmox_connection_args: ProxmoxConnectionArgs,
        resource_name: str,
        opts: Optional[ResourceOptions] = None,
    ) -> AddIsoImage:
        add_iso_image = AddIsoImage(
            resource_name=resource_name,
            add_iso_image_args=AddIsoImageArgs(
                proxmox_connection_args=proxmox_connection_args,
                url=PFSENSE_ISO,
            ),
            opts=opts,
        )
        return add_iso_image

    @staticmethod
    def create_vm(
        resource_name_base: str,
        proxmox_base: ProxmoxBase,
        vm_id: int,
        vm_name: str,
        lan_ipv4_address: str,
        lan_ipv4_subnet: str,
        lan_ipv4_dhcp_start_address: str,
        lan_ipv4_dhcp_end_address: str,
        wan_passthrough: str,
        lan_passthrough: str,
        admin_password: str,
        admin_public_key: Union[Output[str], str],
        cores: int = 2,
        memory: int = 4096,
        drive_storage: str = "local-zfs",
        drive_in_gb: int = 100,
        ssd_emulation: bool = True,
    ):
        # First install the ios image onto the proxmox server
        add_iso_image = PfSense.add_iso_image_to_proxmox(
            proxmox_connection_args=proxmox_base.proxmox_connection_args,
            resource_name=f"{resource_name_base}AddPfsenseIso",
            opts=pulumi.ResourceOptions(
                parent=proxmox_base.enable_iommu,
                delete_before_replace=True,
            ),
        )
        local_image_name = add_iso_image.local_image_name
        pulumi.export("local_image_name", local_image_name)
        local_image_name = "pfSense-CE-2.7.2-RELEASE-amd64.iso"

        _ = pulumi.Output.all(
            local_image_name=add_iso_image.local_image_name,
        ).apply(
            lambda args: (
                f"sudo qm set {vm_id} --ide2 local:iso/{args['local_image_name']},media=cdrom",
            )
        )

        ssd_emulation_str = "1" if ssd_emulation else "0"
        create_vm_script = [
            # Create image
            f"sudo qm create {vm_id} --memory {memory} --core {cores} --name {vm_name} --ostype l26",
            f"sudo qm set {vm_id} --cpu cputype=host,flags=+aes --scsihw virtio-scsi-single --onboot 1",
            # Add cdrom
            # f"qm set {vm_id} --ide2 local:iso/pfSense-CE-2.7.2-RELEASE-amd64.iso,media=cdrom",
            f"sudo qm set {vm_id} --ide2 local:iso/{local_image_name},media=cdrom",
            # Add local hard drive
            f"sudo qm set {vm_id} --scsi0 {drive_storage}:{drive_in_gb},ssd={ssd_emulation_str},iothread=1",
            # Configure boot order
            f"sudo qm set {vm_id} --boot order='scsi0;ide2'",
            # Add Hardware Network ports (WAN)
            f"sudo qm set {vm_id} --hostpci0 host={wan_passthrough},rombar=1",
            # Add Hardware Network ports (LAN)
            f"sudo qm set {vm_id} --hostpci1 host={lan_passthrough},rombar=1",
        ]
        create_vm_script_resource = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{resource_name_base}_proxmoxCreatePfSenseVM",
            connection=proxmox_base.pulumi_connection,
            create=create_vm_script,
            delete=[f"qm destroy {vm_id}"],
            update=[f"qm destroy {vm_id}"] + create_vm_script,
            opts=pulumi.ResourceOptions(
                parent=proxmox_base.enable_iommu,
                delete_before_replace=True,
            ),
        )

        # Start VM and setup pfsense
        # https://github.com/tuxvador/PROXMOX_PFSENSE_AUTOINSTALL/blob/main/modules/pfsense/scripts/pfsense.sh
        start_vm_script = [
            f"sudo qm start {vm_id}",
            "sleep 60",
            # accept EULA
            f"sudo qm sendkey {vm_id} kp_enter",
            # Choose to install pfsense
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
            # How would you like to partition your disks (Auto ZFS)
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
            # proceed with installation
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
            # Select Virtual Device type
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
            # Select drive
            "sleep 1",
            f"sudo qm sendkey {vm_id} spc",
            # OK
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
            # Confirm (tab over to YES)
            "sleep 1",
            f"sudo qm sendkey {vm_id} tab",
            # Click Yes
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
            # Installing (wait 60 seconds)
            "sleep 60",
            # Reboot
            f"sudo qm sendkey {vm_id} kp_enter",
        ]
        start_vm_resource = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{resource_name_base}_proxmoxPfSenseStartVM",
            connection=proxmox_base.pulumi_connection,
            create=start_vm_script,
            opts=pulumi.ResourceOptions(
                parent=create_vm_script_resource,
                delete_before_replace=True,
            ),
        )

        configure_pfsense_script = [
            # first boot sleep
            "sleep 60",
            # Configure Vlan now (no)
            f"sudo qm sendkey {vm_id} n-kp_enter",
            # Select WAN interface
            "sleep 1",
            f"sudo qm sendkey {vm_id} i-g-c-0-kp_enter",
            # Select LAN interface
            "sleep 1",
            f"sudo qm sendkey {vm_id} i-g-c-1-kp_enter",
            # Do you wish to proceed (yes)
            "sleep 1",
            f"sudo qm sendkey {vm_id} y-kp_enter",
            # Wait for configuration to complete
            "sleep 60",
        ]

        configure_pfsense_resource = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{resource_name_base}_proxmoxPfSenseConfigure",
            connection=proxmox_base.pulumi_connection,
            create=configure_pfsense_script,
            opts=pulumi.ResourceOptions(
                parent=start_vm_resource,
                delete_before_replace=True,
            ),
        )

        lan_ipv4_address_cmd = "-".join(lan_ipv4_address).replace(".", "dot")
        lan_ipv4_subnet_cmd = "-".join(lan_ipv4_subnet)
        lan_ipv4_dhcp_start_address_cmd = "-".join(lan_ipv4_dhcp_start_address).replace(
            ".", "dot"
        )
        lan_ipv4_dhcp_end_address_cmd = "-".join(lan_ipv4_dhcp_end_address).replace(
            ".", "dot"
        )
        setup_lan_wan_script = [
            # Set interface IPs
            "sleep 1",
            f"sudo qm sendkey {vm_id} 2-kp_enter",
            # Set the LAN IP
            "sleep 1",
            f"sudo qm sendkey {vm_id} 2-kp_enter",
            # Configure IPv4 LAN interface via DHCP
            "sleep 1",
            f"sudo qm sendkey {vm_id} n-kp_enter",
            # Enter new LAN IPv4 address
            "sleep 1",
            f"sudo qm sendkey {vm_id} {lan_ipv4_address_cmd}-kp_enter",
            # Enter subnet bit count
            "sleep 1",
            f"sudo qm sendkey {vm_id} {lan_ipv4_subnet_cmd}-kp_enter",
            # For LAN, press <ENTER> for none
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
            # Configure IPv6 for LAN
            "sleep 1",
            f"sudo qm sendkey {vm_id} n-kp_enter",
            # For LAN, press <ENTER> for none
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
            # Enable DHCP Server on LAN
            "sleep 1",
            f"sudo qm sendkey {vm_id} y-kp_enter",
            # Enter start address
            "sleep 1",
            f"sudo qm sendkey {vm_id} {lan_ipv4_dhcp_start_address_cmd}-kp_enter",
            # Enter end address
            "sleep 1",
            f"sudo qm sendkey {vm_id} {lan_ipv4_dhcp_end_address_cmd}-kp_enter",
            # Revert to HTTP for webConfigurator
            "sleep 1",
            f"sudo qm sendkey {vm_id} n-kp_enter",
            # Press <ENTER> to continue
            "sleep 1",
            f"sudo qm sendkey {vm_id} kp_enter",
        ]
        setup_lan_wan_resource = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{resource_name_base}_proxmoxPfSenseSetupNetworks",
            connection=proxmox_base.pulumi_connection,
            create=setup_lan_wan_script,
            opts=pulumi.ResourceOptions(
                parent=configure_pfsense_resource,
                delete_before_replace=True,
            ),
        )

        # Enable SSH
        enable_ssh_script = [
            "sleep 1",
            f"sudo qm sendkey {vm_id} 1-4-kp_enter",
            # Confirm enable
            "sleep 1",
            f"sudo qm sendkey {vm_id} y-kp_enter",
        ]
        enable_ssh_resource = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{resource_name_base}_proxmoxPfSenseSetupSSH",
            connection=proxmox_base.pulumi_connection,
            create=enable_ssh_script,
            opts=pulumi.ResourceOptions(
                parent=setup_lan_wan_resource,
                delete_before_replace=True,
            ),
        )

        # Install API
        pfsense_admin_connection = pulumi_command.remote.ConnectionArgs(
            host=lan_ipv4_address,
            port=22,
            user="admin",
            password="pfsense",  # pragma: allowlist secret
        )
        install_api_script = [
            "pkg-static add "
            + "https://github.com/jaredhendrickson13/pfsense-api/"
            + "releases/latest/download/pfSense-2.7.2-pkg-RESTAPI.pkg"
        ]
        _ = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{resource_name_base}_proxmoxPfSenseEnableAPI",
            connection=pfsense_admin_connection,
            create=install_api_script,
            opts=pulumi.ResourceOptions(
                parent=enable_ssh_resource,
                delete_before_replace=True,
            ),
        )

        # Setup QEMU Guest
        qemu_guest_script = [
            # "pkg update -y",
            "pkg install -y qemu-guest-agent",
            "sysrc qemu_guest_agent_enable='YES'",
            # "sysrc qemu_guest_agent_flags = '-d -v -l /var/log/qemu-ga.log'",
            "service qemu-guest-agent start",
        ]
        setup_qemu_guest_resource = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{resource_name_base}_proxmoxPfSenseSetupQEMU",
            connection=pfsense_admin_connection,
            create=qemu_guest_script,
            opts=pulumi.ResourceOptions(
                parent=enable_ssh_resource,
                delete_before_replace=True,
            ),
        )

        # Enable QEMU agent on proxmox
        enable_qemu_resource = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{resource_name_base}_proxmoxPfSenseEnableQEMU",
            connection=proxmox_base.pulumi_connection,
            create=[
                f"sudo qm set {vm_id} --agent 1",
            ],
            delete=[
                f"sudo qm set {vm_id} --agent 0",
            ],
            opts=pulumi.ResourceOptions(
                parent=setup_qemu_guest_resource,
                delete_before_replace=True,
            ),
        )

        # Change default password and add ssh key
        update_admin_password = PfsenseUpdateUser(
            resource_name="Router_pfsense_update_admin_user",
            update_user_args=PfsenseUpdateUserArgs(
                pf_sense_api_connection_args=PfsenseApiConnectionArgs(
                    username="admin",
                    password=ORIGINAL_PFSENSE_PASS,
                    url=lan_ipv4_address,
                    verify_cert=False,
                ),
                username="admin",
                password=admin_password,
                authorized_keys=admin_public_key,
            ),
            opts=pulumi.ResourceOptions(
                parent=enable_qemu_resource,
                delete_before_replace=True,
            ),
        )

        """
        ###############################
        # Install qemu guest agent
        # https://github.com/tuxvador/PROXMOX_PFSENSE_AUTOINSTALL/blob/main/modules/pfsense/pfsense.tf
        # Needs to run via ssh
        ###############################
        pkg update -y
        pkg install -y qemu-guest-agent
        pkg install -y sudo
        pkg install -y vim
        python3.11 -m ensurepip",                 #install pip
        python3.11 -m pip install --upgrade pip", #upgrade pip
        sysrc sshd_enable='YES'
        sysrc qemu_guest_agent_enable='YES'
        sysrc qemu_guest_agent_flags='-d -v -l /var/log/qemu-ga.log'
        service qemu-guest-agent start
        service qemu-guest-agent status
        """

        return update_admin_password
