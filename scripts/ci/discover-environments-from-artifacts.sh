#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# DISCOVER ENVIRONMENTS FROM ARTIFACTS
#
# A single terraform-plan.yml run may have planned one environment (a
# workflow_dispatch run) or several (a pull_request that touched more than
# one environment's Terraform files). Rather than requiring the caller to
# already know which, this scans every downloaded plan artifact under the
# given directory for a deployment-metadata.json, reads its "environment"
# field, and returns the JSON array of what it found.
#
# Usage:
#   discover-environments-from-artifacts.sh <download-directory>
#
# Expects <download-directory> to contain one subdirectory per downloaded
# artifact (actions/download-artifact's default layout when multiple
# artifacts match a pattern), each containing a deployment-metadata.json.
# ==============================================================================

if [[ $# -ne 1 ]]; then
  echo "ERROR: Usage: ${0} <download-directory>" >&2
  exit 1
fi

DOWNLOAD_DIR="$1"

if [[ ! -d "${DOWNLOAD_DIR}" ]]; then
  echo "ERROR: Download directory not found: ${DOWNLOAD_DIR}" >&2
  exit 1
fi

mapfile -t METADATA_FILES < <(find "${DOWNLOAD_DIR}" -name "deployment-metadata.json" | sort)

if [[ ${#METADATA_FILES[@]} -eq 0 ]]; then
  echo "ERROR: No deployment-metadata.json files found under ${DOWNLOAD_DIR}." >&2
  echo "       Expected at least one plan artifact to have been downloaded." >&2
  exit 1
fi

ENVIRONMENTS="[]"

for FILE in "${METADATA_FILES[@]}"; do
  ENV_NAME="$(jq -r '.environment' "${FILE}")"

  if [[ -z "${ENV_NAME}" || "${ENV_NAME}" == "null" ]]; then
    echo "ERROR: ${FILE} has no 'environment' field." >&2
    exit 1
  fi

  # The plan workflow plans only environments this project runs; a plan for
  # another would mean environments.json changed in between. Refuse it.
  bash "$(dirname "${BASH_SOURCE[0]}")/enabled-environments.sh" --check "${ENV_NAME}"

  ENVIRONMENTS="$(jq -c --arg env "${ENV_NAME}" '. + [$env]' <<< "${ENVIRONMENTS}")"
done

echo "${ENVIRONMENTS}"
