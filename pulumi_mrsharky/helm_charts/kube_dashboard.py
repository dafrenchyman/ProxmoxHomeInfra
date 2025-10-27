from pulumi_kubernetes.helm.v3 import Chart, ChartOpts, FetchOpts


def kube_dashboard(hostname: str):
    Chart(
        "kubernetes-dashboard",
        config=ChartOpts(
            chart="kubernetes-dashboard",
            version="5.2.0",
            fetch_opts=FetchOpts(
                repo="https://kubernetes.github.io/dashboard/",
            ),
            values={
                "containerSecurityContext": {
                    # "allowPrivilegeEscalation": "true",
                    # "readOnlyRootFilesystem": "true",
                    # "runAsUser": "1000",
                    # "runAsGroup": "1000"
                },
                "ingress": {
                    "enabled": "true",
                    "annotations": {
                        "nginx.ingress.kubernetes.io/backend-protocol": "HTTPS",
                    },
                    "hosts": [f"kube-dash.{hostname}"],
                },
            },
        ),
    )
    return
