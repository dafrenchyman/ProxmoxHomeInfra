import io
import socket
import time
from typing import Optional

import paramiko
from paramiko.client import SSHClient
from pulumi import Input

IOMMU_GRUB = {
    "INTEL": "quiet intel_iommu=on iommu=pt pcie_acs_override=downstream",
    "AMD": "quiet amd_iommu=on iommu=pt pcie_acs_override=downstream",
}

IOMMU_UEFI = {
    "INTEL": "quiet intel_iommu=on iommu=pt",
    "AMD": "quiet intel_iommu=on iommu=pt",
}


class RemoteMethods:
    @staticmethod
    def ssh_connection(
        host: Optional[Input[str]],
        user: Optional[Input[str]],
        port: Optional[Input[int]],
        password: Optional[Input[str]] = None,
        private_key: Optional[Input[str]] = None,
    ) -> SSHClient:
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        # SSH > Password
        if private_key is not None:
            pkey = paramiko.RSAKey.from_private_key(io.StringIO(private_key))
            ssh.connect(hostname=host, username=user, port=port, pkey=pkey, timeout=10)
        elif password is not None:
            ssh.connect(
                hostname=host, username=user, port=port, password=password, timeout=10
            )
        if password is None and private_key is None:
            raise Exception("Must either have a password or private_key")
        return ssh

    @staticmethod
    def wait_for_remote_host(
        host: str,
        user: str,
        port: int,
        password: Optional[str] = None,
        private_key: Optional[str] = None,
        max_wait_for_reboot_in_seconds: int = 300,
    ) -> float:
        # Loop and wait
        connected = False
        start_time = time.time()
        finish_time = -100.0
        ssh: SSHClient
        while (
            start_time + max_wait_for_reboot_in_seconds > time.time()
            or connected is True
        ):
            try:
                ssh = RemoteMethods.ssh_connection(
                    host=host,
                    user=user,
                    port=port,
                    password=password,
                    private_key=private_key,
                )
                connected = True
                finish_time = time.time() - start_time
                break
            except (
                paramiko.ssh_exception.NoValidConnectionsError,
                paramiko.ssh_exception.SSHException,
                TimeoutError,
                socket.timeout,
                socket.error,
            ):
                time.sleep(5)

        if not connected:
            raise Exception(f"Host '{host}', took to long to reboot.")

        # Cleanup the SSH connection
        ssh.close()
        return finish_time

    @staticmethod
    def reboot_function(
        host: str,
        user: str,
        port: int,
        password: Optional[str] = None,
        private_key: Optional[str] = None,
        max_wait_for_reboot_in_seconds: int = 300,
        use_sudo: bool = False,
    ) -> float:
        # Connect using the proper creds and reboot the computer
        ssh = RemoteMethods.ssh_connection(
            host=host, user=user, port=port, password=password, private_key=private_key
        )
        command_to_run = "/sbin/reboot -f > /dev/null 2>&1 &"
        if use_sudo:
            command_to_run = f"sudo {command_to_run}"
        ssh.exec_command(command_to_run)
        ssh.close()

        # Wait for ssh to close
        time.sleep(30)

        finish_time = RemoteMethods.wait_for_remote_host(
            host=host,
            user=user,
            port=port,
            password=password,
            private_key=private_key,
            max_wait_for_reboot_in_seconds=max_wait_for_reboot_in_seconds,
        )
        return finish_time

    @staticmethod
    def enable_iommu(
        host: Input[str],
        user: Input[str],
        port: Input[int] = 22,
        password: Optional[Input[str]] = None,
        private_key: Optional[Input[str]] = None,
    ):
        # Connect using the proper creds
        ssh = RemoteMethods.ssh_connection(
            host=host, user=user, port=port, password=password, private_key=private_key
        )

        # Figure out the type of CPU
        command_to_run = """
            cpu_info=$(lscpu)
            if echo "$cpu_info" | grep -q "GenuineIntel"; then
                echo "INTEL"
            elif echo "$cpu_info" | grep -q "AuthenticAMD"; then
                echo "AMD"
            else
                echo "UNKNOWN"
            fi
            """
        detect_cpu = ssh.exec_command(command_to_run)

        cpu_type = detect_cpu[1].read().decode("ascii").strip()
        print(f"CPU Type: {cpu_type}")
        if cpu_type not in IOMMU_GRUB.keys():
            raise Exception(f"Not an Intel or AMD CPU: {cpu_type}")

        #############################
        # Modify GRUB boot loader
        #   This file is always here
        #############################
        grub_modify = (
            r"sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/"
            rf"c\GRUB_CMDLINE_LINUX_DEFAULT=\"{IOMMU_GRUB[cpu_type]}\"' /etc/default/grub && "
            "sudo chmod 644 /etc/default/grub && "
            "sudo update-grub && "
            "sudo update-initramfs -u -k all"
        )
        ssh.exec_command(grub_modify)

        #############################
        # Modify UEFI Boot Loader
        #   This file may not be here
        #############################

        # Check if the UEFI file "/etc/kernel/cmdline" exists
        command_to_run = """
            FILE="/etc/kernel/cmdline"
            if [[ -f "$FILE" ]]; then
                echo "True"
            else
                echo ""
            fi
            """
        detect_file = ssh.exec_command(command_to_run)
        cmdline_file_exists = bool(detect_file[1].read().decode("ascii").strip())

        if cmdline_file_exists:
            cmdline_modify = (
                r"sudo sed -i '/^root=ZFS=rpool/ROOT/pve-1 boot=zfs/"
                rf"c\root=ZFS=rpool/ROOT/pve-1 boot=zfs {IOMMU_UEFI[cpu_type]}' /etc/kernel/cmdline && "
                "sudo chmod 644 /etc/kernel/cmdline && "
                "sudo pve-efiboot-tool refresh "
            )
            ssh.exec_command(cmdline_modify)

        # Create "/etc/modules-load.d/vfio.conf" to add vfio modules
        cmdline_create_vfio_conf = (
            r'sudo echo -e "vfio\nvfio_iommu_type1\nvfio_pci\nvfio_virqfd" '
            r"> /etc/modules-load.d/vfio.conf"
        )
        ssh.exec_command(cmdline_create_vfio_conf)

        # Blacklist drivers "/etc/modprobe.d/blacklist.conf"
        cmdline_blacklist = (
            r'sudo echo -e "blacklist amdgpu\nblacklist radeon\nblacklist '
            r'nouveau\nblacklist nvidia*\nblacklist i915" > /etc/modprobe.d/blacklist.conf'
        )
        ssh.exec_command(cmdline_blacklist)
        ssh.exec_command("sudo update-initramfs -u -k all")

        # Close the session
        ssh.close()

        # Reboot Machine
        finish_time = RemoteMethods.reboot_function(
            host=host,
            user=user,
            port=port,
            password=password,
            private_key=private_key,
            max_wait_for_reboot_in_seconds=300,
        )
        return finish_time

    @staticmethod
    def disable_iommu(
        host: Input[str],
        user: Input[str],
        port: Input[int],
        password: Optional[Input[str]] = None,
        private_key: Optional[Input[str]] = None,
    ):
        # Connect using the proper creds
        ssh = RemoteMethods.ssh_connection(
            host=host, user=user, port=port, password=password, private_key=private_key
        )

        grub_modify = (
            r"sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/"
            r"c\GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"' /etc/default/grub && "
            "sudo chmod 644 /etc/default/grub && "
            "sudo update-grub && "
            "sudo update-initramfs -u -k all"
        )
        ssh.exec_command(grub_modify)

        #############################
        # Modify UEFI Boot Loader
        #   This file may not be here
        #############################

        # Check if the UEFI file "/etc/kernel/cmdline" exists
        command_to_run = """
            FILE="/etc/kernel/cmdline"
            if [[ -f "$FILE" ]]; then
                echo "True"
            else
                echo ""
            fi
            """
        detect_file = ssh.exec_command(command_to_run)
        cmdline_file_exists = bool(detect_file[1].read().decode("ascii").strip())

        if cmdline_file_exists:
            cmdline_modify = (
                r"sudo sed -i '/^root=ZFS=rpool/ROOT/pve-1 boot=zfs/"
                r"c\root=ZFS=rpool/ROOT/pve-1 boot=zfs' /etc/kernel/cmdline && "
                "sudo chmod 644 /etc/kernel/cmdline && "
                "sudo pve-efiboot-tool refresh "
            )
            ssh.exec_command(cmdline_modify)

        # Remove vfio modules
        ssh.exec_command("sudo rm /etc/modules-load.d/vfio.conf")

        # Remove Blacklist
        ssh.exec_command("sudo rm /etc/modprobe.d/blacklist.conf")

        # Close the session
        ssh.close()

        # Reboot machine
        finish_time = RemoteMethods.reboot_function(
            host=host,
            user=user,
            port=port,
            password=password,
            private_key=private_key,
            max_wait_for_reboot_in_seconds=300,
            use_sudo=True,
        )
        return finish_time

    @staticmethod
    def copy_file(
        host: str,
        user: str,
        port: int,
        local_path: str,
        remote_path: str,
        password: str = None,
        private_key: str = None,
    ):
        # Connect using the proper creds
        ssh = RemoteMethods.ssh_connection(
            host=host, user=user, port=port, password=password, private_key=private_key
        )

        sftp = ssh.open_sftp()

        results = sftp.put(
            localpath=local_path,
            remotepath=remote_path,
        )

        # Close up
        sftp.close()
        ssh.close()

        return results

    @staticmethod
    def base64_file(ssh: SSHClient, filename: str):
        command_to_run = f"""
            FILE="{filename}"
            if [[ -f "$FILE" ]]; then
                echo "True"
            else
                echo ""
            fi
        """

        """
        FILE="/var/lib/kubernetes/secrets/ca.pem"
        if [[ -f "$FILE" ]]; then
            echo "True"
        else
            echo ""
        fi
        """

        detect_file = ssh.exec_command(command_to_run)
        cmdline_file_exists = not bool(detect_file[1].read().decode("ascii").strip())

        if cmdline_file_exists:
            raise Exception(f"File '{filename}' doesn't exist")

        base64_cmd = rf"sudo base64 -w 0 {filename}"
        raw_results = ssh.exec_command(base64_cmd)
        results = raw_results[1].read().decode("ascii")
        return results

    @staticmethod
    def generate_kubectl_config(
        ssh_host: Optional[Input[str]],
        ssh_user: Optional[Input[str]],
        ssh_port: Optional[Input[int]],
        kubectl_api_url: Optional[Input[str]],
        ssh_password: Optional[Input[str]] = None,
        ssh_private_key: Optional[Input[str]] = None,
    ) -> str:
        # Connect using the proper creds
        ssh = RemoteMethods.ssh_connection(
            host=ssh_host,
            user=ssh_user,
            port=ssh_port,
            password=ssh_password,
            private_key=ssh_private_key,
        )

        # Certificate Authority
        ca_pem = RemoteMethods.base64_file(ssh, r"/var/lib/kubernetes/secrets/ca.pem")
        cluster_admin = RemoteMethods.base64_file(
            ssh, r"/var/lib/kubernetes/secrets/cluster-admin.pem"
        )
        # "/var/lib/kubernetes/secrets/cluster-admin.pem"

        cluster_admin_key = RemoteMethods.base64_file(
            ssh, "/var/lib/kubernetes/secrets/cluster-admin-key.pem"
        )
        ssh.close()

        # Create the file
        kubectl_config = rf"""apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: {ca_pem}
    server: {kubectl_api_url}
  name: local
contexts:
- context:
    cluster: local
    user: cluster-admin
  name: local
current-context: local
kind: Config
preferences: {{}}
users:
- name: cluster-admin
  user:
    client-certificate-data: {cluster_admin}
    client-key-data: {cluster_admin_key}

        """
        return kubectl_config
