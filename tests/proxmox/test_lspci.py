import os

from home_infra.proxmox.proxmox import Proxmox


def test_nvidia_lspci_regex():
    # Load the Nvidia example
    nvidia_lspci_file_path = os.path.dirname(os.path.abspath(__file__))
    with open(f"{nvidia_lspci_file_path}/nvidia_lspci_stdout.txt", "r") as file:
        data = file.read()

    # Run the regex on it
    nvidia_lspci_pci_ids = Proxmox.pci_ids_reg_ex(data)
    assert nvidia_lspci_pci_ids == "10de:1b82,10de:10f0"

    return


if __name__ == "__main__":
    test_nvidia_lspci_regex()
