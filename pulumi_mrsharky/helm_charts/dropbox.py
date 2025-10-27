from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts

from pulumi_mrsharky.common.kube_helpers import KubeHelpers


def dropbox(config_folder_root: str, timezone: str, uid=1000, gid=1000):
    _, _, config_map = KubeHelpers.create_pvc(
        name="dropbox-config",
        path=f"{config_folder_root}/dropbox",
        size="3Gi",
        access_mode="ReadWriteMany",
        mount_path="/opt/dropbox/.dropbox",
    )

    _, _, data_map = KubeHelpers.create_pvc(
        name="dropbox-data",
        path="/mnt/Bank/SnapArrays/NonSnap/8TB_01/dropbox/data",
        size="10Gi",
        access_mode="ReadWriteMany",
        mount_path="/opt/dropbox/Dropbox",
    )

    Chart(
        "dropbox",
        config=ChartOpts(
            chart="dropbox",
            version="0.1.0",
            fetch_opts=FetchOpts(
                repo="https://charts.mrsharky.com/",
            ),
            values={
                "env": {
                    "TZ": timezone,
                    "DROPBOX_UID": uid,
                    "DROPBOX_GID": gid,
                    "SKIP_SET_PERMISSIONS": "true",
                },
                "persistence": {
                    "config": config_map,
                    "data": data_map,
                },
            },
        ),
    )
    return
