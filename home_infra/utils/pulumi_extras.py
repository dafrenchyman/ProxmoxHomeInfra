import os
import re
from typing import Any, List, Mapping, Optional, Sequence, Union

import pulumi
import pulumi_command
from pulumi import Output
from pulumi_command.remote import ConnectionArgs


class PulumiExtras:
    @staticmethod
    def save_file_on_remote_host(
        resource_name: str,
        connection: pulumi.Input[pulumi.InputType[ConnectionArgs]],
        file_contents: Union[str, Output],
        file_location: str,
        file_permission: str = "644",
        use_sudo: bool = False,
        environment: Optional[pulumi.Input[Mapping[str, pulumi.Input[str]]]] = None,
        stdin: Optional[pulumi.Input[str]] = None,
        triggers: Optional[pulumi.Input[Sequence[Any]]] = None,
        opts: Optional[pulumi.ResourceOptions] = None,
    ) -> pulumi_command.remote.Command:
        # Check the file_permissions are valid
        pattern = r"^[012467]{3}$"
        assert bool(re.match(pattern, file_permission))

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
                f"mkdir -p {folder_path} && "
                f"echo '{args['x']}' | {sudo} tee -a {file_location} && "
                f"{sudo} chmod {file_permission} {file_location}"
            )
        )
        delete = f"{sudo} rm {file_location}"

        create_file = PulumiExtras.run_command_on_remote_host(
            resource_name=resource_name,
            connection=connection,
            create=create,
            delete=delete,
            environment=environment,
            stdin=stdin,
            triggers=triggers,
            opts=opts,
        )
        return create_file

    @staticmethod
    def run_commands_on_remote_host(
        resource_name: str,
        connection: pulumi.Input[pulumi.InputType[ConnectionArgs]],
        create: List[Union[str, Output]],
        delete: Optional[List[Union[str, Output]]] = None,
        update: Optional[List[Union[str, Output]]] = None,
        environment: Optional[pulumi.Input[Mapping[str, pulumi.Input[str]]]] = None,
        stdin: Optional[pulumi.Input[str]] = None,
        triggers: Optional[pulumi.Input[Sequence[Any]]] = None,
        opts: Optional[pulumi.ResourceOptions] = None,
    ) -> pulumi_command.remote.Command:
        # Convert input statements to pulumi.Output
        new_create = Output.all(*create).apply(lambda parts: " && ".join(parts))
        if delete is not None:
            new_delete = Output.all(*delete).apply(lambda parts: " && ".join(parts))
        else:
            new_delete = None
        if update is not None:
            new_update = Output.all(*update).apply(lambda parts: " && ".join(parts))
        else:
            new_update = None

        result = PulumiExtras.run_command_on_remote_host(
            resource_name=resource_name,
            connection=connection,
            create=new_create,
            delete=new_delete,
            update=new_update,
            environment=environment,
            stdin=stdin,
            triggers=triggers,
            opts=opts,
        )
        return result

    @staticmethod
    def run_command_on_remote_host(
        resource_name: str,
        connection: pulumi.Input[pulumi.InputType[ConnectionArgs]],
        create: Union[str, Output],
        delete: Optional[Union[str, Output]] = None,
        update: Optional[Union[str, Output]] = None,
        environment: Optional[pulumi.Input[Mapping[str, pulumi.Input[str]]]] = None,
        stdin: Optional[pulumi.Input[str]] = None,
        triggers: Optional[pulumi.Input[Sequence[Any]]] = None,
        opts: Optional[pulumi.ResourceOptions] = None,
    ) -> pulumi_command.remote.Command:
        # Convert input statements to pulumi.Output
        if isinstance(create, str):
            create = pulumi.Output.all(x=create).apply(lambda args: f"{args['x']}")
        if isinstance(delete, str):
            delete = pulumi.Output.all(x=delete).apply(lambda args: f"{args['x']}")
        if isinstance(update, str):
            update = pulumi.Output.all(x=update).apply(lambda args: f"{args['x']}")

        # If no update_stmt was given, but we have a delete statement
        # Make the update run the delete first, then create
        if delete is not None and update is None:
            update = pulumi.Output.all(
                create_stmt=create.apply(lambda u: u),
                delete_stmt=delete.apply(lambda u: u),
            ).apply(lambda args: f"{args['delete_stmt']} && {args['create_stmt']}")

        remote_cmd = pulumi_command.remote.Command(
            resource_name=resource_name,
            connection=connection,
            create=create,
            delete=delete,
            update=update,
            environment=environment,
            stdin=stdin,
            triggers=triggers,
            opts=opts,
        )
        return remote_cmd

    @staticmethod
    def reboot_remote_host(
        resource_name: str,
        connection: pulumi.Input[pulumi.InputType[ConnectionArgs]],
        seconds_to_wait_for_reboot: int = 120,
        use_sudo: bool = False,
        opts: Optional[pulumi.ResourceOptions] = None,
    ):
        reboot_cmd = "reboot now"
        if use_sudo:
            reboot_cmd = "sudo reboot now"

        # Reboot
        reboot_now = PulumiExtras.run_command_on_remote_host(
            resource_name=f"{resource_name}RebootCommand",
            connection=connection,
            create=reboot_cmd,
            opts=opts,
        )

        # Since it can take time for the PC to reboot, force a delay.
        delay = pulumi_command.local.Command(
            resource_name=f"{resource_name}Delay",
            create=f"sleep {seconds_to_wait_for_reboot}",
            opts=pulumi.ResourceOptions(
                parent=reboot_now,
            ),
        )

        check_back_up = pulumi_command.remote.Command(
            resource_name=f"{resource_name}CheckBackUp",
            connection=connection,
            create="echo 'Server is back online'",
            opts=pulumi.ResourceOptions(
                parent=delay,
            ),
        )
        return check_back_up
