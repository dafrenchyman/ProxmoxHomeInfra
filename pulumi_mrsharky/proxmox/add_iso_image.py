from typing import Any, Optional

import pulumi
from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource, UpdateResult

from pulumi_mrsharky.proxmox.proxmox_connection import ProxmoxConnectionArgs
from pulumi_mrsharky.proxmox.resource_provider_proxmox import ResourceProviderProxmox


@pulumi.input_type
class AddIsoImageArgs(object):
    proxmox_connection_args: Input[ProxmoxConnectionArgs]
    url: Input[str]

    def __init__(
        self,
        proxmox_connection_args: Input[ProxmoxConnectionArgs],
        url: Input[str],
    ) -> None:
        self.proxmox_connection_args = proxmox_connection_args
        self.url = url
        return


class AddIsoImageProvider(ResourceProviderProxmox):
    def _process_inputs(self, props) -> AddIsoImageArgs:
        # Proxmox connection args
        proxmox_connection_args = super()._process_inputs(props)

        start_vm_args = AddIsoImageArgs(
            proxmox_connection_args=proxmox_connection_args,
            url=props.get("url"),
        )
        return start_vm_args

    def _common_create(self, props):
        arguments = self._process_inputs(props)

        # Set up the connection
        proxmox_connection = self._create_proxmox_connection(
            proxmox_connection_args=arguments.proxmox_connection_args
        )

        # Download the image
        local_image_name = proxmox_connection.download_iso_image(
            url=arguments.url,
        )

        results = {
            "url": arguments.url,
            "local_image_name": local_image_name,
            "proxmox_connection_args": arguments.proxmox_connection_args,
        }

        return proxmox_connection.host, results

    def create(self, props) -> CreateResult:
        id, results = self._common_create(props)
        return CreateResult(id_=id, outs=results)

    def delete(self, id: str, props: Any) -> None:
        print(props)
        arguments = self._process_inputs(props)

        # Set up the connection
        proxmox_connection = self._create_proxmox_connection(
            proxmox_connection_args=arguments.proxmox_connection_args
        )
        print("Getting local_image_name")
        local_image_name = props.get("local_image_name")

        proxmox_connection.remove_iso_image(local_image_name)
        return

    def update(self, id: str, old_props: Any, new_props: Any) -> UpdateResult:
        self.delete(id=id, props=old_props)
        _, results = self._common_create(new_props)
        return UpdateResult(outs=results)


class AddIsoImage(Resource):
    id: Output[str]
    add_iso_image_args: Output[AddIsoImageArgs]
    url: Output[int]
    local_image_name: Output[str]

    def __init__(
        self,
        resource_name,
        add_iso_image_args: AddIsoImageArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {"local_image_name": None, **vars(add_iso_image_args)}
        super().__init__(
            provider=AddIsoImageProvider(),
            name=resource_name,
            props=full_args,
            opts=opts,
        )
