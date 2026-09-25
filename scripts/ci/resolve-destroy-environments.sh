#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# RESOLVE DESTROY ENVIRONMENTS
#
# Expands the workflow's "environment" input ("development", "staging",
# "production", or "all") into the JSON array of environments to destroy.
# "all" is ordered safest-first (development, staging, production) — see
# terraform-destroy.yml's header for why order matters there.
#
# Usage:
#   resolve-destroy-environments.sh <selected-environment>
# ==============================================================================

if [[ $# -ne 1 ]]; then
  echo "ERROR: Usage: ${0} <selected-environment>" >&2
  exit 1
fi

SELECTED="$1"

ENABLED="$(dirname "${BASH_SOURCE[0]}")/enabled-environments.sh"

# "all" is every environment this project runs (environments.json), in the
# platform's order: development, staging, production. One named must be one of
# them.
if [[ "${SELECTED}" == "all" ]]; then
  bash "${ENABLED}"
else
  bash "${ENABLED}" --check "${SELECTED}"
  echo "[\"${SELECTED}\"]"
fi
