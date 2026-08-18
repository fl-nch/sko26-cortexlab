#!/usr/bin/env bash
#
# Download the Cortex Helm installer from the transfer bucket onto the Linux VM,
# ready to deploy with helm.
#
# RUN THIS FROM THE LINUX VM. Lab workflow:
#   1. In the Cortex console, generate the Kubernetes / Helm installer.
#   2. Upload it to the transfer bucket's "cortex/" folder from your
#      workstation:  aws s3 cp <installer> s3://<transfer-bucket>/cortex/
#   3. Run this script on the VM, then deploy with helm from ${DEST}.
#
# The transfer bucket name is read from /opt/cortexlab/transfer-bucket (written
# at first boot); override with TRANSFER_BUCKET. Region comes from AWS_REGION,
# else config/config.yaml.
#
# Usage:
#   scripts/fetch-cortex.sh          # sync s3://<bucket>/cortex/ -> ${DEST}
#
# Env overrides: TRANSFER_BUCKET, AWS_REGION, DEST (default /opt/cortexlab/cortex)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT_DIR}/config/config.yaml"
DEST="${DEST:-/opt/cortexlab/cortex}"

# Region: env, else config/config.yaml.
REGION="${AWS_REGION:-}"
if [[ -z "$REGION" ]]; then
  PY="$(command -v python3 || command -v python || command -v py || true)"
  if [[ -n "$PY" && -f "$CONFIG" ]]; then
    REGION="$("$PY" "${ROOT_DIR}/scripts/config.py" region < "$CONFIG" 2>/dev/null || true)"
  fi
fi
if [[ -z "$REGION" ]]; then
  echo "Could not resolve region. Set AWS_REGION." >&2
  exit 1
fi

# Transfer bucket: env, else the file written at first boot.
BUCKET="${TRANSFER_BUCKET:-}"
if [[ -z "$BUCKET" && -f /opt/cortexlab/transfer-bucket ]]; then
  BUCKET="$(tr -d '[:space:]' < /opt/cortexlab/transfer-bucket)"
fi
if [[ -z "$BUCKET" ]]; then
  echo "Could not resolve the transfer bucket. Set TRANSFER_BUCKET, or ensure" >&2
  echo "/opt/cortexlab/transfer-bucket exists (written at first boot)." >&2
  exit 1
fi

mkdir -p "$DEST"
echo ">> Downloading s3://${BUCKET}/cortex/ -> ${DEST}"
aws s3 sync --region "$REGION" "s3://${BUCKET}/cortex/" "$DEST"

echo ">> Done. Files ready in ${DEST}:"
find "$DEST" -type f | sed 's/^/   /'
