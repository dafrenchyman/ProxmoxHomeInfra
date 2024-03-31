from typing import Any, Optional

from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource, UpdateResult

from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnectionArgs
from pulumi_mrsharky.proxmox.resource_provider_proxmox import ResourceProviderProxmox


class AddPhysicalDiskToVmArgs(object):
    proxmox_connection_args: Input[ProxmoxConnectionArgs]
    volume_type: Input[str] = "scsi"
    node_name: Input[str]
    vm_id: Input[int]
    drive_id: Input[str]
    ssd_emulation: Input[bool] = False
    api_verify_ssl: Input[bool] = False

    def __init__(
        self,
        proxmox_connection_args: Input[ProxmoxConnectionArgs],
        node_name: Input[str],
        vm_id: Input[int],
        drive_id: Input[str],
        volume_type: Input[str] = "scsi",
        ssd_emulation: Input[bool] = False,
        api_verify_ssl: Input[bool] = False,
    ) -> None:
        self.proxmox_connection_args = proxmox_connection_args
        self.node_name = node_name
        self.vm_id = vm_id
        self.drive_id = drive_id
        self.volume_type = volume_type
        self.ssd_emulation = ssd_emulation
        self.api_verify_ssl = api_verify_ssl
        return


class AddPhysicalDiskToVmProvider(ResourceProviderProxmox):
    def _process_inputs(self, props) -> AddPhysicalDiskToVmArgs:
        # Proxmox connection args
        proxmox_connection_args = super()._process_inputs(props)

        arguments = AddPhysicalDiskToVmArgs(
            proxmox_connection_args=proxmox_connection_args,
            # vm related arguments
            node_name=props.get("node_name"),
            vm_id=int(props.get("vm_id")),
            drive_id=props.get("drive_id"),
            ssd_emulation=props.get("ssd_emulation", False),
            volume_type=props.get("volume_type", "scsi"),
        )
        return arguments

    def _common_create(self, props):
        arguments = self._process_inputs(props)

        # Setup the connection
        proxmox_connection = self._create_proxmox_connection(
            proxmox_connection_args=arguments.proxmox_connection_args
        )

        # Add the drive
        results = proxmox_connection.attach_drive_to_vm(
            node_name=arguments.node_name,
            vm_id=arguments.vm_id,
            drive_id=arguments.drive_id,
            volume_type=arguments.volume_type,
            ssd_emulation=arguments.ssd_emulation,
        )
        return arguments.host, results

    def create(self, props) -> CreateResult:
        id, results = self._common_create(props)
        return CreateResult(id_=id, outs=results)

    def delete(self, id: str, props: Any) -> None:
        arguments = self._process_inputs(props)
        interface = props.get("interface")
        proxmox_connection = arguments.get_proxmox_connection()
        _ = proxmox_connection.remove_drive_from_vm(
            node_name=arguments.node_name,
            vm_id=arguments.vm_id,
            interface=interface,
        )
        return

    def update(self, id: str, old_props: Any, new_props: Any) -> UpdateResult:
        self.delete(id=id, props=old_props)
        _, results = self._common_create(new_props)
        return UpdateResult(outs=results)


class AddPhysicalDiskToVm(Resource):
    id: Output[str]
    proxmox_connection_args: Output[ProxmoxConnectionArgs]
    volume_type: Output[str]
    node_name: Output[str]
    vm_id: Output[int]
    drive_id: Output[str]
    ssd_emulation: Output[bool]
    stdin: Output[str]
    stdout: Output[str]
    stderr: Output[str]
    api_verify_ssl: Output[bool]

    def __init__(
        self,
        resource_name,
        add_physical_disk_to_vm_args: AddPhysicalDiskToVmArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {
            "stdin": None,
            "stdout": None,
            "stderr": None,
            **vars(add_physical_disk_to_vm_args),
        }
        super().__init__(
            provider=AddPhysicalDiskToVmProvider(),
            name=resource_name,
            props=full_args,
            opts=opts,
        )
