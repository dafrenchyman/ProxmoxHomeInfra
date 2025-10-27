from typing import Any, List, Mapping, Optional, Sequence, Union

import pulumi
import pulumi_command
from pulumi import Output
from pulumi_command.remote import ConnectionArgs


class RunCommandsOnHost(pulumi.ComponentResource):
    def __init__(
        self,
        resource_name: str,
        connection: pulumi.Input[pulumi.InputType[ConnectionArgs]],
        create: List[str] | List[Output[str]],
        delete: Optional[Union[List[str], List[Output[str]]]] = None,
        update: Optional[Union[List[str], List[Output[str]]]] = None,
        environment: Optional[pulumi.Input[Mapping[str, pulumi.Input[str]]]] = None,
        stdin: Optional[pulumi.Input[str]] = None,
        triggers: Optional[pulumi.Input[Sequence[Any]]] = None,
        use_sudo: bool = False,
        opts: Optional[pulumi.ResourceOptions] = None,
    ) -> None:
        # Convert input statements to pulumi.Output
        create_stmt = self._generate_outputs_from_string_list(create, use_sudo)
        if delete is not None:
            delete_stmt = self._generate_outputs_from_string_list(delete, use_sudo)
        else:
            delete_stmt = None
        if update is not None:
            update_stmt = self._generate_outputs_from_string_list(update, use_sudo)
        else:
            update_stmt = None

        # If no update_stmt was given, but we have a delete statement
        # Make the update run the delete first, then create
        if delete is not None and update is None:
            update_stmt = pulumi.Output.all(
                create_stmt=create_stmt.apply(lambda u: u),
                delete_stmt=delete_stmt.apply(lambda u: u),
            ).apply(lambda args: f"{args['delete_stmt']} && {args['create_stmt']}")

        remote_cmd = pulumi_command.remote.Command(
            resource_name=f"{resource_name}-remote-command",
            connection=connection,
            create=create_stmt,
            delete=delete_stmt,
            update=update_stmt,
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
            t="pkg:index:RunCommandsOnHost",
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

    def _generate_outputs_from_string_list(
        self,
        statements: List[str] | List[Output[str]],
        use_sudo: bool = False,
    ):
        combined_statements = pulumi.Output.all(x="").apply(lambda args: f"{args['x']}")
        sudo = ""
        if use_sudo:
            sudo = "sudo"
        for idx, statement in enumerate(statements):
            combined_statements = pulumi.Output.all(
                x=combined_statements,
                y=statement,
            ).apply(lambda args: f"{args['x']} {sudo} {args['y']}")
            if idx < len(statements) - 1:
                combined_statements = pulumi.Output.all(
                    x=combined_statements, y=" && "
                ).apply(lambda args: f"{args['x']} {args['y']}")
        return combined_statements
