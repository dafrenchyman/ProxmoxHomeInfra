import os
from typing import List, Optional

import pulumi
import pulumi_command
from pulumi import Resource
from pulumi_tls import PrivateKey

from home_infra.utils.pulumi_extras import PulumiExtras
from pulumi_mrsharky.nixos.create_config import CreateConfig, CreateConfigArgs
from pulumi_mrsharky.proxmox.get_ip_of_vm import GetIpOfVm, GetIpOfVmArgs
from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnectionArgs
from pulumi_mrsharky.proxmox.start_vm import StartVm, StartVmArgs
from pulumi_mrsharky.remote import RunCommandsOnHost, SaveFileOnRemoteHost


class NixosBase:
    def __init__(
        self,
        resource_name_prefix: str,
        pulumi_connection: pulumi_command.remote.ConnectionArgs,
        parent: Optional[Resource],
    ):
        self.resource_name_prefix = resource_name_prefix
        self.pulumi_connection = pulumi_connection
        self.parent = parent

        # Setup glances
        self._set_glances()
        return

    def _set_glances(self):
        ####################################
        # Upload Glances with Prometheus
        ####################################
        with open(
            f"{os.path.dirname(__file__)}/glances_with_prometheus/default.nix", "r"
        ) as file:
            glances_default_nix = file.read()
        self.glances_file_default = SaveFileOnRemoteHost(
            resource_name=f"{self.resource_name_prefix}_glances_default_nix",
            connection=self.pulumi_connection,
            file_contents=glances_default_nix,
            file_location="/etc/nixos/glances_with_prometheus/default.nix",
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.parent,
                delete_before_replace=True,
            ),
        )

        with open(
            f"{os.path.dirname(__file__)}/glances_with_prometheus/service.nix", "r"
        ) as file:
            glances_default_nix = file.read()
        self.glances_file_default = SaveFileOnRemoteHost(
            resource_name=f"{self.resource_name_prefix}_glances_service_nix",
            connection=self.pulumi_connection,
            file_contents=glances_default_nix,
            file_location="/etc/nixos/glances_with_prometheus/service.nix",
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.parent,
                delete_before_replace=True,
            ),
        )

    def setup_kubernetes(
        self,
        host_name: str,
        domain_name: str,
        nameserver_ip: str,
    ):
        host_name = host_name.lower()
        domain_name = domain_name.lower()

        full_host_name = f"{host_name}.{domain_name}"

        nix_cfg_file = f"{os.path.dirname(__file__)}/kubernetes/configuration.nix"
        with open(nix_cfg_file, "r") as file:
            configuration_nix = file.read()
        # Place a password for the samba-user account
        configuration_nix = configuration_nix.replace("{{HOSTNAME}}", host_name)
        configuration_nix = configuration_nix.replace(
            "{{KUBE_HOSTNAME}}", full_host_name
        )
        configuration_nix = configuration_nix.replace(
            "{{HOST_IP}}", self.pulumi_connection.host
        )
        configuration_nix = configuration_nix.replace("{{NAMESERVER}}", nameserver_ip)

        # Save the configuration.nix file
        self.configuration_nix = self._upload_configuration_nix(
            configuration_file_str=configuration_nix,
        )

        # Rebuild / switch
        # self.nixos_samba_update_channel = RunCommandsOnHost(
        self.nixos_samba_update_channel = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{self.resource_name_prefix}_RebuildSwitch",
            connection=self.pulumi_connection,
            create=[
                "echo 'Starting'",
                "sudo nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix",
                "echo 'Finished'",
            ],
            update=[
                "echo 'Starting'",
                "sudo nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix"
                "echo 'Finished'",
            ],
            # use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.configuration_nix,
                delete_before_replace=True,
            ),
        )

        # Generate the "config file and return as string
        create_config = CreateConfig(
            resource_name=f"{self.resource_name_prefix}_CreateConfig",
            create_config_args=CreateConfigArgs(
                ssh_user=self.pulumi_connection.user,
                ssh_port=int(self.pulumi_connection.port),
                ssh_host=self.pulumi_connection.host,
                kubectl_api_url=f"https://{full_host_name}:6443",
                ssh_private_key=self.pulumi_connection.private_key,
            ),
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_update_channel,
                delete_before_replace=True,
            ),
        )
        pulumi.export("kubectl", create_config.kubectl_config)
        return create_config

    def _upload_configuration_nix(
        self,
        configuration_file_str: str,
    ):
        configuration_path = "/etc/nixos/configuration.nix"
        nixos_samba_configuration_nix = SaveFileOnRemoteHost(
            resource_name=f"{self.resource_name_prefix}_ConfigurationNix",
            connection=self.pulumi_connection,
            file_contents=configuration_file_str,
            file_location=configuration_path,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.parent,
                delete_before_replace=True,
            ),
        )
        return nixos_samba_configuration_nix


