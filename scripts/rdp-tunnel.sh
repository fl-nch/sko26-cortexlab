#!/usr/bin/env bash
#
# Open an RDP tunnel to the Windows VM over SSM port forwarding.
#
# The Windows VM has no inbound rules (SSM only). This starts an
# AWS-StartPortForwardingSession that maps a local port to the instance's RDP
# port (3389), so you can point any RDP client at localhost:<local-port>.
#
# RUN THIS LOCALLY (from your workstation), not on the VMs. Requires the aws CLI
# v2 and the AWS Session Manager plugin:
#   https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
#
# On Windows, prefer Git Bash: the tunnel binds on the Windows side, so your RDP
# client (mstsc.exe) reaches localhost:<local-port> directly. WSL also works but
# adds a networking hop:
#   - The Linux aws CLI + session-manager-plugin (and python3 + pyyaml, or an
#     explicit INSTANCE_ID) must be installed INSIDE the distro, not on Windows.
#   - WSL 1 shares localhost with Windows, so mstsc connects with no extra setup.
#   - WSL 2 relies on localhost-forwarding, which can be flaky. If mstsc can't
#     connect, enable mirrored networking: add "networkingMode=mirrored" under
#     [wsl2] in %UserProfile%\.wslconfig, then run "wsl --shutdown".
#
# First time only, set an Administrator password from a PowerShell SSM session:
#   aws ssm start-session --target <instance-id>
#   net user Administrator <NewPassw0rd!>
#
# Usage:
#   scripts/rdp-tunnel.sh [local-port]     # default local port 13389
#
# Env overrides: AWS_REGION, INSTANCE_ID, WIN_STACK. Setting INSTANCE_ID skips
# the config.yaml / CloudFormation lookup entirely.

set -euo pipefail

LOCAL_PORT="${1:-13389}"
REMOTE_PORT=3389

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT_DIR}/config/config.yaml"

# Resolve region + stack prefix. Explicit env wins; otherwise derive from
# config/config.yaml (region, and the win-vm stack name "<stackPrefix>-win-vm").
REGION="${AWS_REGION:-}"
INSTANCE_ID="${INSTANCE_ID:-}"
STACK_PREFIX=""
if [[ -z "$REGION" || -z "$INSTANCE_ID" ]]; then
  PY="$(command -v python3 || command -v python || command -v py || true)"
  if [[ -n "$PY" && -f "$CONFIG" ]]; then
    cfg() { "$PY" "${ROOT_DIR}/scripts/config.py" "$1" < "$CONFIG"; }
    REGION="${REGION:-$(cfg region)}"
    STACK_PREFIX="$(cfg prefix)"
  fi
fi

if [[ -z "$REGION" ]]; then
  echo "Could not resolve region. Set AWS_REGION, or run where config/config.yaml is readable." >&2
  exit 1
fi

# Resolve the Windows VM instance id from its stack output unless given.
WIN_STACK="${WIN_STACK:-${STACK_PREFIX}-win-vm}"
if [[ -z "$INSTANCE_ID" ]]; then
  if [[ -z "$STACK_PREFIX" ]]; then
    echo "Set INSTANCE_ID, or make config/config.yaml readable so the stack can be found." >&2
    exit 1
  fi
  INSTANCE_ID=$(aws cloudformation describe-stacks --region "$REGION" \
    --stack-name "$WIN_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" \
    --output text 2>/dev/null || true)
fi

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
  echo "Could not find the Windows VM instance id (stack '${WIN_STACK}')." >&2
  echo "Deploy it first (scripts/deploy-part1.sh), or pass INSTANCE_ID explicitly." >&2
  exit 1
fi

echo ">> Windows VM: ${INSTANCE_ID}   Region: ${REGION}"
echo ">> Forwarding localhost:${LOCAL_PORT} -> ${INSTANCE_ID}:${REMOTE_PORT} (RDP)"
echo ">> Leave this running; connect an RDP client to localhost:${LOCAL_PORT}. Ctrl-C to stop."

aws ssm start-session \
  --region "$REGION" \
  --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "portNumber=${REMOTE_PORT},localPortNumber=${LOCAL_PORT}"
