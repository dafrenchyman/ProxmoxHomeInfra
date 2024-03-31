import io
import socket
import time

import paramiko
from paramiko.client import SSHClient


class RemoteMethods:

    @staticmethod
    def wait_for_remote_host(
        host: str,
        user: str,
        port: int,
        password: str = None,
        private_key: str = None,
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
        password: str = None,
        private_key: str = None,
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
    def ssh_connection(
        host: str, user: str, port: int, password: str = None, private_key: str = None
    ) -> SSHClient:
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        if password is not None:
            ssh.connect(
                hostname=host, username=user, port=port, password=password, timeout=10
            )
        elif private_key is not None:
            pkey = paramiko.RSAKey.from_private_key(io.StringIO(private_key))
            ssh.connect(hostname=host, username=user, port=port, pkey=pkey, timeout=10)
        if password is None and private_key is None:
            raise Exception("Must either have a password or private_key")
        return ssh
