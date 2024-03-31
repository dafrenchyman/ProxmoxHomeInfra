from pulumi.dynamic import ResourceProvider

from pulumi_mrsharky.proxmox.proxmox_connection import (
    ProxmoxConnection,
    ProxmoxConnectionArgs,
)


class ResourceProviderProxmox(ResourceProvider):
    proxmox_connection = None

    def _process_inputs(self, props) -> ProxmoxConnectionArgs:
        proxmox_connection_args = self._create_proxmox_connection_args(props=props)
        return proxmox_connection_args

    def _create_proxmox_connection_args(self, props) -> ProxmoxConnectionArgs:
        proxmox_connection_args = ProxmoxConnectionArgs(
            api_user=props.get("proxmox_connection_args").get("api_user"),
            host=props.get("proxmox_connection_args").get("host"),
            ssh_user=props.get("proxmox_connection_args").get("ssh_user"),
            ssh_port=int(props.get("proxmox_connection_args").get("ssh_port")),
            ssh_password=props.get("proxmox_connection_args").get("ssh_pasword"),
            ssh_private_key=props.get("proxmox_connection_args").get("ssh_private_key"),
            api_token_name=props.get("proxmox_connection_args").get("api_token_name"),
            api_token_value=props.get("proxmox_connection_args").get("api_token_value"),
            api_password=props.get("proxmox_connection_args").get("api_password"),
            api_verify_ssl=props.get("proxmox_connection_args").get("api_verify_ssl"),
        )
        return proxmox_connection_args

    def _create_proxmox_connection(self, proxmox_connection_args) -> ProxmoxConnection:

        # Set up the connection
        return ProxmoxConnection(proxmox_connection_args=proxmox_connection_args)
