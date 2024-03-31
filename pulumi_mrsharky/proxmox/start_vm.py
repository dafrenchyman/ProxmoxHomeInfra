from typing import Any, Optional

from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource, UpdateResult

from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnectionArgs
from pulumi_mrsharky.proxmox.resource_provider_proxmox import ResourceProviderProxmox


class StartVmArgs(object):
    proxmox_connection_args: Input[ProxmoxConnectionArgs]
    node_name: Input[str]
    vm_id: Input[int]
    wait: Input[int]

    def __init__(
        self,
        proxmox_connection_args: ProxmoxConnectionArgs,
        node_name: str,
        vm_id: int,
        wait: int = 30,
    ) -> None:
        self.proxmox_connection_args = proxmox_connection_args
        self.node_name = node_name
        self.vm_id = int(vm_id)
        self.wait = int(wait)
        return


class StartVmProvider(ResourceProviderProxmox):

    def _process_inputs(self, props) -> StartVmArgs:
        # Proxmox connection args
        proxmox_connection_args = super()._process_inputs(props)

        start_vm_args = StartVmArgs(
            proxmox_connection_args=proxmox_connection_args,
            node_name=props.get("node_name"),
            vm_id=int(props.get("vm_id")),
            wait=int(props.get("wait")),
        )
        return start_vm_args

    def _common_create(self, props):
        arguments = self._process_inputs(props)

        # Set up the connection
        proxmox_connection = self._create_proxmox_connection(
            proxmox_connection_args=arguments.proxmox_connection_args
        )

        # Start the VM
        proxmox_connection.start_vm(
            node_name=arguments.node_name,
            vm_id=arguments.vm_id,
            wait=arguments.wait,
        )

        results = {
            "node_name": arguments.node_name,
            "vm_id": arguments.vm_id,
            "wait": arguments.wait,
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


class StartVm(Resource):
    id: Output[str]
    node_name: Output[str]
    proxmox_connection_args: Output[ProxmoxConnectionArgs]
    vm_id: Output[int]
    wait: Output[int]

    def __init__(
        self,
        resource_name,
        start_vm_args: StartVmArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {**vars(start_vm_args)}
        super().__init__(
            provider=StartVmProvider(),
            name=resource_name,
            props=full_args,
            opts=opts,
        )
