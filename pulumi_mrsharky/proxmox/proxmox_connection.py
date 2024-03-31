import json
import re
import time
from typing import Dict, Optional

import pulumi
from paramiko.client import SSHClient
from proxmoxer import ProxmoxAPI
from pulumi import Input

from pulumi_mrsharky.common.remote import RemoteMethods

AVAILABLE_DISK_INTERFACES = {
    "ide": {
        "lower_bound": 0,
        "upper_bound": 3,
    },
    "sata": {
        "lower_bound": 0,
        "upper_bound": 5,
    },
    "scsi": {
        "lower_bound": 0,
        "upper_bound": 30,
    },
    "virtio": {
        "lower_bound": 0,
        "upper_bound": 15,
    },
}


@pulumi.input_type
class ProxmoxConnectionArgs(object):
    api_user: Input[str]
    host: Input[str]
    ssh_user: Input[str]
    ssh_port: Input[int] = 22
    ssh_password: Input[str] = None
    ssh_private_key: Input[str] = None
    api_token_name: Input[str] = None
    api_token_value: Input[str] = None
    api_password: Input[str] = None
    api_verify_ssl: Input[bool] = False

    def __init__(
        self,
        host: Input[str],
        api_user: Input[str],
        ssh_user: Input[str],
        ssh_port: Input[int] = 22,
        ssh_password: Optional[Input[str]] = None,
        ssh_private_key: Optional[Input[str]] = None,
        api_token_name: Optional[Input[str]] = None,
        api_token_value: Optional[Input[str]] = None,
        api_password: Optional[Input[str]] = None,
        api_verify_ssl: Input[bool] = False,
    ) -> None:
        self.host = host
        self.api_user = api_user
        self.ssh_user = ssh_user
        self.ssh_port = int(ssh_port)
        self.ssh_password = ssh_password
        self.ssh_private_key = ssh_private_key
        self.api_token_name = api_token_name
        self.api_token_value = api_token_value
        self.api_password = api_password
        self.api_verify_ssl = api_verify_ssl
        return


