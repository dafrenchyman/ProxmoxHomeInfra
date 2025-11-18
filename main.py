import json
import os
from pathlib import Path
from typing import Any

import pulumi
from pulumi import automation
from pulumi.automation import LocalWorkspaceOptions, ProjectRuntimeInfo, ProjectSettings

from pulumi_mrsharky.common.helpers import generate_private_key
from pulumi_mrsharky.nixos.nix_settings import NixSettings
from pulumi_mrsharky.nixos.nixos import NixosBase
from pulumi_mrsharky.proxmox.proxmox_base import ProxmoxBase
from pulumi_mrsharky.proxmox.proxmox_nixos import ProxmoxNixOS


# 1. Define your Pulumi program as a function
def pulumi_program():
    config = pulumi.Config()

    os.putenv("PULUMI_K8S_SUPPRESS_HELM_HOOK_WARNINGS", "TRUE")

    # Grab all the settings
    settings_str = config.require("settings")
    settings: dict[str, Any] = json.loads(settings_str)
    machine_name = settings["machine_name"]

    # Global configs
    _timezone = settings.get("timezone", "America/Los_Angeles")  # noqa: F841
    gateway = settings.get("gateway", "192.168.1.1")
    cidr = settings.get("cidr", 24)
    domain_name = settings["domain_name"]
    _nameserver_ip = settings["nameserver_ip"]  # noqa: F841

    # Generate the global private ssh key we'll use
    private_key = generate_private_key(
        resource_name=f"{machine_name}_private_key",
        filename=f"{machine_name}_server",
    )
    pulumi.export("server_private_key", private_key.private_key_pem)
    pulumi.export("server_public_key", private_key.public_key_openssh)

    # Setup proxmox - pve (Server)
    proxmox_server_ip = settings["proxmox_server_ip"]
    proxmox_server_pass = settings["proxmox_server_pass"]
    proxmox_server_name = settings["proxmox_server_name"]
    proxmox_server = ProxmoxBase(
        resource_name_prefix="Server",
        proxmox_ip=proxmox_server_ip,
        proxmox_pass=proxmox_server_pass,
        node_name=proxmox_server_name,
        private_key=private_key,
    )

    # Create proxmox nixos template
    proxmox_nixos = ProxmoxNixOS(
        resource_name_prefix="ProxmoxNixOS",
        proxmox_base=proxmox_server,
    )

    # if True:
    #     return

    # Add the NixOS VMs from the configuration
    for nixos_vm in settings.get("nixos_virtual_machines"):
        hostname = nixos_vm["hostname"]

        # Generate the VM
        nixos_kube_resource, nix_kube_connection = proxmox_nixos.create_vm(
            resource_name=f"nixos_{hostname}",
            vm_name=nixos_vm["vm_name"],
            vm_description=nixos_vm["vm_description"],
            memory=nixos_vm.get("memory"),
            bios=nixos_vm.get("bios"),
            lvm_name=nixos_vm.get("lvm_name"),
            cpu_cores=nixos_vm.get("cpu_cores", 1),
            kvm=nixos_vm.get("kvm", True),
            machine=nixos_vm.get("machine"),
            extra_args=nixos_vm.get("args", None),
            disk_space_in_gb=nixos_vm.get("disk_space_in_gb"),
            vm_id=nixos_vm["vm_id"],
            ip_v4=nixos_vm["ip"],
            ip_v4_gw=gateway,
            ip_v4_cidr=cidr,
            start_on_boot=nixos_vm.get("start_on_boot", False),
            hardware_passthrough=nixos_vm.get("hardware_passthrough", []),
        )

        # Create the connection
        nixos_proxmox = NixosBase(
            resource_name_prefix=f"{hostname}-setup",
            pulumi_connection=nix_kube_connection,
            parent=nixos_kube_resource,
        )

        # Generate nixos settings
        settings = NixSettings(**nixos_vm["settings"])

        # Setup Nixos configuration
        _nixos_config = nixos_proxmox.setup_nixos(  # noqa: F841
            settings=settings,
            domain_name=domain_name,
            drive_settings=nixos_vm.get("drive_mounts", {}),
        )
    return


# 2. Setup and run using Automation API
def main():
    # config_file = "./server_mini.json"
    config_file = "./ryzen.json"

    # Load the json config file
    with open(config_file) as json_data:
        settings = json.load(json_data)

    proxmox_server_pass = settings["proxmox_server_pass"]

    # Since using a local backend, make sure we create the folder
    pulumi_local_path = Path.home() / ".pulumi-local"
    pulumi_local_path.mkdir(exist_ok=True)

    stack_name = settings["stack_name"]
    project_name = settings["project_name"]

    # Create or select a stack
    stack = automation.create_or_select_stack(
        stack_name=stack_name,
        project_name=project_name,
        program=pulumi_program,
        opts=LocalWorkspaceOptions(
            project_settings=ProjectSettings(
                name="proxmox_server",
                runtime=ProjectRuntimeInfo(name="python"),
            ),
            env_vars={
                "PULUMI_BACKEND_URL": "file://~/.pulumi-local",
                "PULUMI_CONFIG_PASSPHRASE": proxmox_server_pass,
            },
        ),
    )

    # Cancel any in-progress update
    stack.cancel()

    # stack.refresh()

    # Destroy the stack
    # stack.destroy()
    # return

    # print("Installing plugins...")
    # stack.workspace.install_plugin("aws", "v5.0.0")  # adjust version
    # stack.workspace.install_plugin("pulumi-python")

    print("Setting config...")
    stack.set_config("settings", automation.ConfigValue(value=json.dumps(settings)))

    # preview_result = stack.preview()
    # [print(i) for i in str(preview_result).split("\\n")]
    # return

    print("Running pulumi up...")
    up_res = stack.up(on_output=print)

    print("Output:")
    print(up_res.outputs)


if __name__ == "__main__":
    main()
