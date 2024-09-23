from typing import Optional, Union

from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource, ResourceProvider

from pulumi_mrsharky.common.remote import RemoteMethods


class RebootArgs(object):
    user: Input[str]
    port: Input[int]
    host: Input[str]
    max_wait_for_reboot_in_seconds: Input[int]
    password: Optional[Input[str]]
    private_key: Optional[Input[str]]
    use_sudo: Optional[Input[bool]]

    def __init__(
        self,
        host: str,
        user: str,
        port: int = 22,
        max_wait_for_reboot_in_seconds: int = 300,
        password: Union[Output[str], str] = None,
        private_key: Union[Output[str], str] = None,
        use_sudo: bool = False,
    ) -> None:
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.private_key = private_key
        self.max_wait_for_reboot_in_seconds = max_wait_for_reboot_in_seconds
        self.use_sudo = use_sudo
        return


class RebootProvider(ResourceProvider):
    def create(self, props):
        host = props.get("host", None)
        port = int(
            props.get("port", 22)
        )  # It will be a float when we get it, need to cast to int
        user = props.get("user", None)
        password = props.get("password", None)
        private_key = props.get("private_key", None)
        max_wait_for_reboot_in_seconds = int(
            props.get("max_wait_for_reboot_in_seconds", 300)
        )
        use_sudo = bool(props.get("use_sudo"))

        # Run the reboot function that waits
        print("running reboot function")
        finish_time = RemoteMethods.reboot_function(
            host=host,
            user=user,
            port=port,
            password=password,
            private_key=private_key,
            max_wait_for_reboot_in_seconds=max_wait_for_reboot_in_seconds,
            use_sudo=use_sudo,
        )

        return CreateResult(id_=host, outs={"finish_time": finish_time})


class Reboot(Resource):
    finish_time: Output[float]

    def __init__(
        self,
        resource_name,
        reboot_args: RebootArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {"finish_time": None, **vars(reboot_args)}
        super().__init__(RebootProvider(), resource_name, full_args, opts)