class ProxmoxConnection:
    api_user: Input[str]
    host: Input[str]
    ssh_user: Input[str]
    ssh_port: Input[int] = 22
    ssh_password: Input[str] = None
    ssh_private_key: Input[str] = None
    api_token_name: Input[str] = None
    api_token_value: Input[str] = None
    api_password: Input[str] = None
    api_verify_ssl: Input[bool] = False
    proxmox_ssh: SSHClient = None

    def __init__(
        self,
        proxmox_connection_args: ProxmoxConnectionArgs,
    ):
        print("ProxmoxConnection.__init__")
        print(proxmox_connection_args)
        self.host = proxmox_connection_args.host
        self.api_user = proxmox_connection_args.api_user
        self.ssh_user = proxmox_connection_args.ssh_user
        self.ssh_port = int(proxmox_connection_args.ssh_port)
        self.ssh_password = proxmox_connection_args.ssh_password
        self.ssh_private_key = proxmox_connection_args.ssh_private_key
        self.api_token_name = proxmox_connection_args.api_token_name
        self.api_token_value = proxmox_connection_args.api_token_value
        self.api_password = proxmox_connection_args.api_password
        self.api_verify_ssl = bool(proxmox_connection_args.api_verify_ssl)

        # Generate a proxmoxer connection
        if self.api_token_name is not None and self.api_token_value is not None:
            self.proxmax_api = ProxmoxAPI(
                host=self.host,
                user=self.api_user,
                token_name=self.api_token_name,
                token_value=self.api_token_value,
                verify_ssl=self.api_verify_ssl,
            )
        elif self.api_password is not None:
            self.proxmax_api = ProxmoxAPI(
                host=self.host,
                user=self.api_user,
                password=self.api_password,
                verify_ssl=self.api_verify_ssl,
            )
        else:
            raise SyntaxError("Must connect either via token or password.")

        # Generate an ssh connection
        self.proxmox_ssh = RemoteMethods.ssh_connection(
            host=self.host,
            user=self.ssh_user,
            port=self.ssh_port,
            password=self.ssh_password,
            private_key=self.ssh_private_key,
        )

    def __del__(self):
        if self.proxmox_ssh is not None:
            self.proxmox_ssh.close()

    def create_user(
        self, node_name: str, username: str, role: str = "Administrator"
    ) -> None:
        create_user = self.proxmox_ssh.exec_command(
            f"sudo pveum user add {username}@{node_name}"
        )
        create_user = create_user[1].read().decode("ascii").strip("\n")
        print(create_user)

        add_role = self.proxmox_ssh.exec_command(
            f"sudo pveum aclmod / -user {username}@{node_name} -role {role}"
        )
        add_role = add_role[1].read().decode("ascii").strip("\n")
        print(add_role)
        return

    def delete_user(self, node_name: str, username: str) -> None:
        delete_user = self.proxmox_ssh.exec_command(
            f"sudo pveum user delete {username}@{node_name}"
        )
        delete_user = delete_user[1].read().decode("ascii").strip("\n")
        print(delete_user)
        return

    def create_token(
        self,
        node_name: str,
        username: str,
        token_name: str = "provider",
        expire: int = 0,
    ) -> str:
        create_token = self.proxmox_ssh.exec_command(
            f"sudo pveum user token add {username}@{node_name} {token_name} "
            + f"--privsep=0 --expire {expire} --output-format json"
        )
        create_token_output = create_token[1].read().decode("ascii").strip("\n")
        token = json.loads(create_token_output).get("value")
        return token

    def delete_token(
        self, node_name: str, username: str, token_name: str = "provider"
    ) -> None:
        delete_token = self.proxmox_ssh.exec_command(
            f"sudo pveum user token remove {username}@{node_name} {token_name}"
        )
        delete_token = delete_token[1].read().decode("ascii").strip("\n")
        print(delete_token)
        return

    def check_node_exists(self, node_name: str) -> bool:
        # Loop on the nodes and see if we found it
        for curr_node in self.proxmax_api.nodes.get():
            if curr_node.get("node") == node_name:
                return True
        return False

    def check_vm_exists(self, node_name: str, vm_id: int):
        for vm in self.proxmax_api.nodes(node_name).qemu.get():
            if vm.get("vmid") == vm_id:
                return True
        return False

    def _qemu_guest_agent_installed(self, vm_id: int) -> bool:
        vm_config_results = self.proxmox_ssh.exec_command(
            f"qm config {vm_id} --current 1"
        )
        vm_config_results = vm_config_results[1].read().decode("ascii").strip("\n")

        # Regular expression pattern to match "agent: X" where X is a number
        pattern = r"^agent:\s*(?P<value>\d)$"
        match = re.search(pattern, vm_config_results, flags=re.MULTILINE)
        guest_installed = False
        if match is not None:
            guest_installed = bool(match.groupdict().get("value", 0))
        return guest_installed

    def qemu_guest_agent_installed(self, node_name: str, vm_id: int) -> bool:
        vm_config_results = self.proxmax_api(
            f"/nodes/{node_name}/qemu/{vm_id}/config"
        ).get()
        guest_installed = bool(vm_config_results.get("agent", 0))
        return guest_installed

    def start_vm(self, node_name: str, vm_id: int, wait: int = 30):
        # Double check that vm_id exists
        if not self.check_vm_exists(node_name=node_name, vm_id=vm_id):
            raise Exception(f"VM {vm_id} doesn't exist on the proxmox cluster")

        # Start the VM
        self.proxmax_api(f"/nodes/{node_name}/qemu/{vm_id}/status/start").post()
        # self.proxmox_ssh.exec_command(f"qm start {vm_id}")

        # Wait for the VM to start
        print(f"Waiting {wait} seconds for VM to start")
        time.sleep(wait)
        return

    def get_ip_of_vm(self, node_name: str, vm_id: int) -> str:
        # Double check that vm_id exists
        if not self.check_vm_exists(node_name=node_name, vm_id=vm_id):
            raise Exception(f"VM {vm_id} doesn't exist on the proxmox cluster")

        # First check if the qemu guest is installed (otherwise this won't work
        if not self.qemu_guest_agent_installed(node_name=node_name, vm_id=vm_id):
            raise Exception("QEMU Guest agent must be installed for this to work")

        result = self.proxmax_api(
            f"/nodes/{node_name}/qemu/{vm_id}/agent/network-get-interfaces"
        ).get()
        ip_infos = result["result"]

        # Loop through all the values and get the correct IP address
        ip_address = None
        for ip_info in ip_infos:
            if ip_info["name"] == "eth0":
                for ip in ip_info["ip-addresses"]:
                    if ip["ip-address-type"] == "ipv4":
                        ip_address = ip["ip-address"]
                        break

        if ip_address is None:
            raise Exception("Unable to find an IP address")

        return ip_address

    def check_drive_exists(self, node_name: str, drive_id: str):
        for curr_drive in self.proxmax_api.nodes(node_name).disks.list.get():
            if curr_drive.get("by_id_link") == f"/dev/disk/by-id/{drive_id}":
                return True
        return False

    def find_available_disk_interfaces(self, node_name: str, vm_id: int):
        devices = self.proxmax_api(f"nodes/{node_name}/qemu/{vm_id}/config").get()
        existing_interfaces = {}
        for curr_interface in list(AVAILABLE_DISK_INTERFACES.keys()):
            existing_interfaces[curr_interface] = []

        # Go through devices and identify what we have
        for device in list(devices.keys()):
            regex_pattern = r"(?P<interface>ide|sata|scsi|virtio)(?P<number>[0-9]+)"
            m = re.fullmatch(regex_pattern, device)
            if m:
                grouped = m.groupdict()
                interface = grouped["interface"]
                number = int(grouped["number"])
                existing_interfaces[interface].append(number)

        # Find available numbers
        available_interfaces = {}
        for curr_interface in list(AVAILABLE_DISK_INTERFACES.keys()):
            curr_available = self._find_available_numbers(
                current_numbers=existing_interfaces[curr_interface],
                lower_bound=AVAILABLE_DISK_INTERFACES[curr_interface]["lower_bound"],
                upper_bound=AVAILABLE_DISK_INTERFACES[curr_interface]["upper_bound"],
            )
            available_interfaces[curr_interface] = curr_available
        return available_interfaces

    def _find_available_numbers(
        self, current_numbers, lower_bound: int, upper_bound: int
    ):
        all_numbers = set(range(lower_bound, upper_bound + 1))
        available_numbers = list(all_numbers - set(current_numbers))
        return available_numbers

    def attach_drive_to_vm(
        self,
        node_name: str,
        vm_id: int,
        drive_id: str,
        volume_type="scsi",
        ssd_emulation=False,
    ):
        # Check Node is valid
        if not self.check_node_exists(node_name):
            raise Exception(f"Node {node_name} doesn't exist on the proxmox cluster")

        # Double check that vm_id exists
        if not self.check_vm_exists(node_name=node_name, vm_id=vm_id):
            raise Exception(f"VM {vm_id} doesn't exist on the proxmox cluster")

        # Double check the drive exists
        if not self.check_drive_exists(node_name=node_name, drive_id=drive_id):
            raise Exception(f"DriveId {drive_id} doesn't exist on the proxmox cluster")

        # Check for a valid volume type
        if volume_type not in list(AVAILABLE_DISK_INTERFACES.keys()):
            raise ValueError(f"Invalid volume type: {volume_type}")

        # Get list of all the drives, so we can see what -scsi##s are available
        available = self.find_available_disk_interfaces(
            node_name=node_name, vm_id=vm_id
        )

        # Check the device hasn't already been added
        devices = self.proxmax_api(f"nodes/{node_name}/qemu/{vm_id}/config").get()
        for key, value in devices.items():
            if value == f"/dev/disk/by-id/{drive_id}":
                raise Exception(
                    f"Drive '{drive_id}' has already been added to key: {key}"
                )

        # Get the first available interface number for the drive
        if len(available[volume_type]) == 0:
            raise Exception(f"Can no longer add drives to volume_type: {volume_type}")
        volume_type_number = available[volume_type][0]

        # Assign the scsi#/ide#/etc... to the drive
        command_to_run = f"qm set {vm_id} --{volume_type}{volume_type_number} /dev/disk/by-id/{drive_id}"

        # Add optional arguments
        if ssd_emulation:
            command_to_run = f"{command_to_run},ssd=1"

        self.proxmox_ssh.exec_command(command_to_run)
        results = {
            "interface": f"{volume_type}{volume_type_number}",
        }
        return results

    def is_hardware_present(self, node_name, vm_id, hardware_device) -> bool:
        devices = self.proxmax_api(f"nodes/{node_name}/qemu/{vm_id}/config").get()
        result = False
        if hardware_device in devices.keys():
            result = True
        return result

    def remove_drive_from_vm(
        self,
        node_name: str,
        vm_id: int,
        interface: str,
    ) -> Dict[str, str]:
        # Check Node is valid
        if not self.check_node_exists(node_name):
            raise Exception(f"Node {node_name} doesn't exist on the proxmox cluster")

        # Double check that vm_id exists
        if not self.check_vm_exists(node_name=node_name, vm_id=vm_id):
            raise Exception(f"VM {vm_id} doesn't exist on the proxmox cluster")

        if not self.is_hardware_present(
            node_name=node_name, vm_id=vm_id, hardware_device=interface
        ):
            raise Exception(f"VM {vm_id} doesn't have hardware {interface}")

        command_to_run = f"qm set {vm_id} --delete {interface}"
        results = self.proxmox_ssh.exec_command(command_to_run)
        stdin = results[0].read().decode("ascii").strip("\n")
        stdout = results[1].read().decode("ascii").strip("\n")
        stderr = results[2].read().decode("ascii").strip("\n")

        return {
            "stdin": stdin,
            "stdout": stdout,
            "stderr": stderr,
        }
