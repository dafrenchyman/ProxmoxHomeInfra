"""A Python Pulumi program"""

import os

import pulumi
import pulumi_kubernetes
import pulumi_tls
from pulumi import ResourceOptions
from pulumi_kubernetes.apiextensions import CustomResource
from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts
from pulumi_tls import PrivateKey

from home_infra.proxmox.proxmox import Proxmox
from pulumi_mrsharky.helm_charts.unifi_chart import UnifiChart
from pulumi_mrsharky.helm_charts.wikijs import Wikijs
from pulumi_mrsharky.local import Local
from pulumi_mrsharky.nixos.nixos import NixosBase
from pulumi_mrsharky.nixos_samba.nixos_samba_server import NixosSambaServer
from pulumi_mrsharky.proxmox.pfsense import PfSense
from pulumi_mrsharky.proxmox.proxmox_base import ProxmoxBase
from pulumi_mrsharky.proxmox.proxmox_nixos import ProxmoxNixOS


def generate_global_key() -> PrivateKey:
    # Create a new TLS private key
    private_key = pulumi_tls.PrivateKey(
        resource_name="globalPrivateKey", algorithm="RSA", rsa_bits=4096
    )

    # Save the private key out for use with this system's ssh.
    # NOTE: Needs full path (can't use "~" directly)
    home_folder = os.path.expanduser("~")
    private_key.private_key_pem.apply(
        lambda private_key_pem: Local.text_to_file(
            text=private_key_pem, filename=f"{home_folder}/.ssh/global_private_key.pem"
        )
    )
    private_key.private_key_openssh.apply(
        lambda private_key_ssh: Local.text_to_file(
            text=private_key_ssh, filename=f"{home_folder}/.ssh/global_private_key.ssh"
        )
    )

    # Save the public key out for use
    private_key.public_key_pem.apply(
        lambda public_key_pem: Local.text_to_file(
            text=public_key_pem, filename=f"{home_folder}/.ssh/global_public_key.pem"
        )
    )
    private_key.public_key_openssh.apply(
        lambda public_key_ssh: Local.text_to_file(
            text=public_key_ssh, filename=f"{home_folder}/.ssh/global_public_key.ssh"
        )
    )
    return private_key


