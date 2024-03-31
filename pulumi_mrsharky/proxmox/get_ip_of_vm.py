from typing import Any, Optional

from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource, UpdateResult

from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnectionArgs
from pulumi_mrsharky.proxmox.resource_provider_proxmox import ResourceProviderProxmox


class GetIpOfVmArgs(object):
    proxmox_connection_args: Input[ProxmoxConnectionArgs]
    node_name: Input[str]
    vm_id: Input[int]

    def __init__(
        self,
        proxmox_connection_args: Input[ProxmoxConnectionArgs],
        node_name: str,
        vm_id: int,
    ) -> None:
        self.proxmox_connection_args = proxmox_connection_args
        self.node_name = node_name
        self.vm_id = vm_id
        return


class GetIpOfVmProvider(ResourceProviderProxmox):

    def _process_inputs(self, props) -> GetIpOfVmArgs:
        # Proxmox connection args
        proxmox_connection_args = super()._process_inputs(props)

        arguments = GetIpOfVmArgs(
            proxmox_connection_args=proxmox_connection_args,
            # vm related arguments
            node_name=props.get("node_name"),
            vm_id=int(props.get("vm_id")),
        )
        return arguments

    def _common_create(self, props):
        arguments = self._process_inputs(props)

        # Setup the connection
        proxmox_connection = self._create_proxmox_connection(
            proxmox_connection_args=arguments.proxmox_connection_args
        )

        # Get the IP
        ip_address = proxmox_connection.get_ip_of_vm(
            node_name=arguments.node_name,
            vm_id=arguments.vm_id,
        )

        results = {
            "ip": ip_address,
        }

        return proxmox_connection.host, results

    def create(self, props) -> CreateResult:
        id, results = self._common_create(props)
        return CreateResult(id_=id, outs=results)

    def delete(self, id: str, props: Any) -> None:
        return

    def update(self, id: str, old_props: Any, new_props: Any) -> UpdateResult:
        self.delete(id=id, props=old_props)
        _, results = self._common_create(new_props)
        return UpdateResult(outs=results)


class GetIpOfVm(Resource):
    id: Output[str]
    ip: Output[str]
    node_name: Output[str]
    proxmox_connection_args: Output[ProxmoxConnectionArgs]
    vm_id: Output[int]

    def __init__(
        self,
        resource_name,
        get_ip_of_vm_args: GetIpOfVmArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {"ip": None, **vars(get_ip_of_vm_args)}
        super().__init__(
            provider=GetIpOfVmProvider(), name=resource_name, props=full_args, opts=opts
        )
