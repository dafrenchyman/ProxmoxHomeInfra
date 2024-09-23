import json
from typing import Any, Optional, Sequence

import pulumi
import pulumi_command
import pulumi_tls
from pulumi import Input, Output

from home_infra.utils.pulumi_extras import PulumiExtras
from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnectionArgs
from pulumi_mrsharky.remote.enable_iommu import EnableIOMMU, EnableIOMMUArgs


class ProxmoxBase(pulumi.ComponentResource):
    def __init__(
        self,
        resource_name_prefix: str,
        proxmox_ip: Input[str],
        proxmox_pass: Input[str],
        node_name: Input[str],
        private_key: Input[pulumi_tls.PrivateKey],
        proxmox_api_username: Input[str] = "pulumi",
        proxmox_api_token_name: Input[str] = "provider",
        stdin: Optional[pulumi.Input[str]] = None,
        triggers: Optional[pulumi.Input[Sequence[Any]]] = None,
        opts: Optional[pulumi.ResourceOptions] = None,
    ) -> None:

        # Get inputs
        self.resource_name_prefix = resource_name_prefix
        self.proxmox_ip = proxmox_ip
        self.proxmox_pass = proxmox_pass
        self.node_name = node_name
        self.private_key = private_key
        self.proxmox_api_username = proxmox_api_username
        self.proxmox_api_token_name = proxmox_api_token_name

        super().__init__(
            t="pkg:index:Proxmox",
            name=resource_name_prefix,
            props={
                "proxmox_ip": self.proxmox_ip,
                "proxmox_pass": self.proxmox_pass,
                "node_name": self.node_name,
                "private_key": self.private_key,
                "proxmox_api_username": self.proxmox_api_username,
                "proxmox_api_token_name": self.proxmox_api_token_name,
            },
            opts=opts,
        )

        # Remove Enterprise Repo
        self._remove_enterprise_repo()

        # Setup pulumi user
        self._setup_pulumi_user()

        # Setup API Token
        self._setup_api_token()

        ###############################################
        # Enable IOMMU
        # NOTE: This will also reboot the machine.
        ###############################################
        self.enable_iommu = EnableIOMMU(
            resource_name=f"{self.resource_name_prefix}ProxmoxEnableIOMMU",
            enable_iommu_args=EnableIOMMUArgs(
                host=self.proxmox_ip,
                port=22,
                user="root",
                password=self.proxmox_pass,
            ),
            opts=pulumi.ResourceOptions(parent=self.sub_component_create_token),
        )

        # Create a re-usable proxmox connection
        self.api_user = pulumi.Output.all(
            username=self.proxmox_api_username,
            node_name=self.node_name,
        ).apply(lambda args: (f"{args['username']}@{args['node_name']}"))

        ###############################################
        # Create helpers
        ###############################################

        # Create a proxmox_connection_args helper
        self.proxmox_connection_args = ProxmoxConnectionArgs(
            host=self.proxmox_ip,
            api_user=self.api_user,
            ssh_user=self.proxmox_api_username,
            ssh_port=22,
            ssh_private_key=self.private_key.private_key_pem,
            api_token_name=self.proxmox_api_token_name,
            api_token_value=self.pulumi_api_token,
            api_verify_ssl=False,
        )

        # Create a pulumi connection helper
        self.pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user=self.proxmox_api_username,
            private_key=self.private_key.private_key_pem,
        )

        # clean it all up
        outputs = {
            "proxmox_ip": self.proxmox_ip,
            "proxmox_pass": self.proxmox_pass,
            "node_name": self.node_name,
            "private_key": self.private_key,
            "pulumi_api_username": self.proxmox_api_username.apply(lambda u: u),
            "pulumi_api_token": self.pulumi_api_token,
            "proxmox_connection_args": self.proxmox_connection_args,
        }

        self.register_outputs(outputs)

        return

    def _remove_enterprise_repo(self) -> None:
        self.remove_enterprise_repo = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{self.resource_name_prefix}ProxmoxRemoveEnterpriseRepo",
            connection=pulumi_command.remote.ConnectionArgs(
                host=self.proxmox_ip,
                port=22,
                user="root",
                password=self.proxmox_pass,
            ),
            create=(
                "sed -i 's/deb https/# deb https/g' /etc/apt/sources.list.d/pve-enterprise.list && "
                "sed -i 's/deb https/# deb https/g' /etc/apt/sources.list.d/ceph.list "
            ),
            delete=(
                "sed -i 's/# deb https/deb https/g' /etc/apt/sources.list.d/pve-enterprise.list && "
                "sed -i 's/# deb https/deb https/g' /etc/apt/sources.list.d/ceph.list "
            ),
            opts=pulumi.ResourceOptions(
                depends_on=[self.private_key],
                delete_before_replace=True,
            ),
        )

        return

    def _setup_pulumi_user(self) -> None:
        proxmox_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user="root",
            password=self.proxmox_pass,
        )

        # Install sudo
        self.sub_component_install_sudo = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{self.resource_name_prefix}ProxmoxInstallSudo",
            connection=proxmox_connection,
            create="apt-get update && apt-get install -y sudo",
            delete="apt-get purge -y sudo",
            opts=pulumi.ResourceOptions(
                depends_on=[self.private_key],
                parent=self.remove_enterprise_repo,
                delete_before_replace=True,
            ),
        )

        # Create the pulumi user
        create_stmt = self.proxmox_api_username.apply(
            lambda username: (f"useradd --create-home -s /bin/bash {username}")
        )
        delete_stmt = self.proxmox_api_username.apply(
            lambda username: (f"userdel --remove {username}")
        )
        self.sub_component_create_pulumi_user = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{self.resource_name_prefix}ProxmoxCreatePulumiUser",
            connection=proxmox_connection,
            create=create_stmt,
            delete=delete_stmt,
            opts=pulumi.ResourceOptions(
                depends_on=[self.private_key],
                parent=self.sub_component_install_sudo,
                delete_before_replace=True,
            ),
        )

        # Add ssh key
        create_stmt = pulumi.Output.all(
            username=self.proxmox_api_username,
            key=self.private_key.public_key_openssh,
        ).apply(
            lambda args: (
                f"mkdir -p /home/{args['username']}/.ssh/ && "
                + f"echo '{args['key']}' >> /home/{args['username']}/.ssh/authorized_keys"
            )
        )
        self.sub_component_add_pulumi_ssh_key = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{self.resource_name_prefix}ProxmoxAddSshKeyForPulumiUser",
            connection=proxmox_connection,
            create=create_stmt,
            # TODO: Come up with good delete
            delete=None,
            opts=pulumi.ResourceOptions(
                depends_on=self.private_key,
                parent=self.sub_component_create_pulumi_user,
                delete_before_replace=True,
            ),
        )

        # Add pulumi to sudo
        create_stmt = pulumi.Output.all(
            username=self.proxmox_api_username,
        ).apply(
            lambda args: (
                "mkdir -p /etc/sudoers.d/ && "
                + f"echo '{args['username']} ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/{args['username']} && "
                + f"chown root:root /etc/sudoers.d/{args['username']} && "
                + f"chmod 440 /etc/sudoers.d/{args['username']}"
            )
        )
        delete_stmt = self.proxmox_api_username.apply(
            lambda username: f"rm /etc/sudoers.d/{username}"
        )
        self.sub_component_add_pulumi_to_sudo = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{self.resource_name_prefix}ProxmoxAddPulumiToSudo",
            connection=proxmox_connection,
            create=create_stmt,
            delete=delete_stmt,
            opts=pulumi.ResourceOptions(
                parent=self.sub_component_install_sudo,
                depends_on=[self.private_key, self.sub_component_add_pulumi_ssh_key],
                delete_before_replace=True,
            ),
        )
        return

    def _setup_api_token(self) -> None:
        pulumi_connection = pulumi_command.remote.ConnectionArgs(
            host=self.proxmox_ip,
            port=22,
            user=self.proxmox_api_username,
            private_key=self.private_key.private_key_pem,
        )

        # Add a pulumi user
        create_stmt = pulumi.Output.all(
            username=self.proxmox_api_username, node_name=self.node_name
        ).apply(
            lambda args: (
                f"sudo pveum user add {args['username']}@{args['node_name']} && "
                + f"sudo pveum aclmod / -user {args['username']}@{args['node_name']} -role Administrator"
            )
        )
        delete_stmt = pulumi.Output.all(
            username=self.proxmox_api_username, node_name=self.node_name
        ).apply(
            lambda args: (
                f"sudo pveum user delete {args['username']}@{args['node_name']}"
            )
        )
        self.sub_component_create_api_user = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{self.resource_name_prefix}ProxmoxCreatePulumiApiUser",
            connection=pulumi_connection,
            create=create_stmt,
            delete=delete_stmt,
            opts=pulumi.ResourceOptions(
                parent=self.sub_component_add_pulumi_to_sudo,
                depends_on=[self.sub_component_create_pulumi_user],
                delete_before_replace=True,
            ),
        )

        # Create token
        create_stmt = pulumi.Output.all(
            username=self.proxmox_api_username,
            node_name=self.node_name,
            token_name=self.proxmox_api_token_name,
        ).apply(
            lambda args: (
                f"sudo pveum user token add {args['username']}@{args['node_name']} "
                + f"{args['token_name']} --privsep=0 --expire 0 --output-format json"
            )
        )
        delete_stmt = pulumi.Output.all(
            username=self.proxmox_api_username,
            node_name=self.node_name,
            token_name=self.proxmox_api_token_name,
        ).apply(
            lambda args: (
                f"sudo pveum user token remove {args['username']}@{args['node_name']} "
                + f"{args['token_name']}"
            )
        )
        self.sub_component_create_token = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{self.resource_name_prefix}ProxmoxCreatePulumiApiToken",
            connection=pulumi_connection,
            create=create_stmt,
            delete=delete_stmt,
            opts=pulumi.ResourceOptions(
                parent=self.sub_component_create_api_user,
                depends_on=[],
                delete_before_replace=True,
            ),
        )
        self.pulumi_api_token = self.get_api_token(
            self.sub_component_create_token.stdout
        )
        # pulumi.export(f"{self.resource_name}_API_TOKEN", self.pulumi_api_token)

        return

    @staticmethod
    def get_api_token(input: Output) -> pulumi.Output[str]:
        output = input.apply(lambda input: json.loads(input).get("value"))
        return output