def main():
    config = pulumi.Config()

    # Global configs
    timezone = config.require("timezone")

    # Generate the global private ssh key we'll use
    private_key = generate_global_key()
    pulumi.export("global_private_key", private_key.private_key_pem)
    pulumi.export("global_public_key", private_key.public_key_openssh)

    # Setup proxmox - pve1 (router box)
    proxmox_router_ip = config.require("proxmox_router_ip")
    proxmox_router_pass = config.require("proxmox_router_pass")
    proxmox_router = ProxmoxBase(
        resource_name_prefix="Router",
        proxmox_ip=proxmox_router_ip,
        proxmox_pass=proxmox_router_pass,
        node_name="pve1",
        private_key=private_key,
    )

    # Setup pfsense
    pfsense_ip = config.require("proxmox_router_pfsense_lan_ipv4_ip")
    pfsense_subnet = config.require("proxmox_router_pfsense_lan_ipv4_subnet")
    pfsense_dhcp_start = config.require(
        "proxmox_router_pfsense_lan_ipv4_dhcp_start_address"
    )
    pfsense_dhcp_end = config.require(
        "proxmox_router_pfsense_lan_ipv4_dhcp_end_address"
    )
    pfsense_admin_password = config.require("proxmox_router_pfsense_admin_password")
    pfsense_wan_passthrough = config.require("proxmox_router_pfsense_wan_passthrough")
    pfsense_lan_passthrough = config.require("proxmox_router_pfsense_lan_passthrough")
    _ = PfSense.create_vm(
        proxmox_base=proxmox_router,
        resource_name_base="Router",
        vm_id=101,
        vm_name="pfsense",
        lan_ipv4_address=pfsense_ip,
        lan_ipv4_subnet=pfsense_subnet,
        lan_ipv4_dhcp_start_address=pfsense_dhcp_start,
        lan_ipv4_dhcp_end_address=pfsense_dhcp_end,
        wan_passthrough=pfsense_wan_passthrough,
        lan_passthrough=pfsense_lan_passthrough,
        admin_password=pfsense_admin_password,
        admin_public_key=private_key.public_key_openssh,
    )

    # Create proxmox nixos
    proxmox_nixos = ProxmoxNixOS(
        resource_name_prefix="ProxmoxRouter",
        proxmox_base=proxmox_router,
    )

    # Add NixOS VM for kubernetes
    nix_os_ip = "192.168.10.51"
    nixos_kube_resource, nix_kube_connection = proxmox_nixos.create_vm(
        resource_name="NixosKube-1",
        vm_name="nixoskube1",
        vm_description="NixOSkube-1",
        memory=8192,
        cpu_cores=4,
        disk_space_in_gb=1000,
        vm_id=501,
        ip_v4=nix_os_ip,
        ip_v4_gw=pfsense_ip,
        ip_v4_cidr=24,
        start_on_boot=True,
    )

    # Setup the nixos vm
    nixos_kube_proxmox = NixosBase(
        resource_name_prefix="NixosKube-1-setup",
        pulumi_connection=nix_kube_connection,
        parent=nixos_kube_resource,
    )
    nixos_kube_config = nixos_kube_proxmox.setup_kubernetes(
        host_name="nixoskube1",
        domain_name="home.arpa",
        nameserver_ip=pfsense_ip,
    )

    # Connect to kube provider
    pulumi_kubernetes.Provider(
        resource_name="nxoskube1_kube_provider",
        kubeconfig=nixos_kube_config.kubectl_config,
    )

    # Save the kubectl config to file:
    home_folder = os.path.expanduser("~")
    nixos_kube_config.kubectl_config.apply(
        lambda kubectl_config: Local.text_to_file(
            text=kubectl_config, filename=f"{home_folder}/.kube/config"
        )
    )

    kube_provider = pulumi_kubernetes.Provider(
        resource_name="nixoskube1_kube_provider",
        kubeconfig=nixos_kube_config.kubectl_config,
    )

    # Setup ingress
    ingress = Chart(
        release_name="ingress",
        config=ChartOpts(
            chart="ingress-nginx",
            version="4.11.2",
            fetch_opts=FetchOpts(
                repo="https://kubernetes.github.io/ingress-nginx",
            ),
            values={
                "controller": {
                    "hostNetwork": "true",
                    "hostPorts": {
                        "http": 80,
                        "https": 443,
                    },
                    "service": {
                        "type": "ClusterIP",
                    },
                    "admissionWebhooks": {
                        "port": 8445,
                    },
                },
            },
        ),
        opts=ResourceOptions(
            parent=nixos_kube_config,
            provider=kube_provider,
        ),
    )

    # Setup cert-manager
    cert_manager = Chart(
        release_name="cert-manager",
        config=ChartOpts(
            chart="cert-manager",
            version="v1.15.3",
            fetch_opts=FetchOpts(
                repo="https://charts.jetstack.io",
            ),
            values={
                "crds": {
                    "enabled": "true",
                    "keep": "true",
                },
            },
        ),
        opts=ResourceOptions(
            parent=nixos_kube_config,
            provider=kube_provider,
        ),
    )

    # Self signed issuer
    # Create a self-signed Issuer
    self_signed_issuer = CustomResource(
        resource_name="selfsigned-issuer",
        api_version="cert-manager.io/v1",
        kind="Issuer",
        metadata={
            "name": "selfsigned-issuer",
            "namespace": "default",
        },
        spec={"selfSigned": {}},
        opts=ResourceOptions(
            parent=cert_manager,
            provider=kube_provider,
        ),
    )

    # Setup MetalLB
    _ = Chart(
        release_name="metallb",
        config=ChartOpts(
            chart="metallb",
            version="v0.14.8",
            fetch_opts=FetchOpts(
                repo="https://metallb.github.io/metallb",
            ),
        ),
        opts=ResourceOptions(
            parent=nixos_kube_config,
            provider=kube_provider,
        ),
    )

    # Define the IPAddressPool for MetalLB
    _ = pulumi_kubernetes.apiextensions.CustomResource(
        "ip-address-pool",
        api_version="metallb.io/v1beta1",
        kind="IPAddressPool",
        metadata={
            "name": "first-pool",
            # "namespace": "metallb-system",  # Ensure you have MetalLB installed in this namespace
        },
        spec={
            "addresses": [
                "192.168.10.240-192.168.10.250",
            ]
        },
    )

    # Setup helm charts
    Wikijs(
        config_folder_root="/kube/config",
        data_folder_root="/kube/data",
        hostname="nixoskube1.home.arpa",
        timezone=timezone,
        kube_provider=kube_provider,
        uid=1000,
        gid=100,
        node_ip=nix_os_ip,
        depends_on=[ingress],
    )

    UnifiChart(
        config_folder_root="/kube/config",
        hostname="nixoskube1.home.arpa",
        timezone=timezone,
        kube_provider=kube_provider,
        uid=1000,
        gid=100,
        node_ip=nix_os_ip,
        depends_on=[ingress, self_signed_issuer],
    )

    # Old stuff
    if False:
        # Common settings
        proxmox_ip: str = config.require("proxmox_ip")
        proxmox_pass = config.require("proxmox_pass")
        samba_hardware = config.require("samba_hardware")
        samba_pass = config.require("samba_pass")

        # Setup proxmox
        proxmox = Proxmox(proxmox_ip=proxmox_ip, proxmox_pass=proxmox_pass)
        proxmox.run()

        # Setup Nixos Samba Server
        nix_samba_server = NixosSambaServer(
            proxmox_ip=proxmox_ip,
            proxmox_username="pulumi",
            proxmox_node_name="pve",
            proxmox_private_key=proxmox.private_key,
            proxmox_api_token=proxmox.pulumi_api_token,
            nixos_template_vm_id=9001,
            proxmox_api_token_name="provider",
            nix_hardware_configuration=samba_hardware,
        )

        nix_samba_server.create(
            samba_password=samba_pass,
            resource_name="ProxmoxNixosSambaServer",
            vm_description="Nixos Samba Fileserver",
            memory=16384,
            cpu_cores=4,
            disk_space_in_gb=400000,
            vm_id=401,
            opts=pulumi.ResourceOptions(
                parent=proxmox.create_nixos_cloud_init_image,
            ),
            hardware_passthrough=["0000:02:00,rombar=0"],  # HBA Card
            drive_config=samba_hardware,
        )

    return


if __name__ == "__main__":
    main()
