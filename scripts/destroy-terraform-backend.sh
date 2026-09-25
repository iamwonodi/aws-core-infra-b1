#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# DESTROY TERRAFORM STATE BUCKET
#
# The counterpart to bootstrap-environment.sh: permanently empties and
# deletes an environment's dedicated state bucket. Since that bucket is
# never Terraform-managed (see bootstrap-environment.sh's header for why),
# nothing in terraform-destroy.yml — or anywhere else in this pipeline —
# can remove it. This is the only tool that can.
#
# THIS IS A MANUAL, LOCAL-ONLY UTILITY. It is intentionally NOT part of any
# GitHub Actions workflow, and intentionally has no "-auto-approve"-style
# shortcut.
#
# SAFEGUARDS:
#
#   1. REFUSES TO PROCEED if the bucket's terraform.tfstate still tracks
#      any real resources (a non-empty "resources" array). This is a hard
#      block, not a warning, and there is deliberately no override flag.
#      Destroying the bucket at that point wouldn't just delete a bucket —
#      it would permanently orphan every real AWS resource Terraform was
#      still tracking, with no path back to managing them through this
#      pipeline. If you actually intend to tear down that environment's
#      infrastructure too, do that FIRST via terraform-destroy.yml (its
#      own approvals, its own typed confirmation), THEN come back here
#      once the state is empty.
#
#   2. Typed confirmation required — type the environment name exactly, or
#      "DESTROY-ALL-STATE-BUCKETS" for "all". Matches terraform-destroy.yml's
#      pattern deliberately, so the safety model feels consistent across
#      this repo's destructive tools.
#
#   3. Correctly empties a VERSIONED bucket before deleting it — S3 will
#      not delete a bucket that still contains any object version or
#      delete marker, current or not. Deleting only "current" objects and
#      then trying to delete the bucket will fail; this removes every
#      version and every delete marker first.
#
# Usage:
#   scripts/destroy-terraform-backend.sh <development|staging|production|all> <confirmation>
#
# Examples:
#   scripts/destroy-terraform-backend.sh staging staging
#   scripts/destroy-terraform-backend.sh all DESTROY-ALL-STATE-BUCKETS
#
# Requires AWS credentials for the TARGET environment's account to already
# be active in your shell — this script does not assume or switch accounts
# for you.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VALID_ENVIRONMENTS=("development" "staging" "production")

# ==============================================================================
# ARGUMENT VALIDATION
# ==============================================================================

