from pulumi import ResourceOptions
from pulumi_kubernetes.core.v1 import PersistentVolume, PersistentVolumeClaim
from pulumi_kubernetes.core.v1.outputs import PersistentVolumeSpec


class KubeHelpers:
    @staticmethod
    def create_pvc(
        name,
        path,
        access_mode="ReadWriteMany",
        size="1Gi",
        mount_path="",
        storage_class_name="base",
        namespace="default",
        opts: ResourceOptions = None,
    ):
        clean_name = name.lower().replace("_", "-")
        pv = PersistentVolume(
            clean_name,
            metadata={
                "name": f"{clean_name}-pv",
                "labels": {"type": "local"},
                "namespace": namespace,
            },
            spec=PersistentVolumeSpec(
                persistent_volume_reclaim_policy="Retain",
                storage_class_name=storage_class_name,
                capacity={"storage": size},
                access_modes=[
                    access_mode,
                ],
                host_path={"path": f"{path}"},
            ),
            opts=opts,
        )

        pvc = PersistentVolumeClaim(
            clean_name,
            metadata={
                "name": f"{clean_name}-pvc",
                "namespace": namespace,
            },
            spec={
                "storageClassName": storage_class_name,
                "accessModes": [access_mode],
                "resources": {
                    "requests": {
                        "storage": size,
                    }
                },
                "volumeName": f"{clean_name}-pv",
            },
            opts=ResourceOptions(
                parent=pv,
                provider=opts.provider,
            ),
        )

        pre_built_mount = {
            "enabled": "true",
            "type": "pvc",
            "existingClaim": pvc.metadata.apply(lambda v: v["name"]),
            "mountPath": mount_path,
        }
        return pv, pvc, pre_built_mount
