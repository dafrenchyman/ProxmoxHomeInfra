from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts

from pulumi_mrsharky.common.kube_helpers import KubeHelpers


def mariadb(
    config_folder_root,
    # hostname: str,
    uid=1000,
    gid=1000,
):
    mariadb_root_password = "root"  # pragma: allowlist secret
    mariadb_database = "extra"
    mariadb_username = "user"
    mariadb_password = "123"  # pragma: allowlist secret

    mariadb_pv, mariadb_pvc, _ = KubeHelpers.create_pvc(
        name="mariadb",
        path=f"{config_folder_root}/mariadb",
        size="100Gi",
        access_mode="ReadWriteOnce",
        storage_class_name="microk8s-hostpath",
    )

    Chart(
        "mariadb",
        config=ChartOpts(
            chart="mariadb",
            version="11.0.12",
            fetch_opts=FetchOpts(
                repo="https://charts.bitnami.com/bitnami",
            ),
            values={
                "image": {
                    "pullPolicy": "Always",
                },
                "architecture": "standalone",
                "auth": {
                    "rootPassword": mariadb_root_password,
                    "database": mariadb_database,
                    "username": mariadb_username,
                    "password": mariadb_password,
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
                        "existingClaim": mariadb_pvc.metadata.apply(
                            lambda v: v["name"]
                        ),
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

    # Trying to figure out a good way to give the DB a resolvable name (this doesn't work)
    # if False:
    #     Ingress(
    #         "mariadb-ingress",
    #         metadata={
    #             "name": "mariadb-ingress",
    #             "annotations": {},
    #         },
    #         spec=IngressSpecArgs(
    #             rules=[
    #                 IngressRuleArgs(
    #                     host=f"mariadb.{hostname}",
    #                     http=HTTPIngressRuleValueArgs(
    #                         paths=[
    #                             HTTPIngressPathArgs(
    #                                 path_type="Prefix",
    #                                 path="/",
    #                                 backend=IngressBackendArgs(
    #                                     service=IngressServiceBackendArgs(
    #                                         name="mariadb",
    #                                         port=ServiceBackendPortArgs(
    #                                             number=3306,
    #                                         ),
    #                                     ),
    #                                 ),
    #                             ),
    #                         ],
    #                     ),
    #                 ),
    #             ],
    #         ),
    #     )

    return
