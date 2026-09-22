#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# VALIDATE DESTROY CONFIRMATION
#
# Requires the typed confirmation to exactly match the selected environment
# name, or "DESTROY-ALL-ENVIRONMENTS" when "all" was selected. See
# terraform-destroy.yml's header (SAFEGUARDS #1) for why a typed
# confirmation is required in addition to the dropdown selection — a
# dropdown alone can be mis-clicked; typing the exact name forces a
# deliberate, specific act.
#
# Usage:
#   validate-destroy-confirmation.sh <selected-environment> <typed-confirmation>
# ==============================================================================

if [[ $# -ne 2 ]]; then
  echo "ERROR: Usage: ${0} <selected-environment> <typed-confirmation>" >&2
  exit 1
fi

SELECTED="$1"
CONFIRM="$2"

if [[ "${SELECTED}" == "all" ]]; then
  EXPECTED="DESTROY-ALL-ENVIRONMENTS"
else
  EXPECTED="${SELECTED}"
fi

if [[ "${CONFIRM}" != "${EXPECTED}" ]]; then
  echo "ERROR: Confirmation text did not match." >&2
  echo "       Selected environment:  ${SELECTED}" >&2
  echo "       Expected confirmation: ${EXPECTED}" >&2
  echo "       Received confirmation: ${CONFIRM}" >&2
  exit 1
fi

echo "Confirmation accepted for: ${SELECTED}"
