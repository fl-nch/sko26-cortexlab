#!/usr/bin/env bash
#
# Deploy part 1: every stack EXCEPT the EKS stack.
#
# Usage:
#   scripts/deploy-part1.sh [stack-name]
#
#   [stack-name]  Optional. Deploy a single (non-EKS) stack (e.g. "vpc").
#                 If omitted, deploys every stack except "eks".
#
# The EKS stack is deployed separately by scripts/deploy-part2.sh: it takes
# ~15 minutes and imports the private subnets (vpc) plus the VM security groups
# and roles (linux-vm / win-vm), so those must exist first.
#
# Requires: aws CLI v2. Uses "aws cloudformation deploy" which creates or
# updates the stack as needed and is a no-op when there are no changes.

set -euo pipefail

ONLY_STACK="${1:-}"

# Stack deployed by deploy-part2.sh instead; skipped here.
SKIP_STACK="eks"

# Repo directories staged to the transfer bucket (under lab-assets/) right after
# the transfer-bucket stack is created, so the Linux VM can pull them on first
# boot - the k8s manifest, deploy-app.sh, config.py and config.yaml. The repo
# stays the single source of truth; the VM just gets a copy.
LAB_ASSET_DIRS=(k8s config scripts)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT_DIR}/config/config.yaml"

# Resolve a Python 3 interpreter (name varies: python3 / python / py).
PY="$(command -v python3 || command -v python || command -v py || true)"
if [[ -z "$PY" ]]; then
  echo "Python 3 is required but was not found (tried python3, python, py)." >&2
  exit 1
fi

# config/config.yaml is the single source of truth for region, prefix, tags,
# and the stack list. AWS_REGION still wins if explicitly set.
cfg() { "$PY" "${ROOT_DIR}/scripts/config.py" "$1" < "$CONFIG"; }
REGION="${AWS_REGION:-$(cfg region)}"
STACK_PREFIX="$(cfg prefix)"
mapfile -t TAGS < <(cfg tags)
mapfile -t STACKS < <(cfg stacks)

if [[ -z "$REGION" || -z "$STACK_PREFIX" ]]; then
  echo "config.yaml must define 'region' and 'stackPrefix'." >&2
  exit 1
fi

deploy_stack() {
  local name="$1"
  local template="$2"
  local params_file="$3"
  local stack_name="${STACK_PREFIX}-${name}"

  echo ">> Deploying ${stack_name} (${template})"

  # Convert the JSON parameter file into "Key=Value" overrides.
  # The file is fed via stdin (bash opens it) so we never pass a filesystem
  # path into Python -- native Windows interpreters can't resolve the
  # Git Bash "/c/..." paths this script produces.
  local overrides
  overrides=$("$PY" -c '
import json, sys
for p in json.load(sys.stdin):
    print(p["ParameterKey"] + "=" + p["ParameterValue"])
' < "${ROOT_DIR}/${params_file}")

  # Drive every resource name from the single stackPrefix in config.yaml.
  # Each template declares a NamePrefix parameter used in its Name tags.
  overrides="${overrides:+$overrides }NamePrefix=${STACK_PREFIX}"

  local deploy_args=(
    --region "$REGION"
    --stack-name "$stack_name"
    --template-file "${ROOT_DIR}/${template}"
    --capabilities CAPABILITY_NAMED_IAM
    --no-fail-on-empty-changeset
  )
  # Tags and parameter overrides are only added when present.
  if [[ ${#TAGS[@]} -gt 0 ]]; then
    deploy_args+=(--tags "${TAGS[@]}")
  fi
  if [[ -n "$overrides" ]]; then
    deploy_args+=(--parameter-overrides $overrides)
  fi

  aws cloudformation deploy "${deploy_args[@]}"
}

# Upload the lab-asset directories to the transfer bucket so the Linux VM pulls
# them on boot. Runs after the transfer-bucket stack (which precedes the VMs),
# so the files are in place before the VM launches. Idempotent: re-running
# refreshes them. Non-fatal if the bucket name can't be resolved.
stage_lab_assets() {
  local bucket
  bucket=$(aws cloudformation describe-stacks --region "$REGION" \
    --stack-name "${STACK_PREFIX}-transfer-bucket" \
    --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
    --output text 2>/dev/null || true)
  if [[ -z "$bucket" || "$bucket" == "None" ]]; then
    echo "!! transfer-bucket name not found; skipping lab-asset staging." >&2
    return 0
  fi
  echo ">> Staging lab assets to s3://${bucket}/lab-assets/"
  local d
  for d in "${LAB_ASSET_DIRS[@]}"; do
    aws s3 sync --region "$REGION" "${ROOT_DIR}/${d}" "s3://${bucket}/lab-assets/${d}"
  done
}

for entry in "${STACKS[@]}"; do
  IFS='|' read -r name template params <<< "$entry"
  if [[ "$name" == "$SKIP_STACK" ]]; then
    continue
  fi
  if [[ -n "$ONLY_STACK" && "$ONLY_STACK" != "$name" ]]; then
    continue
  fi
  deploy_stack "$name" "$template" "$params"
  # Stage the VM's lab assets as soon as the bucket exists, before the VMs boot.
  if [[ "$name" == "transfer-bucket" ]]; then
    stage_lab_assets
  fi
done

echo ">> Done."
