import os
import re
from typing import Any, Mapping, Optional, Sequence, Union

import pulumi
import pulumi_command
from pulumi import Output
from pulumi_command.remote import ConnectionArgs


class SaveFileOnRemoteHost(pulumi.ComponentResource):
    def __init__(
        self,
        resource_name: str,
        connection: pulumi.Input[pulumi.InputType[ConnectionArgs]],
        file_contents: Union[str, Output],
        file_location: Union[str, Output],
        file_permission: str = "644",
        use_sudo: bool = False,
        environment: Optional[pulumi.Input[Mapping[str, pulumi.Input[str]]]] = None,
        stdin: Optional[pulumi.Input[str]] = None,
        triggers: Optional[pulumi.Input[Sequence[Any]]] = None,
        opts: Optional[pulumi.ResourceOptions] = None,
    ) -> None:
        # Check the file_permissions are valid
        pattern = r"^[012467]{3}$"
        assert bool(re.match(pattern, file_permission))

        # Fix issues with single quotes in the file_contents
        # NOTE: This was a weird one to solve:
        # https://stackoverflow.com/questions/25608503/using-single-quotes-with-echo-in-bash
        # Basically, you need to surround \' with '\'' quotes. But, you need to
        # double escape it too.
        if isinstance(file_contents, str):
            file_contents = file_contents.replace("'", "'\\''")

        # Get the folder the file is in (to create the directory if not present)
        folder_path = os.path.dirname(file_location)

        # Add in sudo or not
        sudo = ""
        if use_sudo:
            sudo = "sudo"

        # Generate the Create/Delete Statement
        # If the file_contents happens to be a Pulumi Output, we have to process it
        # via an .apply(). So, do it just in case
        create = pulumi.Output.all(x=file_contents).apply(
            lambda args: (
                f"{sudo} mkdir -p {folder_path} && "
                f"{sudo} rm -f {file_location} && "
                f"echo '{args['x']}' | {sudo} tee -a {file_location} && "
                f"{sudo} chmod {file_permission} {file_location}"
            )
        )
        delete = f"{sudo} rm -f {file_location}"
        _ = pulumi.Output.all(x=file_contents).apply(
            lambda args: (
                f"{sudo} mkdir -p {folder_path} && "
                f"{sudo} rm -f {file_location} && "
                f"echo '{args['x']}' | {sudo} tee -a {file_location} && "
                f"{sudo} chmod {file_permission} {file_location}"
            )
        )

        remote_cmd = pulumi_command.remote.Command(
            resource_name=f"{resource_name}-remote-command",
            connection=connection,
            create=create,
            delete=delete,
            # update=update,
            environment=environment,
            stdin=stdin,
            triggers=triggers,
            opts=opts,
        )

        self.register_outputs(
            {
                "connection": remote_cmd.connection,
                "create": remote_cmd.create,
                "delete": remote_cmd.delete,
                "environment": remote_cmd.environment,
                "stdin": remote_cmd.stdin,
                "stdout": remote_cmd.stdout,
                "stderr": remote_cmd.stderr,
                "triggers": remote_cmd.triggers,
                "update": remote_cmd.update,
            }
        )

        super().__init__(
            t="pkg:index:SaveFileOnRemoteHost",
            name=resource_name,
            props={
                "connection": remote_cmd.connection,
                "create": remote_cmd.create,
                "delete": remote_cmd.delete,
                "environment": remote_cmd.environment,
                "stdin": remote_cmd.stdin,
                "stdout": remote_cmd.stdout,
                "stderr": remote_cmd.stderr,
                "triggers": remote_cmd.triggers,
                "update": remote_cmd.update,
            },
            opts=opts,
        )
        return
