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

if [[ "${SELECTED}" == "all" ]]; then
  echo '["development","staging","production"]'
else
  echo "[\"${SELECTED}\"]"
fi
