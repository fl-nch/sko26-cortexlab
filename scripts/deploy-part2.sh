#!/usr/bin/env bash
#
# Deploy part 2: the EKS stack only.
#
# Usage:
#   scripts/deploy-part2.sh
#
# Run scripts/deploy-part1.sh first. The EKS stack imports the private subnets
# (vpc stack) and the VM security groups and roles (linux-vm / win-vm stacks),
# so those must be in place. Creating the cluster and node group takes ~15
# minutes.
#
# Requires: aws CLI v2. Uses "aws cloudformation deploy" which creates or
# updates the stack as needed and is a no-op when there are no changes.

set -euo pipefail

# The single stack this script deploys.
ONLY_STACK="eks"

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

found=""
for entry in "${STACKS[@]}"; do
  IFS='|' read -r name template params <<< "$entry"
  if [[ "$name" != "$ONLY_STACK" ]]; then
    continue
  fi
  found="yes"
  deploy_stack "$name" "$template" "$params"
done

if [[ -z "$found" ]]; then
  echo "Stack '${ONLY_STACK}' is not defined in config.yaml." >&2
  exit 1
fi

echo ">> Done."
