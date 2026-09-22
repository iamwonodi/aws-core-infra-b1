#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# READ DEPLOYMENT METADATA
#
# Reads a deployment-metadata.json file (written by terraform-plan.yml
# alongside its saved plan) and prints its fields as KEY=value lines, one
# per line, suitable for the caller to redirect into $GITHUB_ENV.
#
# This is what lets terraform-apply.yml check out the EXACT infrastructure
# commit and assets release that produced a given plan, rather than
# whatever happens to be current at apply time.
#
# Usage:
#   read-deployment-metadata.sh <metadata-json-file>
# ==============================================================================

if [[ $# -ne 1 ]]; then
  echo "ERROR: Usage: ${0} <metadata-json-file>" >&2
  exit 1
fi

METADATA_FILE="$1"

if [[ ! -s "${METADATA_FILE}" ]]; then
  echo "ERROR: Metadata file not found or empty: ${METADATA_FILE}" >&2
  exit 1
fi

# assets_repository and assets_ref are legitimately empty when the assets came
# from this repository's own assets/ folder, so only the rest are required.
for FIELD in infrastructure_sha assets_path environment; do
  if ! jq -e --arg f "${FIELD}" 'has($f) and (.[$f] | length > 0)' "${METADATA_FILE}" >/dev/null; then
    echo "ERROR: Metadata file is missing required field '${FIELD}': ${METADATA_FILE}" >&2
    exit 1
  fi
done

jq -r '
  "INFRASTRUCTURE_SHA=" + .infrastructure_sha,
  "ASSETS_REPOSITORY=" + (.assets_repository // ""),
  "ASSETS_REF=" + (.assets_ref // ""),
  "ASSETS_PATH=" + .assets_path,
  "ENVIRONMENT=" + .environment
' "${METADATA_FILE}"
