from typing import Optional

import pulumi
from pulumi import Input
from pulumi.dynamic import ResourceProvider

from pulumi_mrsharky.pfsense.pfsense_api import PfsenseApi


@pulumi.input_type
class PfsenseApiConnectionArgs(object):
    username: Input[str]
    password: Input[str]
    url: Input[str]
    verify_cert: Optional[Input[bool]]

    def __init__(
        self,
        username: Input[str],
        password: Input[str],
        url: Input[str],
        verify_cert: Optional[Input[bool]] = True,
    ) -> None:
        self.username = username
        self.password = password
        self.url = url
        self.verify_cert = bool(verify_cert)
        return


class ResourceProviderPfsense(ResourceProvider):
    proxmox_connection = None

    def _process_inputs(self, props) -> PfsenseApiConnectionArgs:
        pfsense_connection_args = self._create_pfsense_api_connection_args(props=props)
        return pfsense_connection_args

    def _create_pfsense_api_connection_args(self, props) -> PfsenseApiConnectionArgs:
        pfsense_api_connection_args = PfsenseApiConnectionArgs(
            username=props.get("pf_sense_api_connection_args").get("username"),
            password=props.get("pf_sense_api_connection_args").get("password"),
            url=props.get("pf_sense_api_connection_args").get("url"),
            verify_cert=bool(
                props.get("pf_sense_api_connection_args").get("verify_cert")
            ),
        )
        return pfsense_api_connection_args

    def _create_pfsense_api_connection(
        self, pfsense_api_connection_args: PfsenseApiConnectionArgs
    ) -> PfsenseApi:

        # Set up the connection
        return PfsenseApi(
            username=pfsense_api_connection_args.username,
            password=pfsense_api_connection_args.password,
            url=pfsense_api_connection_args.url,
            verify_cert=pfsense_api_connection_args.verify_cert,
        )
