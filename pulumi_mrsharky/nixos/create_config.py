from typing import Any, Optional

from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource, ResourceProvider

from pulumi_mrsharky.common.remote import RemoteMethods


class CreateConfigArgs(object):
    ssh_user: Input[str]
    ssh_port: Input[int]
    ssh_host: Input[str]
    kubectl_api_url: Input[str]
    ssh_password: Optional[Input[str]]
    ssh_private_key: Optional[Input[str]]
    is_k3s: Optional[Input[bool]]

    def __init__(
        self,
        ssh_host: Optional[Input[str]],
        ssh_user: Optional[Input[str]],
        kubectl_api_url: Input[str],
        ssh_port: Optional[Input[float]] = 22,
        ssh_password: Optional[Input[str]] = None,
        ssh_private_key: Optional[Input[str]] = None,
        is_k3s: Optional[Input[bool]] = False,
    ) -> None:
        if ssh_host is None:
            raise Exception(f"{self.__class__.__name__}: ssh_host cannot be None")
        if ssh_user is None:
            raise Exception(f"{self.__class__.__name__}: ssh_user cannot be None")
        if ssh_port is None:
            raise Exception(f"{self.__class__.__name__}: ssh_port cannot be None")

        self.ssh_host = ssh_host
        self.ssh_port = int(ssh_port)
        self.ssh_user = ssh_user
        self.ssh_password = ssh_password
        self.ssh_private_key = ssh_private_key
        self.kubectl_api_url = kubectl_api_url
        self.is_k3s = is_k3s
        return


class CreateConfigProvider(ResourceProvider):
    def _process_inputs(self, props) -> CreateConfigArgs:
        arguments = CreateConfigArgs(
            ssh_host=props.get("ssh_host"),
            ssh_user=props.get("ssh_user"),
            ssh_port=props.get("ssh_port"),
            kubectl_api_url=props.get("kubectl_api_url"),
            ssh_password=props.get("ssh_password"),
            ssh_private_key=props.get("ssh_private_key"),
            is_k3s=props.get("is_k3s"),
        )
        return arguments

    def create(self, props: Any):
        arguments = self._process_inputs(props)

        print("Creating kubectl config file")
        if arguments.is_k3s:
            kubectl_config = RemoteMethods.get_kubectl_config_from_k3(
                ssh_host=arguments.ssh_host,
                ssh_user=arguments.ssh_user,
                ssh_port=arguments.ssh_port,
                ssh_password=arguments.ssh_password,
                ssh_private_key=arguments.ssh_private_key,
                kubectl_api_url=arguments.kubectl_api_url,
            )
        else:
            kubectl_config = RemoteMethods.generate_kubectl_config(
                ssh_host=arguments.ssh_host,
                ssh_user=arguments.ssh_user,
                ssh_port=arguments.ssh_port,
                ssh_password=arguments.ssh_password,
                ssh_private_key=arguments.ssh_private_key,
                kubectl_api_url=arguments.kubectl_api_url,
            )

        if kubectl_config is None:
            raise Exception("generate_kubectl_config returned None")

        outs = {
            "kubectl_config": kubectl_config,
            "ssh_host": arguments.ssh_host,
            "ssh_user": arguments.ssh_user,
            "ssh_port": arguments.ssh_port,
            "ssh_password": arguments.ssh_password,
            "ssh_private_key": arguments.ssh_private_key,
            "kubectl_api_url": arguments.kubectl_api_url,
        }
        return CreateResult(id_=arguments.ssh_host, outs=outs)

    def delete(self, id: str, props: Any) -> None:
        outs: dict[str, Any] = {}
        _result = CreateResult(id_=str(id), outs=outs)  # noqa: F841
        return


class CreateConfig(Resource):
    kubectl_config: Output[str]
    kubectl_api_url: Output[str]
    ssh_user: Output[str]
    ssh_port: Output[int]
    ssh_host: Output[str]
    ssh_password: Optional[Output[str]]
    ssh_private_key: Optional[Output[str]]

    def __init__(
        self,
        resource_name,
        create_config_args: CreateConfigArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {"kubectl_config": None, **vars(create_config_args)}
        super().__init__(
            provider=CreateConfigProvider(),
            name=resource_name,
            props=full_args,
            opts=opts,
        )
