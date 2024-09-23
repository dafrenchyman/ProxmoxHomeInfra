from typing import Any, Dict, List, Optional

import pulumi
from pulumi import Input, Output, ResourceOptions
from pulumi.dynamic import CreateResult, Resource

from pulumi_mrsharky.pfsense.resource_provider_pfsense import (
    PfsenseApiConnectionArgs,
    ResourceProviderPfsense,
)


@pulumi.input_type
class PfsenseUpdateUserArgs(object):
    pf_sense_api_connection_args: Input[PfsenseApiConnectionArgs]
    username: Input[str]
    password: Optional[Input[str]]
    privileges: Optional[Input[List[str]]]
    disable: Optional[Input[bool]]
    description: Optional[Input[str]]
    expires: Optional[Input[str]]
    certs: Optional[Input[List[str]]]
    authorized_keys: Optional[Input[str]]
    ipsecpsk: Optional[Input[str]]

    def __init__(
        self,
        pf_sense_api_connection_args: PfsenseApiConnectionArgs,
        username: str,
        password: str,
        privileges: List[str] = None,
        disable: Optional[bool] = False,
        description: str = None,
        expires: str = None,
        certs: List[str] = None,
        authorized_keys: str = None,
        ipsecpsk: str = None,
    ) -> None:
        if username is None:
            raise Exception(f"{self.__class__.__name__}: host cannot be None")
        self.pf_sense_api_connection_args = pf_sense_api_connection_args
        self.username = username
        self.password = password
        self.privileges = privileges
        self.disable = bool(disable)
        self.description = description
        self.expires = expires
        self.certs = certs
        self.authorized_keys = authorized_keys
        self.ipsecpsk = ipsecpsk
        return


class PfSenseUpdateUserProvider(ResourceProviderPfsense):
    def _process_inputs(self, props) -> PfsenseUpdateUserArgs:
        pf_sense_api_connection_args = super()._process_inputs(props)

        arguments = PfsenseUpdateUserArgs(
            pf_sense_api_connection_args=pf_sense_api_connection_args,
            username=props.get("username"),
            password=props.get("password"),
            privileges=props.get("privileges"),
            disable=props.get("disable"),
            description=props.get("description"),
            expires=props.get("expires"),
            certs=props.get("certs"),
            authorized_keys=props.get("authorized_keys"),
            ipsecpsk=props.get("ipsecpsk"),
        )
        return arguments

    def create(self, props: Any) -> CreateResult:
        arguments = self._process_inputs(props)
        api = self._create_pfsense_api_connection(
            arguments.pf_sense_api_connection_args
        )

        # Run the reboot function that waits
        print(f"Updating username: {arguments.username}")
        api.update_user(
            username=arguments.username,
            password=arguments.password,
            privileges=arguments.privileges,
            disable=arguments.disable,
            description=arguments.description,
            expires=arguments.expires,
            certs=arguments.certs,
            authorized_keys=arguments.authorized_keys,
            ipsecpsk=arguments.ipsecpsk,
        )

        outs = {
            "pf_sense_api_connection_args": arguments.pf_sense_api_connection_args,
            "username": arguments.username,
            "password": arguments.password,
            "privileges": arguments.privileges,
            "disable": arguments.disable,
            "description": arguments.description,
            "expires": arguments.expires,
            "certs": arguments.certs,
            "authorized_keys": arguments.authorized_keys,
            "ipsecpsk": arguments.ipsecpsk,
        }
        return CreateResult(id_=arguments.username, outs=outs)

    def delete(self, id: str, props: Any) -> CreateResult:
        arguments = self._process_inputs(props)

        outs = {
            "pf_sense_api_connection_args": arguments.pf_sense_api_connection_args,
            "username": arguments.username,
            "password": arguments.password,
            "privileges": arguments.privileges,
            "disable": arguments.disable,
            "description": arguments.description,
            "expires": arguments.expires,
            "certs": arguments.certs,
            "authorized_keys": arguments.authorized_keys,
            "ipsecpsk": arguments.ipsecpsk,
        }
        return CreateResult(id_=arguments.username, outs=outs)


class PfsenseUpdateUser(Resource):
    test: Output[str]
    pf_sense_api_connection_args: Output[Dict]
    username: Output[str]
    password: Optional[Output[str]]
    privileges: Optional[Output[List[str]]]
    disable: Optional[Output[bool]]
    description: Optional[Output[str]]
    expires: Optional[Output[str]]
    certs: Optional[Output[List[str]]]
    authorized_keys: Optional[Output[str]]
    ipsecpsk: Optional[Output[str]]

    def __init__(
        self,
        resource_name,
        update_user_args: PfsenseUpdateUserArgs,
        opts: Optional[ResourceOptions] = None,
    ):
        full_args = {"test": None, **vars(update_user_args)}
        super().__init__(PfSenseUpdateUserProvider(), resource_name, full_args, opts)
