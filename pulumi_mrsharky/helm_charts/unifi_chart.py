import pulumi_kubernetes
from pulumi import ResourceOptions
from pulumi_kubernetes.apiextensions import CustomResource
from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts

from pulumi_mrsharky.common.kube_helpers import KubeHelpers


def UnifiChart(
    config_folder_root: str,
    hostname: str,
    timezone: str,
    depends_on,
    kube_provider: pulumi_kubernetes.Provider,
    node_ip: str,
    uid=1000,
    gid=100,
):
    # Create a certificate resource
    certificate = CustomResource(
        "unifi-tls",
        api_version="cert-manager.io/v1",
        kind="Certificate",
        metadata={"name": "unifi-tls", "namespace": "default"},
        spec={
            "secretName": "unifi-tls-secret",  # pragma: allowlist secret
            "issuerRef": {"name": "selfsigned-issuer"},
            "commonName": f"unifi.{hostname}",
            "dnsNames": [
                f"unifi.{hostname}",
                "unifi.192.168.10.51.nip.io",
            ],
            "duration": "2160h",  # 90 days
            "renewBefore": "360h",  # Renew 15 days before expiration
        },
    )

    pv, pvc, config_map = KubeHelpers.create_pvc(
        name="unifi-config",
        path=f"{config_folder_root}/unifi",
        size="4Gi",
        access_mode="ReadWriteMany",
        mount_path="/unifi",
    )

    unifi_chart = Chart(
        "unifi",
        config=ChartOpts(
            chart="unifi",
            version="5.1.2",
            fetch_opts=FetchOpts(
                repo="https://k8s-at-home.com/charts/",
            ),
            values={
                "image": {
                    "repository": "jacobalberty/unifi",
                    "tag": "v8.4.62",
                    "pullPolicy": "IfNotPresent",
                },
                "env": {
                    "TZ": timezone,
                    "PUID": uid,
                    "PGID": gid,
                    "UNIFI_UID": uid,
                    "UNIFI_GID": gid,
                },
                "persistence": {
                    "data": config_map,
                },
                "hostNetwork": "true",
                "dnsPolicy": "ClusterFirstWithHostNet",
                "service": {
                    "main": {
                        # "enabled": "true",
                        # "type": "LoadBalancer",
                        "ports": {
                            "http": {
                                "enabled": "true",
                                "port": 8443,
                                "nodePort": 8443,
                                "targetPort": 8443,
                                "protocol": "HTTPS",
                            },
                            "controller": {
                                "enabled": "true",
                                "port": 8080,
                                "nodePort": 8080,
                                "targetPort": 8080,
                                "protocol": "TCP",
                            },
                            "portal-http": {
                                "enabled": "true",
                                "port": 8880,
                                "nodePort": 8880,
                                "targetPort": 8880,
                                "protocol": "HTTP",
                            },
                            "portal-https": {
                                "enabled": "true",
                                "port": 8843,
                                "nodePort": 8843,
                                "targetPort": 8843,
                                "protocol": "HTTPS",
                            },
                            "speedtest": {
                                "enabled": "true",
                                "port": 6789,
                                "nodePort": 6789,
                                "targetPort": 6789,
                                "protocol": "TCP",
                            },
                            #
                            "stun": {
                                "enabled": "true",
                                "port": 3478,
                                "nodePort": 3478,
                                "targetPort": 3478,
                                "protocol": "UDP",
                            },
                            "syslog": {
                                "enabled": "true",
                                "port": 5514,
                                "nodePort": 5514,
                                "targetPort": 5514,
                                "protocol": "UDP",
                            },
                            "discovery": {
                                "enabled": "true",
                                "port": 10001,
                                "nodePort": 10001,
                                "targetPort": 10001,
                                "protocol": "UDP",
                            },
                            "discoverable": {
                                "enabled": "true",
                                "port": 1900,
                                "nodePort": 1900,
                                "targetPort": 1900,
                                "protocol": "UDP",
                            },
                        },
                    },
                },
                "ingress": {
                    "main": {
                        "enabled": "true",
                        "annotations": {
                            "kubernetes.io/ingress.class": "nginx",
                            "cert-manager.io/issuer": "selfsigned-issuer",
                            "nginx.ingress.kubernetes.io/force-ssl-redirect": "true",
                            "nginx.ingress.kubernetes.io/backend-protocol": "HTTPS",
                        },
                        "tls": [
                            {
                                "secretName": "unifi-tls-secret",  # pragma: allowlist secret
                                "hosts": [
                                    f"unifi.{hostname}",
                                    f"unifi.{node_ip}.nip.io",
                                ],
                            },
                        ],
                        "hosts": [
                            {
                                "host": f"unifi.{hostname}",
                                "paths": [
                                    {
                                        "path": "/",
                                        "service": {"name": "unifi", "port": 8443},
                                    }
                                ],
                            },
                            {
                                "host": f"unifi.{node_ip}.nip.io",
                                "paths": [
                                    {
                                        "path": "/",
                                        "service": {"name": "unifi", "port": 8443},
                                    }
                                ],
                            },
                        ],
                    },
                },
            },
        ),
        opts=ResourceOptions(
            provider=kube_provider,
            depends_on=depends_on + [pv, pvc, certificate],
        ),
    )

    return unifi_chart
