from typing import Any, Optional, Union

from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource, ResourceProvider

from pulumi_mrsharky.common.remote import RemoteMethods


class EnableIOMMUArgs(object):
    user: Input[str]
    port: Input[int]
    host: Input[str]
    password: Optional[Input[str]]
    private_key: Optional[Input[str]]

    def __init__(
        self,
        host: str,
        user: str,
        port: int = 22,
        password: Union[Output[str], str] = None,
        private_key: Union[Output[str], str] = None,
    ) -> None:
        if host is None:
            raise Exception(f"{self.__class__.__name__}: host cannot be None")
        if user is None:
            raise Exception(f"{self.__class__.__name__}: user cannot be None")
        if port is None:
            raise Exception(f"{self.__class__.__name__}: port cannot be None")

        self.host = host
        self.port = int(port)
        self.user = user
        self.password = password
        self.private_key = private_key
        return


class EnableIOMMUProvider(ResourceProvider):
    def _process_inputs(self, props) -> EnableIOMMUArgs:
        arguments = EnableIOMMUArgs(
            host=props.get("host"),
            user=props.get("user"),
            port=props.get("port"),
            password=props.get("password"),
            private_key=props.get("private_key"),
        )
        return arguments

    def create(self, props: Any):
        arguments = self._process_inputs(props)

        # Run the reboot function that waits
        print("Enabling IOMMU")
        finish_time = RemoteMethods.enable_iommu(
            host=arguments.host,
            user=arguments.user,
            port=arguments.port,
            password=arguments.password,
            private_key=arguments.private_key,
        )

        outs = {"finish_time": finish_time}
        return CreateResult(id_=arguments.host, outs=outs)

    def delete(self, id: str, props: Any) -> None:
        arguments = self._process_inputs(props)
        finish_time = RemoteMethods.disable_iommu(
            host=arguments.host,
            user=arguments.user,
            port=arguments.port,
            password=arguments.password,
            private_key=arguments.private_key,
        )

        outs = {"finish_time": finish_time}
        return CreateResult(id_=arguments.host, outs=outs)


class EnableIOMMU(Resource):
    finish_time: Output[float]
    user: Output[str]
    port: Output[int]
    host: Output[str]
    password: Optional[Output[str]]
    private_key: Optional[Output[str]]

    def __init__(
        self,
        resource_name,
        enable_iommu_args: EnableIOMMUArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {"finish_time": None, **vars(enable_iommu_args)}
        super().__init__(EnableIOMMUProvider(), resource_name, full_args, opts)
