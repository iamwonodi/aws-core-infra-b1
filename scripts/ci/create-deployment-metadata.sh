#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# RECORD WHAT PRODUCED A PLAN
#
# terraform-apply.yml reads this back to check out the exact commit and assets
# the plan was generated from. jq builds the JSON, so no value -- however odd --
# can break out of a string, which a shell heredoc would allow.
#
# assets_repository and assets_ref are empty when the assets came from this
# repository's own assets/ folder (the default) instead of an external
# repository.
#
# Usage: create-deployment-metadata.sh <environment-dir> <environment> <infrastructure-sha> <assets-path> [assets-repository] [assets-ref]
# ==============================================================================

if [[ $# -lt 4 || $# -gt 6 ]]; then
  echo "ERROR: Usage: ${0} <environment-dir> <environment> <infrastructure-sha> <assets-path> [assets-repository] [assets-ref]" >&2
  exit 1
fi

ENV_DIR="$1"
ENVIRONMENT="$2"
INFRASTRUCTURE_SHA="$3"
ASSETS_PATH="$4"
ASSETS_REPOSITORY="${5:-}"
ASSETS_REF="${6:-}"

case "${ENVIRONMENT}" in
  development|staging|production) ;;
  *)
    echo "ERROR: unknown environment '${ENVIRONMENT}'." >&2
    exit 1
    ;;
esac

if ! [[ "${INFRASTRUCTURE_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: '${INFRASTRUCTURE_SHA}' is not a full 40-character commit SHA." >&2
  exit 1
fi

if [[ -n "${ASSETS_REPOSITORY}" && -z "${ASSETS_REF}" ]]; then
  echo "ERROR: an assets repository was given without an assets ref." >&2
  exit 1
fi

jq -n \
  --arg sha "${INFRASTRUCTURE_SHA}" \
  --arg env "${ENVIRONMENT}" \
  --arg path "${ASSETS_PATH}" \
  --arg repo "${ASSETS_REPOSITORY}" \
  --arg ref "${ASSETS_REF}" \
  '{infrastructure_sha: $sha, environment: $env, assets_path: $path, assets_repository: $repo, assets_ref: $ref}' \
  > "${ENV_DIR}/deployment-metadata.json"

cat "${ENV_DIR}/deployment-metadata.json"
