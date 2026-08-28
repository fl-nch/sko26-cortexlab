#!/usr/bin/env bash
#
# Deploy (or remove) the GoCortex Broken Bank workload on the EKS cluster.
#
# RUN THIS FROM THE LINUX VM (or any host inside the VPC). The EKS API endpoint
# is private-only, so kubectl only resolves from inside the VPC.
#
# deploy-part1.sh stages this script and the k8s manifest to the transfer bucket,
# and the Linux VM pulls them to /opt/cortexlab on first boot. So in class you
# just connect via SSM and run:
#
#   /opt/cortexlab/scripts/deploy-app.sh
#
# (If the assets weren't staged, copy k8s/ + config/ + scripts/ onto the VM via
# the transfer bucket, or re-run deploy-part1.sh, then run this from there.)
#
# Requires on the VM: aws CLI v2 and kubectl (both preinstalled by the VM's
# first-boot bootstrap). python3 reads config/config.yaml when present;
# otherwise set CLUSTER_NAME / AWS_REGION explicitly.
#
# Usage:
#   scripts/deploy-app.sh            # apply the manifest
#   scripts/deploy-app.sh delete     # remove it

set -euo pipefail

ACTION="${1:-apply}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT_DIR}/config/config.yaml"
MANIFEST="${ROOT_DIR}/k8s/gocortexbrokenbank.yaml"

# Resolve region + cluster name. Explicit env wins; otherwise derive from
# config/config.yaml (region, and cluster name "<stackPrefix>-eks").
REGION="${AWS_REGION:-}"
CLUSTER_NAME="${CLUSTER_NAME:-}"
if [[ -z "$REGION" || -z "$CLUSTER_NAME" ]]; then
  PY="$(command -v python3 || command -v python || command -v py || true)"
  if [[ -n "$PY" && -f "$CONFIG" ]]; then
    cfg() { "$PY" "${ROOT_DIR}/scripts/config.py" "$1" < "$CONFIG"; }
    REGION="${REGION:-$(cfg region)}"
    CLUSTER_NAME="${CLUSTER_NAME:-$(cfg prefix)-eks}"
  fi
fi

if [[ -z "$REGION" || -z "$CLUSTER_NAME" ]]; then
  echo "Could not resolve cluster/region. Set CLUSTER_NAME and AWS_REGION, or" >&2
  echo "run where config/config.yaml is readable." >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "Manifest not found: $MANIFEST" >&2
  exit 1
fi

echo ">> Cluster: ${CLUSTER_NAME}   Region: ${REGION}"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

case "$ACTION" in
  apply)
    kubectl apply -f "$MANIFEST"
    kubectl -n gocortexbrokenbank rollout status deploy/gocortexbrokenbank --timeout=180s
    echo
    echo ">> Node private IPs (target any one of these from the VMs):"
    kubectl get nodes -o jsonpath='{range .items[*]}{"   "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
    echo ">> Service NodePort mapping (native port -> nodePort):"
    kubectl -n gocortexbrokenbank get svc gocortexbrokenbank \
      -o jsonpath='{range .spec.ports[*]}{"   "}{.name}{"\t"}{.port}{" -> "}{.nodePort}{"\n"}{end}'
    echo
    echo ">> Example: curl \"http://<node-ip>:30888/search?q=' OR '1'='1\""
    ;;
  delete)
    kubectl delete -f "$MANIFEST"
    ;;
  *)
    echo "Usage: $0 [apply|delete]" >&2
    exit 1
    ;;
esac

echo ">> Done."
