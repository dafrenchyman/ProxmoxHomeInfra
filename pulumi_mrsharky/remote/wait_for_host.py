from typing import Optional

import pulumi
from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource, ResourceProvider

from pulumi_mrsharky.common.remote import RemoteMethods


@pulumi.input_type
class WaitForHostArgs(object):
    user: Input[str]
    port: Input[int]
    host: Input[str]
    max_wait_for_reboot_in_seconds: Input[int]
    password: Optional[Input[str]]
    private_key: Optional[Input[str]]

    def __init__(
        self,
        host: str,
        user: str,
        port: int = 22,
        max_wait_for_reboot_in_seconds: int = 300,
        password: str = None,
        private_key: str = None,
    ) -> None:
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.private_key = private_key
        self.max_wait_for_reboot_in_seconds = max_wait_for_reboot_in_seconds
        return


class WaitForHostProvider(ResourceProvider):
    def create(self, props):
        host = props.get("host")
        port = int(
            props.get("port", 22)
        )  # It will be a float when we get it, need to cast to int
        user = props.get("user")
        password = props.get("password", None)
        private_key = props.get("private_key", None)
        max_wait_for_reboot_in_seconds = int(
            props.get("max_wait_for_reboot_in_seconds", 300)
        )

        # Wait for remote host
        finish_time = RemoteMethods.wait_for_remote_host(
            host=host,
            user=user,
            port=port,
            password=password,
            private_key=private_key,
            max_wait_for_reboot_in_seconds=max_wait_for_reboot_in_seconds,
        )
        return CreateResult(id_=host, outs={"finish_time": finish_time})


class WaitForHost(Resource):
    finish_time: Output[float]

    def __init__(
        self,
        resource_name,
        wait_for_host_args: WaitForHostArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {"finish_time": None, **vars(wait_for_host_args)}
        super().__init__(WaitForHostProvider(), resource_name, full_args, opts)
