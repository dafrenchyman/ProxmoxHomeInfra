from pulumi_kubernetes.core.v1 import Secret
from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts
from pulumi_kubernetes.networking.v1 import (
    HTTPIngressPathArgs,
    HTTPIngressRuleValueArgs,
    Ingress,
    IngressBackendArgs,
    IngressRuleArgs,
    IngressServiceBackendArgs,
    IngressSpecArgs,
    ServiceBackendPortArgs,
)


def pihole(
    hostname: str,
    timezone: str,
    admin_password: str,
    uid=1000,
    gid=1000,
):
    Secret(
        "pihole-secret",
        metadata={
            "name": "pihole-secret",
        },
        type="kubernetes.io/basic-auth",
        string_data={
            "password": admin_password,
        },
    )

    pihole_chart = Chart(
        "pihole",
        config=ChartOpts(
            chart="pihole",
            version="2.5.8",
            fetch_opts=FetchOpts(
                repo="https://mojo2600.github.io/pihole-kubernetes/",
            ),
            values={
                "admin": {
                    # -- Specify an existing secret to use as admin password
                    "existingSecret": "pihole-secret",  # pragma: allowlist secret
                    # -- Specify the key inside the secret to use
                    "passwordKey": "password",  # pragma: allowlist secret
                },
                "extraEnvVars": {
                    "CUSTOM_CACHE_SIZE": 100_000,
                    "PIHOLE_UID": uid,
                    "PIHOLE_GID": gid,
                    "TZ": timezone,
                    "WEB_UID": uid,
                    "WEB_GID": gid,
                },
                "serviceDhcp": {
                    "enabled": False,
                },
                "serviceDns": {
                    "type": "LoadBalancer",
                    "mixedService": False,
                    # "loadBalancerIP": "192.168.10.201"
                },
                "serviceWeb": {
                    "http": {
                        "port": 80,
                    },
                    "type": "ClusterIP",
                },
                "blacklist": [
                    "(\.|^)youtube\.com$",  # noqa W605
                    "(\.|^)facebook\.com$",  # noqa W605
                ],  # noqa W605
                # "hostNetwork": True,
            },
        ),
    )

    Ingress(
        "pihole-ingress",
        metadata={
            "name": "pihole-ingress",
            "annotations": {},
        },
        spec=IngressSpecArgs(
            rules=[
                IngressRuleArgs(
                    host=f"pihole.{hostname}",
                    http=HTTPIngressRuleValueArgs(
                        paths=[
                            HTTPIngressPathArgs(
                                path="/",
                                path_type="Prefix",
                                backend=IngressBackendArgs(
                                    service=IngressServiceBackendArgs(
                                        name=pihole_chart.get_resource(
                                            "v1/Service", "pihole-web"
                                        ).metadata["name"],
                                        port=ServiceBackendPortArgs(number=80),
                                    ),
                                ),
                            ),
                        ]
                    ),
                ),
            ],
        ),
    )
    return
