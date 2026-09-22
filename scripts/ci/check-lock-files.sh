#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# EVERY ROOT CONFIGURATION HAS A COMMITTED, COMPLETE PROVIDER LOCK FILE
#
# The lock file pins the exact provider builds and their checksums, so every
# plan and apply -- on a laptop or in CI -- installs the same providers. It only
# works if it is committed, and it is easy to forget: `terraform init` writes it
# locally and nothing complains that it is untracked.
#
# For each directory given, this fails unless:
#   - .terraform.lock.hcl is tracked by git, and
#   - it lists every provider the directory's own required_providers declares.
#
# Providers that only child modules declare are checked by Terraform itself: the
# workflows run `terraform init -lockfile=readonly`, which refuses a lock file
# that does not cover the whole configuration.
#
# Usage: check-lock-files.sh <root-dir>...
# ==============================================================================

[[ $# -gt 0 ]] || { echo "Usage: check-lock-files.sh <root-dir>..." >&2; exit 1; }

LOCK_COMMAND='terraform providers lock -platform=windows_amd64 -platform=linux_amd64 -platform=darwin_amd64 -platform=darwin_arm64'
FAILED=0

for DIR in "$@"; do
  DIR="${DIR%/}"
  LOCK="${DIR}/.terraform.lock.hcl"

  if [[ ! -f "${LOCK}" ]]; then
    echo "::error file=${DIR}::${LOCK} does not exist. Run 'terraform -chdir=${DIR} init' and then '${LOCK_COMMAND}' in that folder, and commit it."
    FAILED=1
    continue
  fi

  if ! git ls-files --error-unmatch "${LOCK}" >/dev/null 2>&1; then
    echo "::error file=${LOCK}::${LOCK} exists but is not committed. git add it."
    FAILED=1
    continue
  fi

  # Providers this root declares itself, as <namespace>/<type>.
  DECLARED="$(cat "${DIR}"/*.tf 2>/dev/null \
    | grep -oE 'source[[:space:]]*=[[:space:]]*"[a-z0-9-]+/[a-z0-9-]+"' \
    | sed -E 's/.*"([^"]+)"/\1/' | sort -u || true)"

  MISSING=()
  for PROVIDER in ${DECLARED}; do
    grep -q "provider \"registry.terraform.io/${PROVIDER}\"" "${LOCK}" || MISSING+=("${PROVIDER}")
  done

  if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "::error file=${LOCK}::${LOCK} does not lock ${MISSING[*]}. Run 'terraform -chdir=${DIR} init -upgrade', then '${LOCK_COMMAND}' there, and commit it."
    FAILED=1
    continue
  fi

  echo "ok   ${LOCK}"
done

exit "${FAILED}"