if [[ $# -ne 2 ]]; then
  echo "ERROR: Usage: ${0} <development|staging|production|all> <confirmation>" >&2
  exit 1
fi

REQUESTED="$1"
CONFIRM="$2"

if [[ "${REQUESTED}" == "all" ]]; then
  # Every environment this project runs. An environment taken out of
  # environments.json can still be named on its own: removing its state bucket
  # is the last step of retiring it.
  mapfile -t TARGET_ENVIRONMENTS < <(bash "$(dirname "${BASH_SOURCE[0]}")/ci/enabled-environments.sh" | jq -r '.[]')
  [[ ${#TARGET_ENVIRONMENTS[@]} -gt 0 ]] || exit 1
  EXPECTED_CONFIRM="DESTROY-ALL-STATE-BUCKETS"
else
  MATCHED=false
  for ENV in "${VALID_ENVIRONMENTS[@]}"; do
    if [[ "${ENV}" == "${REQUESTED}" ]]; then
      MATCHED=true
      break
    fi
  done
  if [[ "${MATCHED}" != "true" ]]; then
    echo "ERROR: Unknown environment '${REQUESTED}'." >&2
    echo "       Must be one of: development, staging, production, all" >&2
    exit 1
  fi
  TARGET_ENVIRONMENTS=("${REQUESTED}")
  EXPECTED_CONFIRM="${REQUESTED}"
fi

if [[ "${CONFIRM}" != "${EXPECTED_CONFIRM}" ]]; then
  echo "ERROR: Confirmation text did not match." >&2
  echo "       Expected: ${EXPECTED_CONFIRM}" >&2
  echo "       Received: ${CONFIRM}" >&2
  exit 1
fi

for command in aws jq; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: Required command is not installed: ${command}" >&2
    exit 1
  fi
done

# ==============================================================================
# RESOLVE BUCKET NAME AND STATE KEY FROM backend.tf
#
# Same source of truth bootstrap-environment.sh uses — reads the literal
# values out of the environment's own backend.tf rather than duplicating a
# separate guess here.
# ==============================================================================

resolve_backend_value() {
  local BACKEND_FILE="$1"
  local FIELD="$2"

  sed -n "s/^[[:space:]]*${FIELD}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "${BACKEND_FILE}" \
    | head -n 1
}

# ==============================================================================
# CHECK WHETHER THE STATE STILL TRACKS REAL RESOURCES
#
# Treats a missing state object (never applied yet) or an empty
# "resources" array as safe to proceed. Anything else is a hard block —
# see SAFEGUARDS #1 above.
# ==============================================================================

check_state_is_empty() {
  local BUCKET_NAME="$1"
  local STATE_KEY="$2"

  local STATE_FILE
  STATE_FILE="$(mktemp)"

  if ! aws s3api get-object --bucket "${BUCKET_NAME}" --key "${STATE_KEY}" "${STATE_FILE}" >/dev/null 2>&1; then
    echo "No state file found at s3://${BUCKET_NAME}/${STATE_KEY} — nothing was ever tracked here. Safe to proceed."
    rm -f "${STATE_FILE}"
    return 0
  fi

  local RESOURCE_COUNT
  RESOURCE_COUNT="$(jq '.resources | length' "${STATE_FILE}" 2>/dev/null || echo "unknown")"
  rm -f "${STATE_FILE}"

  if [[ "${RESOURCE_COUNT}" == "unknown" ]]; then
    echo "ERROR: Could not parse the state file at s3://${BUCKET_NAME}/${STATE_KEY} to confirm it's empty." >&2
    echo "       Refusing to proceed without being able to verify this." >&2
    exit 1
  fi

  if [[ "${RESOURCE_COUNT}" -gt 0 ]]; then
    echo "ERROR: s3://${BUCKET_NAME}/${STATE_KEY} still tracks ${RESOURCE_COUNT} real resource(s)." >&2
    echo "       Destroying this bucket now would permanently orphan them — Terraform" >&2
    echo "       would have no record of them ever existing, with no way back." >&2
    echo "" >&2
    echo "       Run terraform-destroy.yml against this environment first (it has its" >&2
    echo "       own typed confirmation and approval gates), THEN re-run this script" >&2
    echo "       once the state is actually empty." >&2
    exit 1
  fi

  echo "State file exists but tracks zero resources. Safe to proceed."
}

# ==============================================================================
# EMPTY A VERSIONED BUCKET
#
# S3 will not delete a bucket containing any object version or delete
# marker, current or not. This removes every one of both.
#
# NOTE: delete-objects accepts at most 1000 keys per call. This bucket is
# a single-purpose state bucket (a state file, its version history, and
# occasional lock files) and isn't expected to ever approach that — if it
# somehow does, this would need pagination added.
# ==============================================================================

empty_versioned_bucket() {
  local BUCKET_NAME="$1"

  local VERSIONS_PAYLOAD
  VERSIONS_PAYLOAD="$(
    aws s3api list-object-versions \
      --bucket "${BUCKET_NAME}" \
      --output json \
      --query '{Objects: [(Versions[] // [])[], (DeleteMarkers[] // [])[]][].{Key:Key,VersionId:VersionId}}' \
      2>/dev/null || echo '{"Objects": []}'
  )"

  local OBJECT_COUNT
  OBJECT_COUNT="$(jq '.Objects | length' <<< "${VERSIONS_PAYLOAD}")"

  if [[ "${OBJECT_COUNT}" -eq 0 ]]; then
    echo "Bucket ${BUCKET_NAME} is already empty."
    return 0
  fi

  echo "Removing ${OBJECT_COUNT} object version(s)/delete marker(s) from ${BUCKET_NAME}."

  aws s3api delete-objects \
    --bucket "${BUCKET_NAME}" \
    --delete "${VERSIONS_PAYLOAD}" \
    >/dev/null
}

# ==============================================================================
# DESTROY A SINGLE ENVIRONMENT'S STATE BUCKET
# ==============================================================================

destroy_state_bucket() {
  local ENV_NAME="$1"
  local ENV_DIR="${REPO_ROOT}/infrastructure/${ENV_NAME}"
  local BACKEND_FILE="${ENV_DIR}/backend.tf"

  if [[ ! -f "${BACKEND_FILE}" ]]; then
    echo "ERROR: No backend.tf found for '${ENV_NAME}': ${BACKEND_FILE}" >&2
    exit 1
  fi

  local BUCKET_NAME STATE_KEY
  BUCKET_NAME="$(resolve_backend_value "${BACKEND_FILE}" "bucket")"
  STATE_KEY="$(resolve_backend_value "${BACKEND_FILE}" "key")"

  if [[ -z "${BUCKET_NAME}" ]]; then
    echo "ERROR: Could not find a 'bucket = \"...\"' line in ${BACKEND_FILE}." >&2
    exit 1
  fi

  if [[ -z "${STATE_KEY}" ]]; then
    echo "ERROR: Could not find a 'key = \"...\"' line in ${BACKEND_FILE}." >&2
    exit 1
  fi

  echo "============================================================"
  echo "Destroying state bucket for: ${ENV_NAME^^}"
  echo "Bucket: ${BUCKET_NAME}"
  echo "State:  ${STATE_KEY}"
  echo "============================================================"

  if ! aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    echo "Bucket ${BUCKET_NAME} does not exist. Nothing to do."
    echo ""
    return 0
  fi

  check_state_is_empty "${BUCKET_NAME}" "${STATE_KEY}"
  empty_versioned_bucket "${BUCKET_NAME}"

  echo "Deleting bucket ${BUCKET_NAME}."
  aws s3api delete-bucket --bucket "${BUCKET_NAME}"

  echo "State bucket destroyed for: ${ENV_NAME}"
  echo ""
}

# ==============================================================================
# RUN
# ==============================================================================

for ENV_NAME in "${TARGET_ENVIRONMENTS[@]}"; do
  destroy_state_bucket "${ENV_NAME}"
done

echo "============================================================"
echo "State bucket teardown complete for: ${TARGET_ENVIRONMENTS[*]}"
echo "============================================================"