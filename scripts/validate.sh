#!/usr/bin/env bash
#
# Validate all CloudFormation templates.
#
# Runs cfn-lint if available (recommended), otherwise falls back to
# "aws cloudformation validate-template" for basic syntax checking.
#
# Usage:
#   scripts/validate.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
CFN_CONFIG="${ROOT_DIR}/tests/cfn-lint.yaml"

# Resolve a Python 3 interpreter (name varies: python3 / python / py).
PY="$(command -v python3 || command -v python || command -v py || true)"

# Locate cfn-lint: prefer PATH, else the Scripts/bin dir where pip installed it
# (pip console scripts aren't always on PATH on Windows).
find_cfn_lint() {
  if command -v cfn-lint >/dev/null 2>&1; then
    command -v cfn-lint
    return 0
  fi
  [[ -z "$PY" ]] && return 1
  local dir exe
  for dir in \
    "$("$PY" -c 'import sysconfig; print(sysconfig.get_path("scripts"))' 2>/dev/null)" \
    "$("$PY" -c 'import site, os; print(os.path.join(site.getuserbase(), "Scripts" if os.name=="nt" else "bin"))' 2>/dev/null)"; do
    for exe in "$dir/cfn-lint.exe" "$dir/cfn-lint"; do
      [[ -x "$exe" ]] && { echo "$exe"; return 0; }
    done
  done
  return 1
}

CFN_LINT="$(find_cfn_lint || true)"

if [[ -n "$CFN_LINT" ]]; then
  # tests/cfn-lint.yaml is the single source for the template list, regions,
  # and ignore_checks. Run from the repo root so its relative "templates:"
  # globs resolve.
  echo ">> Linting with ${CFN_LINT} (config: ${CFN_CONFIG})"
  ( cd "$ROOT_DIR" && "$CFN_LINT" --config-file "$CFN_CONFIG" )
else
  echo ">> cfn-lint not found; falling back to aws validate-template"
  mapfile -t TEMPLATES < <(find "${ROOT_DIR}/templates" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \))
  if [[ ${#TEMPLATES[@]} -eq 0 ]]; then
    echo "No templates found under templates/." >&2
    exit 0
  fi
  for t in "${TEMPLATES[@]}"; do
    echo ">> Validating $t"
    aws cloudformation validate-template \
      --region "$REGION" \
      --template-body "file://${t}" >/dev/null
  done
fi

echo ">> All templates valid."
