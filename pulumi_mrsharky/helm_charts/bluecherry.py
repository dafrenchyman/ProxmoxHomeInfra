from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts

from pulumi_mrsharky.common.kube_helpers import KubeHelpers


def bluecherry(
    config_folder_root: str,
    recordings_folder: str,
    hostname: str,
    timezone: str,
    mysql_root_password: str,
    bluecherry_password: str,
    uid=1000,
    gid=1000,
):
    mysql_pv, mysql_pvc, _ = KubeHelpers.create_pvc(
        name="bluecherry-mysql",
        path=f"{config_folder_root}/bluecherry-mysql",
        size="2Gi",
        access_mode="ReadWriteOnce",
        storage_class_name="microk8s-hostpath",
    )

    _, _, bluecherry_map = KubeHelpers.create_pvc(
        name="bluecherry",
        mount_path="/var/lib/bluecherry/recordings",
        path=recordings_folder,
        size="100Gi",
        storage_class_name="microk8s-hostpath",
    )

    Chart(
        "bluecherry-mysql",
        config=ChartOpts(
            chart="mysql",
            version="9.1.6",
            fetch_opts=FetchOpts(
                repo="https://charts.bitnami.com/bitnami",
            ),
            values={
                "image": {
                    "pullPolicy": "Always",
                },
                "architecture": "standalone",
                "auth": {
                    "rootPassword": mysql_root_password,
                    # "database": mariadb_database,
                    # "username": mariadb_username,
                    # "password": mariadb_password,
                },
                "primary": {
                    "extraFlags": "--max_heap_table_size=167772160",
                    "podSecurityContext": {
                        "fsGroup": int(gid),
                    },
                    "startupProbe": {"initialDelaySeconds": 90},
                    "containerSecurityContext": {
                        "runAsUser": int(uid),
                    },
                    "persistence": {
                        "existingClaim": mysql_pvc.metadata.apply(lambda v: v["name"]),
                    },
                },
                "secondary": {
                    "replicaCount": 0,
                },
                "metrics": {
                    "enabled": True,
                },
            },
        ),
    )

    Chart(
        "bluecherry",
        config=ChartOpts(
            chart="bluecherry",
            version="0.1.0",
            fetch_opts=FetchOpts(
                repo="https://charts.mrsharky.com/",
            ),
            values={
                "bluecherry": {
                    "timezone": timezone,
                    "uid": f"{uid}",
                    "gid": f"{gid}",
                },
                "persistence": {
                    "recordings": bluecherry_map,
                },
                "mysql": {
                    "useExisting": "true",
                    "host": "bluecherry-mysql",
                    "db": "bluecherry",
                    "admin": {
                        "user": "root",
                        "password": mysql_root_password,
                    },
                    "user": {"user": "bluecherry", "password": bluecherry_password},
                },
                "ingress": {
                    "main": {
                        "enabled": "true",
                        "annotations": {
                            "nginx.ingress.kubernetes.io/backend-protocol": "HTTPS",
                        },
                        "hosts": [
                            {
                                "host": f"bluecherry.{hostname}",
                                "paths": [
                                    {
                                        "path": "/",
                                        "service": {
                                            "name": "bluecherry",
                                            "port": 7001,
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
