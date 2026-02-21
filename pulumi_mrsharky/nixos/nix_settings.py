import json
from dataclasses import asdict, dataclass
from enum import Enum
from typing import Any, Optional


class GpuType(str, Enum):
    AMD = "amd"
    NVIDIA = "nvidia"
    SOFTWARE = "software"


@dataclass
class NixSettings:

    # Global Settings
    timezone: Optional[str] = None
    gateway: Optional[str] = None
    domain_name: Optional[str] = None
    nameserver_ip: Optional[str] = None
    username: Optional[str] = None
    password: Optional[str] = None

    internal_network_ip: Optional[str] = None
    internal_network_cidr: Optional[int] = None

    # uefi or bios
    boot_mode: str = "bios"

    # Cloud-init
    cloud_init: Optional[dict[str, Any]] = None

    # Customized version of glances
    custom_glances_enable: bool = False

    # Useful Desktop Apps
    desktop_apps_enable: bool = False

    ollama_enable: bool = False

    # Setup GPU
    gpu_enable: bool = False
    gpu_type: GpuType = GpuType.SOFTWARE

    # Setup GOW Wolf
    gow_wolf: Optional[dict[str, Any]] = None

    # Fileserver settings
    samba_server: Optional[dict[str, Any]] = None

    # Samba mount settings
    mount_samba: Optional[dict[str, Any]] = None

    # K3s
    single_node_k3s: Optional[dict[str, Any]] = None

    # Kubernetes Settings
    kube_single_node_enable: bool = False
    kube_master_ip: Optional[str] = None
    kube_nix_hostname: Optional[str] = None
    kube_master_hostname: Optional[str] = None
    kube_resolv_conf_nameserver: Optional[str] = None
    kube_master_api_server_port: Optional[int] = None
    kube_enable_unifi_ports: bool = False
    kube_enable_plex_ports: bool = False

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def _remove_none(self, obj):
        if isinstance(obj, dict):
            return {k: self._remove_none(v) for k, v in obj.items() if v is not None}
        elif isinstance(obj, list):
            return [self._remove_none(v) for v in obj if v is not None]
        else:
            return obj

    def to_json(self) -> str:
        as_dict = self.to_dict()
        cleaned = self._remove_none(as_dict)

        # Dump and clean
        as_json = json.dumps(
            cleaned,
            indent=4,
            allow_nan=False,
        )

        return as_json
