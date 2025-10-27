#!/usr/bin/env bash

# Name of your Helm chart (or prefix to match)
CHART_NAME="metallb"

# List of Kubernetes resource types to search and delete
RESOURCE_TYPES=(
  ClusterRole
  ClusterRoleBinding
  CustomResourceDefinition
  ConfigMap
  DaemonSet
  Deployment
  EndpointSlice
  HorizontalPodAutoscaler
  Ingress
  IngressClass
  Job
  Lease
  MutatingWebhookConfiguration
  PersistentVolumeClaim
  PersistentVolume
  Pod
  Role
  RoleBinding
  Secret
  Service
  ServiceAccount
  StatefulSet
  ValidatingWebhookConfiguration
)

# Loop through each type and delete resources that match CHART_NAME
for RESOURCE in "${RESOURCE_TYPES[@]}"; do
  echo "Checking for ${RESOURCE} resources matching '${CHART_NAME}'..."

  # Get all resource names of this type that match the CHART_NAME
  MATCHING_NAMES=$(kubectl get "$RESOURCE" --no-headers 2>/dev/null | grep "^$CHART_NAME" | awk '{print $1}')

  if [[ -n "$MATCHING_NAMES" ]]; then
    # kubectl get service | grep cert-manager | awk '{print($1)}' | xargs -n 1 kubectl delete service
    #echo "$MATCHING_NAMES" | xargs -n 1 -I {} kubectl delete "$RESOURCE" {}
    echo "$MATCHING_NAMES" | xargs -n 1 kubectl delete "$RESOURCE"
  else
    echo "No ${RESOURCE} resources found matching '${CHART_NAME}'"
  fi
done