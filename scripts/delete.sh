#!/usr/bin/env bash
#
# Delete stacks (reverse of deploy order).
#
# Usage:
#   scripts/delete.sh [stack-name]
#
#   [stack-name]  Optional. Delete a single stack (e.g. "vpc").
#
# Prompts for confirmation before deleting.

set -euo pipefail

ONLY_STACK="${1:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT_DIR}/config/config.yaml"

# Resolve a Python 3 interpreter (name varies: python3 / python / py).
PY="$(command -v python3 || command -v python || command -v py || true)"
if [[ -z "$PY" ]]; then
  echo "Python 3 is required but was not found (tried python3, python, py)." >&2
  exit 1
fi

# config/config.yaml is the single source of truth (shared with deploy.sh).
cfg() { "$PY" "${ROOT_DIR}/scripts/config.py" "$1" < "$CONFIG"; }
REGION="${AWS_REGION:-$(cfg region)}"
STACK_PREFIX="$(cfg prefix)"

if [[ -z "$REGION" || -z "$STACK_PREFIX" ]]; then
  echo "config.yaml must define 'region' and 'stackPrefix'." >&2
  exit 1
fi

# Stack names in deploy order, then reversed for deletion (dependents first).
mapfile -t FORWARD < <(cfg stacks | cut -d'|' -f1)
STACKS=()
for ((i=${#FORWARD[@]} - 1; i >= 0; i--)); do
  STACKS+=("${FORWARD[i]}")
done

# Empty a versioned bucket (objects, all versions, and delete markers) so the
# owning stack can be deleted. CloudFormation refuses to delete a non-empty
# bucket, and "aws s3 rm --recursive" alone leaves old versions behind.
empty_bucket() {
  local bucket="$1"
  [[ -z "$bucket" || "$bucket" == "None" ]] && return 0
  echo ">> Emptying bucket ${bucket} (including versions)"
  while :; do
    local batch count
    batch=$(aws s3api list-object-versions --region "$REGION" --bucket "$bucket" \
      --max-items 200 --output json 2>/dev/null \
      | "$PY" -c '
import json, sys
raw = sys.stdin.read().strip()
data = (json.loads(raw) if raw else {}) or {}
items = (data.get("Versions") or []) + (data.get("DeleteMarkers") or [])
objs = [{"Key": i["Key"], "VersionId": i["VersionId"]} for i in items]
print(json.dumps({"Objects": objs, "Quiet": True}))
')
    count=$(printf '%s' "$batch" | "$PY" -c 'import json,sys; print(len(json.load(sys.stdin)["Objects"]))')
    [[ "$count" -eq 0 ]] && break
    aws s3api delete-objects --region "$REGION" --bucket "$bucket" --delete "$batch" >/dev/null
    echo "   removed ${count} object version(s)"
  done
}

read -r -p "Delete stacks in ${REGION}? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

for name in "${STACKS[@]}"; do
  if [[ -n "$ONLY_STACK" && "$ONLY_STACK" != "$name" ]]; then
    continue
  fi
  stack_name="${STACK_PREFIX}-${name}"

  # CloudFormation can't delete a non-empty bucket. Empty any bucket the stack
  # exposes via an output key ending in "BucketName" (transfer, logs, ...)
  # before deleting the stack.
  buckets=$(aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack_name" \
    --query "Stacks[0].Outputs[?ends_with(OutputKey, 'BucketName')].OutputValue" \
    --output text 2>/dev/null || true)
  for bucket in $buckets; do
    empty_bucket "$bucket"
  done

  echo ">> Deleting ${stack_name}"
  aws cloudformation delete-stack --region "$REGION" --stack-name "$stack_name"
  aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$stack_name"
done

echo ">> Done."
