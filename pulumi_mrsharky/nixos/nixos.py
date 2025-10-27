import json
import os
from pathlib import Path
from typing import Any, List, Optional

import pulumi
import pulumi_command
import pulumi_kubernetes
from pulumi import Resource
from pulumi_tls import PrivateKey

from home_infra.utils.pulumi_extras import PulumiExtras
from pulumi_mrsharky.local import Local
from pulumi_mrsharky.nixos.create_config import CreateConfig, CreateConfigArgs
from pulumi_mrsharky.nixos.nix_settings import NixSettings
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

        # Copy over all nix configuration files (.nix)
        self._copy_configurations()

        # Optional kubernetes setup
        self.kube_config = None
        self.kube_provider = None

        return

    def _upload_local_files(
        self, local_dir: str, upload_location_root: str, resource_name_suffix: str
    ):
        # Get all the files and paths in the local_dir
        base_path = Path(local_dir)

        file_counter = 0
        for path in base_path.rglob("*"):
            relative_path = path.relative_to(base_path)
            if path.is_file():
                file_counter += 1
                curr_suffix = f"{resource_name_suffix}_{file_counter}"
                # Create the upload path
                upload_location = str(Path(upload_location_root) / relative_path)
                local_file_path = str(path)
                self._upload_local_file(
                    local_file=local_file_path,
                    upload_location=upload_location,
                    resource_name_suffix=curr_suffix,
                )

        return

    def _upload_local_file(
        self, local_file: str, upload_location: str, resource_name_suffix: str
    ):
        with open(local_file, "r") as file:
            file_contents = file.read()
        SaveFileOnRemoteHost(
            resource_name=f"{self.resource_name_prefix}_{resource_name_suffix}",
            connection=self.pulumi_connection,
            file_contents=file_contents,
            file_location=upload_location,
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.parent,
                delete_before_replace=True,
            ),
        )

    def _copy_configurations(self):
        config_location = Path(__file__).resolve().parent / "config"

        self._upload_local_files(
            local_dir=config_location,
            upload_location_root="/etc/nixos/",
            resource_name_suffix="nix_config",
        )
        return

    def setup_nixos(
        self,
        settings: NixSettings,
        drive_settings: Optional[dict[str, Any]] = None,
        domain_name: Optional[str] = None,
    ):
        # Save settings.json on remote host
        nixos_upload_settings = SaveFileOnRemoteHost(
            resource_name=f"{self.resource_name_prefix}_settings",
            connection=self.pulumi_connection,
            file_contents=settings.to_json(),
            file_location="/etc/nixos/settings.json",
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.parent,
            ),
        )

        # Setup a default hard_drive setup
        if drive_settings is None:
            drive_settings = {}
        nixos_upload_settings = SaveFileOnRemoteHost(
            resource_name=f"{self.resource_name_prefix}_datajson",
            connection=self.pulumi_connection,
            file_contents=json.dumps(drive_settings, indent=2),
            file_location="/etc/nixos/data.json",
            use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=self.parent,
            ),
        )

        #  --extra-experimental-features flakes
        self.rebuild_switch = PulumiExtras.run_commands_on_remote_host(
            resource_name=f"{self.resource_name_prefix}_RebuildSwitch",
            connection=self.pulumi_connection,
            create=[
                (
                    "sudo nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix  --option experimental-features 'nix-command flakes'"  # noqa: E501
                ),
            ],
            update=[
                (
                    "sudo nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix  --option experimental-features 'nix-command flakes'"  # noqa: E501
                ),
            ],
            # use_sudo=True,
            opts=pulumi.ResourceOptions(
                parent=nixos_upload_settings,
                delete_before_replace=True,
            ),
        )

        if settings.kube_single_node_enable:
            if domain_name is None:
                raise Exception("domain_name required if setting up Kubernetes")

            _full_host_name = (  # noqa: F841
                f"{settings.kube_nix_hostname}.{domain_name}"
            )
            ip_address = settings.kube_master_ip

            # Generate the config file and return as string
            # Kube config file can be found in: /etc/rancher/k3s/k3s.yaml on server
            self.kube_config = CreateConfig(
                resource_name=f"{self.resource_name_prefix}_CreateConfig",
                create_config_args=CreateConfigArgs(
                    ssh_user=self.pulumi_connection.user,
                    ssh_port=self.pulumi_connection.port,
                    ssh_host=self.pulumi_connection.host,
                    kubectl_api_url=f"https://{ip_address}:6443",
                    ssh_private_key=self.pulumi_connection.private_key,
                ),
                opts=pulumi.ResourceOptions(
                    parent=self.rebuild_switch,
                    delete_before_replace=True,
                ),
            )
            pulumi.export("kubectl", self.kube_config)

            # Connect to kube provider
            self.kube_provider = pulumi_kubernetes.Provider(
                resource_name=f"{self.resource_name_prefix}_KubeProvider",
                kubeconfig=self.kube_config.kubectl_config,
                opts=pulumi.ResourceOptions(
                    parent=self.kube_config,
                ),
            )

            pulumi.export("kube_provider", self.kube_provider)

            # Save the kubectl config to file:
            # NOTE: Useful command to generate it manually:
            # sudo KUBECONFIG=/etc/kubernetes/cluster-admin.kubeconfig kubectl config view --minify --flatten
            home_folder = os.path.expanduser("~")
            self.kube_config.kubectl_config.apply(
                lambda x: Local.text_to_file(
                    text=x,
                    filename=f"{home_folder}/.kube/{self.resource_name_prefix}_config",
                )
            )

            return

        return

    def _upload_configuration_nix(
        self,
        configuration_file_str: str,
    ):
        configuration_path = "/etc/nixos/configuration.nix"
        nixos_configuration_nix = SaveFileOnRemoteHost(
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
        return nixos_configuration_nix


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
            "nix-channel --add https://nixos.org/channels/nixos-25.05 nixos",
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
