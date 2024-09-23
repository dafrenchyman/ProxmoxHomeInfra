import pulumi_kubernetes
from pulumi import ResourceOptions
from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts

from pulumi_mrsharky.common.kube_helpers import KubeHelpers


def Wikijs(
    config_folder_root: str,
    data_folder_root: str,
    hostname: str,
    timezone: str,
    depends_on,
    kube_provider: pulumi_kubernetes.Provider,
    node_ip: str,
    uid=1000,
    gid=100,
):
    _, _, config_map = KubeHelpers.create_pvc(
        name="wiki-config",
        path=f"{config_folder_root}/wiki",
        size="1Gi",
        access_mode="ReadWriteMany",
        mount_path="/config",
    )

    _, _, data_map = KubeHelpers.create_pvc(
        name="wiki-data",
        path=f"{data_folder_root}/wiki",
        size="1Gi",
        access_mode="ReadWriteMany",
        mount_path="/data",
    )

    Chart(
        "wikijs",
        config=ChartOpts(
            chart="wikijs",
            version="6.4.2",
            fetch_opts=FetchOpts(
                repo="https://k8s-at-home.com/charts/",
            ),
            values={
                "image": {
                    "repository": "linuxserver/wikijs",
                    "tag": "version-2.5.219",
                    "pullPolicy": "IfNotPresent",
                },
                "env": {
                    "TZ": timezone,
                    "PUID": uid,
                    "PGID": gid,
                    "DB_FILEPATH": "/data/db.sqlite",
                },
                "persistence": {
                    "config": config_map,
                    "data": data_map,
                },
                "ingress": {
                    "main": {
                        "enabled": "true",
                        "primary": "true",
                        "annotations": {
                            "kubernetes.io/ingress.class": "nginx",
                        },
                        "hosts": [
                            {
                                "host": f"wiki.{hostname}",
                                "paths": [
                                    {
                                        "path": "/",
                                        "service": {"name": "wikijs", "port": 3000},
                                    }
                                ],
                            },
                            {
                                "host": f"wiki.{node_ip}.nip.io",
                                "paths": [
                                    {
                                        "path": "/",
                                        "service": {"name": "wikijs", "port": 3000},
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
            depends_on=depends_on,
        ),
    )
    return
