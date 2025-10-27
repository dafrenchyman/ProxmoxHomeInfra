from pathlib import Path

import pulumi_tls
from pulumi_tls import PrivateKey

from pulumi_mrsharky.local import Local


def generate_private_key(
    resource_name: str,
    filename: str,
) -> PrivateKey:
    # Create a new TLS private key
    private_key = pulumi_tls.PrivateKey(
        resource_name=resource_name, algorithm="RSA", rsa_bits=4096
    )

    # Save the private key out for use with this system's ssh.
    # NOTE: Needs full path (can't use "~" directly)
    home_folder = Path.home()  # Automatically gives the user's home directory
    ssh_folder = home_folder / ".ssh"  # Combines home_folder and .ssh paths

    # Create folder if it doesn't exist
    ssh_folder.mkdir(exist_ok=True)

    private_key.private_key_pem.apply(
        lambda private_key_pem: Local.text_to_file(
            text=private_key_pem,
            filename=f"{home_folder}/.ssh/{filename}_private_key.pem",
        )
    )
    private_key.private_key_openssh.apply(
        lambda private_key_ssh: Local.text_to_file(
            text=private_key_ssh,
            filename=f"{home_folder}/.ssh/{filename}_private_key.ssh",
        )
    )

    # Save the public key out for use
    private_key.public_key_pem.apply(
        lambda public_key_pem: Local.text_to_file(
            text=public_key_pem,
            filename=f"{home_folder}/.ssh/{filename}_public_key.pem",
        )
    )
    private_key.public_key_openssh.apply(
        lambda public_key_ssh: Local.text_to_file(
            text=public_key_ssh,
            filename=f"{home_folder}/.ssh/{filename}_public_key.ssh",
        )
    )
    return private_key