class NixosSambaServer:
    def __init__(
        self,
        proxmox_ip: str,
        proxmox_username: str,
        proxmox_node_name: str,
        proxmox_private_key: PrivateKey,
        proxmox_api_token: str,
        nixos_template_vm_id: int,
        proxmox_api_token_name: str = "provider",
        samba_server_private_key: Optional[PrivateKey] = None,
        nix_hardware_configuration: str = "",
    ):
        self.proxmox_ip = proxmox_ip
        self.proxmox_username = proxmox_username
        self.proxmox_node_name = proxmox_node_name
        self.proxmox_private_key = proxmox_private_key
        self.nixos_template_vm_id = nixos_template_vm_id
        self.proxmox_api_token_name = proxmox_api_token_name
        self.proxmox_api_token = proxmox_api_token
        self.nix_hardware_configuration = nix_hardware_configuration

        # If a separate key isn't given for the Samba Server, use the same one as for proxmox
        self.samba_server_private_key = samba_server_private_key
        if self.samba_server_private_key is None:
            self.samba_server_private_key = self.proxmox_private_key

        # Create an ssh connection to proxmox
        self.pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user=self.proxmox_username,
            private_key=self.proxmox_private_key.private_key_pem,
        )

        # Create a Proxmox connection
        self.proxmox_connection_args = ProxmoxConnectionArgs(
            host=self.proxmox_ip,
            api_user=f"{self.proxmox_username}@{self.proxmox_node_name}",
            ssh_user=self.proxmox_username,
            ssh_port=22,
            ssh_private_key=self.proxmox_private_key.private_key_pem,
            api_token_name=self.proxmox_api_token_name,
            api_token_value=self.proxmox_api_token,
            api_verify_ssl=False,
        )

        return

    def create(
        self,
        samba_password: str,
        resource_name: str = "ProxmoxNixosSambaServer",
        vm_description="Nixos Samba Fileserver",
        memory: int = 16384,
        cpu_cores: int = 4,
        disk_space_in_gb: int = 1000,
        vm_id: int = 300,
        opts: pulumi.ResourceOptions = None,
        hardware_passthrough: List[str] = None,
        drive_config: str = None,
    ):
        # Process inputs
        if hardware_passthrough is None:
            hardware_passthrough = []
        if drive_config is None:
            drive_config = "{}"

        # Save file with private key on proxmox for use into this image
        key_path = f"/home/{self.proxmox_username}/proxmox_key_vm={vm_id}.pem"
        save_key = SaveFileOnRemoteHost(
            resource_name=f"{resource_name}_nixosSshKey",
            connection=self.pulumi_connection,
            file_contents=self.proxmox_private_key.public_key_openssh,
            file_location=key_path,
            opts=opts,
        )

        # Create the VM
        script = [
            # Clone the nixos template
            f"qm clone {self.nixos_template_vm_id} {vm_id} --name nixos-fileserver "
            + f'--description "{vm_description}" --full 1',
            # Set options on the template
            f"qm set {vm_id} --kvm 1 --ciuser ops",
            f"qm set {vm_id} --cores {cpu_cores}",
            f"qm set {vm_id} --balloon 0 --memory {memory}",
            f"qm set {vm_id} --scsi0 local-lvm:vm-{vm_id}-disk-0,ssd=1",
            f"qm set {vm_id} --agent 1",
            f"qm set {vm_id} --onboot 1"
            f"qm disk resize {vm_id} scsi0 {disk_space_in_gb}G",
            # Set the SSH key
            f"qm set {vm_id} --sshkeys {key_path}",
        ]

        # Add hardware passthrough (if applicable)
        for idx, hardware in enumerate(hardware_passthrough):
            # Set the PCI card (notice it's 0000:02:00 and NOT 0000:02:00.0)
            # Serial Attached SCSI controller: Broadcom / LSI SAS2008 PCI-Express Fusion-MPT SAS-2 [Falcon] (rev 03)
            # qm set 300 --hostpci0 host=0000:02:00,rombar=1
            script.append(f"qm set {vm_id} --hostpci{idx} host={hardware}")

        self.create_nixos_smb_vm = RunCommandsOnHost(
            resource_name=f"{resource_name}_proxmoxCreateNixosSambaServer",
            connection=self.pulumi_connection,
            create=script,
            delete=[f"qm destroy {vm_id}"],
            update=[f"qm destroy {vm_id}"] + script,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=save_key,
            ),
        )

        # Start the VM and pause for 60 seconds
        self.nixos_samba_server_start_vm = StartVm(
            resource_name=f"{resource_name}_StartNixOsSambaServer",
            start_vm_args=StartVmArgs(
                proxmox_connection_args=self.proxmox_connection_args,
                node_name=self.proxmox_node_name,
                vm_id=vm_id,
                wait=60,
            ),
            opts=pulumi.ResourceOptions(
                parent=self.create_nixos_smb_vm,
            ),
        )

        # Get IP of VM
        self.nixos_samba_server_ip = GetIpOfVm(
            resource_name=f"{resource_name}_GetIp",
            get_ip_of_vm_args=GetIpOfVmArgs(
                proxmox_connection_args=self.proxmox_connection_args,
                node_name=self.proxmox_node_name,
                vm_id=vm_id,
            ),
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_server_start_vm,
            ),
        )

        pulumi.export(f"{resource_name}_ip", self.nixos_samba_server_ip.ip)

        # Create ssh connection to nix samba server
        nix_samba_connection = pulumi_command.remote.ConnectionArgs(
            host=self.nixos_samba_server_ip.ip,
            port=22,
            user="ops",
            private_key=self.proxmox_private_key.private_key_pem,
        )

        ####################################
        # update the nix-channel on the VM
        ####################################
        script = [
            "nix-channel --add https://nixos.org/channels/nixos-23.11 nixos",
            "nix-channel --update",
        ]
        self.nixos_samba_update_channel = RunCommandsOnHost(
            resource_name=f"{resource_name}_UpdateChannel",
            connection=nix_samba_connection,
            create=script,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_server_ip,
                depends_on=[
                    self.proxmox_private_key,
                ],
            ),
        )

        # Save the configuration.nix file
        self.nixos_samba_configuration_nix = self._upload_configuration_nix(
            resource_name=resource_name,
            samba_password=samba_password,
            nix_samba_connection=nix_samba_connection,
        )

        ####################################
        # Upload the hardware-configuration
        ####################################
        # Generate the data.json
        nixos_samba_drive_config = SaveFileOnRemoteHost(
            resource_name=f"{resource_name}_DataJson",
            connection=nix_samba_connection,
            file_contents=drive_config,
            file_location="/etc/nixos/data.json",
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_update_channel,
                depends_on=[
                    self.proxmox_private_key,
                ],
            ),
        )

        with open(
            f"{os.path.dirname(__file__)}/hardware-configuration.nix", "r"
        ) as file:
            hardware_configuration_nix = file.read()
        nixos_samba_hardware_configuration_nix = SaveFileOnRemoteHost(
            resource_name=f"{resource_name}_DataJson",
            connection=nix_samba_connection,
            file_contents=hardware_configuration_nix,
            file_location="/etc/nixos/hardware-configuration.nix",
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_update_channel,
                depends_on=[
                    self.proxmox_private_key,
                ],
            ),
        )

        ####################################
        # Upload custom version of glances
        ####################################
        with open(
            f"{os.path.dirname(__file__)}/glances_with_prometheus/default.nix", "r"
        ) as file:
            glances_default_nix = file.read()
        nixos_samba_glances_default_nix = SaveFileOnRemoteHost(
            resource_name=f"{resource_name}_glancesDefaultNix",
            connection=nix_samba_connection,
            file_contents=glances_default_nix,
            file_location="/etc/nixos/glances_with_prometheus/default.nix",
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_update_channel,
                depends_on=[
                    self.proxmox_private_key,
                ],
            ),
        )

        with open(
            f"{os.path.dirname(__file__)}/glances_with_prometheus/service.nix", "r"
        ) as file:
            glances_service_nix = file.read()
        nixos_samba_glances_service_nix = SaveFileOnRemoteHost(
            resource_name=f"{resource_name}_glancesDefaultNix",
            connection=nix_samba_connection,
            file_contents=glances_service_nix,
            file_location="/etc/nixos/glances_with_prometheus/service.nix",
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_update_channel,
                depends_on=[
                    self.proxmox_private_key,
                ],
            ),
        )

        # Rebuild / switch
        self.nixos_samba_update_channel = RunCommandsOnHost(
            resource_name=f"{resource_name}_RebuildSwitch",
            connection=nix_samba_connection,
            create=[
                "nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix"
            ],
            update=[
                "nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix"
            ],
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_configuration_nix,
                depends_on=[
                    self.nixos_samba_server_ip,
                    self.proxmox_private_key,
                    nixos_samba_drive_config,
                    nixos_samba_hardware_configuration_nix,
                    nixos_samba_glances_default_nix,
                    nixos_samba_glances_service_nix,
                ],
            ),
        )
        return

    def _upload_configuration_nix(
        self, resource_name: str, samba_password: str, nix_samba_connection
    ):
        configuration_nix_file = f"{os.path.dirname(__file__)}/configuration.nix"
        with open(configuration_nix_file, "r") as file:
            configuration_nix = file.read()
        # Place a password for the samba-user account
        configuration_nix.replace("{{SAMBA_PASSWORD}}", samba_password)
        configuration_path = "/etc/nixos/configuration.nix"
        nixos_samba_configuration_nix = SaveFileOnRemoteHost(
            resource_name=f"{resource_name}_ConfigurationNix",
            connection=nix_samba_connection,
            file_contents=configuration_nix,
            file_location=configuration_path,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.nixos_samba_update_channel,
                depends_on=[
                    self.proxmox_private_key,
                ],
            ),
        )
        return nixos_samba_configuration_nix
