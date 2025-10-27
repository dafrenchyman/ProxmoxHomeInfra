from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts

from pulumi_mrsharky.common.kube_helpers import KubeHelpers


def netbootxyz(
    config_folder_root: str,
    data_folder_root: str,
    hostname: str,
    timezone: str,
    uid=1000,
    gid=1000,
):
    _, _, config_map = KubeHelpers.create_pvc(
        name="netbootxyz-config",
        path=f"{config_folder_root}/netbootxyz",
        size="1Gi",
        access_mode="ReadWriteMany",
        mount_path="/config",
    )

    _, _, data_map = KubeHelpers.create_pvc(
        name="netbootxyz-data",
        path=f"{data_folder_root}/netbootxyz/",
        access_mode="ReadOnlyMany",
        mount_path="/assets",
    )

    # NOTES: Hijacking the "reg" chart and instead loading the "netbootxyz" linuxserver.io container
    Chart(
        "netbootxyz",
        config=ChartOpts(
            chart="reg",  # Not really going to use this container
            version="3.0.1",
            fetch_opts=FetchOpts(
                repo="https://k8s-at-home.com/charts/",
            ),
            values={
                "image": {
                    "repository": "linuxserver/netbootxyz",
                    "tag": "0.6.7",
                    "pullPolicy": "IfNotPresent",
                },
                "env": {
                    "TZ": timezone,
                    "PUID": uid,
                    "PGID": gid,
                },
                "hostNetwork": "true",
                "persistence": {
                    "config": config_map,
                    "data": data_map,
                },
                "service": {
                    "main": {
                        "enabled": "true",
                        "nameOverride": "netbootxyz",
                        "ports": {
                            "http": {"enabled": "true", "port": 3010},
                        },
                    },
                    "boot": {
                        "enabled": "true",
                        "nameOverride": "boot",
                        "ports": {
                            "boot": {"enabled": "true", "port": 69},
                        },
                    },
                    "webui": {
                        "enabled": "true",
                        "nameOverride": "webui",
                        "ports": {
                            "webui": {
                                "enabled": "true",
                                "port": 80,
                                "targetPort": 8090,
                            },
                        },
                    },
                },
                "ingress": {
                    "main": {
                        "enabled": "true",
                        "nameOverride": "netbootxyz",
                        "hosts": [
                            {
                                "host": f"netbootxyz.{hostname}",
                                "paths": [
                                    {
                                        "path": "/",
                                        "service": {
                                            # The "name" is odd because we hijacked the reg helm
                                            "name": "netbootxyz-reg-netbootxyz",
                                            "port": 3010,
                                        },
                                    }
                                ],
                            },
                        ],
                    },
                },
            },
        ),
    )
    return
