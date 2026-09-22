#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# FLEET DEPLOY ENGINE
#
# 1. Syncs team-provided service directories from THIS TIER'S OWN prefix
#    within the fleet deploy bucket (--delete, so a team removing their
#    service cleans it up here too).
# 2. Discovers every service by presence: any subdirectory holding both a
#    docker-compose.yml (or .yaml) and a .env is deployed. There is no
#    manifest and no "active" flag -- removing either file is how a team takes
#    their service out of rotation.
# 3. Stops any service whose directory has disappeared from the bucket, before
#    the sync removes the local copy. Without this an S3 deletion removes the
#    files while the containers keep running indefinitely: "--remove-orphans"
#    only reaches within a single Compose project, not across separate ones.
# 4. For each service: resolves __FROM_SECRET__ references into a throwaway
#    scratch copy of its env file, checks the compose file against the compose
#    guard, deploys using that copy, then deletes it immediately.
#
# The shared pieces -- lock, jitter, ECR login, secret resolution, compose
# guard -- live in deploy-lib.sh next to this file, which is also used by the
# database host's update script.
#
# LAYOUT -- one directory per service:
#
#   <tier>/<service>/docker-compose.yml
#   <tier>/<service>/.env
#   <tier>/<service>/data/**
#
# Each service's compose file is run with its own directory as the Compose
# project directory, so relative paths inside it ("./data", ".resolved/.env")
# resolve against that service's own directory. The compose guard rejects any
# bind mount that leaves that directory.
#
# Re-runnable at any time -- re-syncs and re-resolves everything fresh on every
# invocation, whether that is the boot-time deploy or a later triggered update.
#
# JITTER_SECONDS (optional, environment): the maximum random delay before
# deploying. The secret-rotation trigger sets it so hosts do not all recreate a
# container at the same instant.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLICATION_ROOT="${APPLICATION_ROOT:-${SCRIPT_DIR}}"
SERVICES_DIR="${APPLICATION_ROOT}/services"
LOCK_FILE="${FLEET_LOCK_FILE:-/var/lock/fleet-update.lock}"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/deploy-lib.sh"


# ==============================================================================
# LOAD PLATFORM ENVIRONMENT
# ==============================================================================

# shellcheck source=/dev/null
source "${APPLICATION_ROOT}/.env"

: "${PROJECT_NAME:?PROJECT_NAME must be set in .env}"
: "${DEPLOY_BUCKET_NAME:?DEPLOY_BUCKET_NAME must be set in .env}"
: "${FLEET_TIER:?FLEET_TIER must be set in .env}"
: "${AWS_REGION:?AWS_REGION must be set in .env}"

export AWS_REGION

for required_command in docker aws jq flock; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${required_command}"
    exit 1
  fi
done


# ==============================================================================
# SERIALISE, DELAY, AUTHENTICATE
# ==============================================================================

deploy_lock "${LOCK_FILE}"

deploy_jitter "${JITTER_SECONDS:-0}"

if [[ -n "${ECR_REGISTRY_URL:-}" ]]; then
  ecr_login "${AWS_REGION}" "${ECR_REGISTRY_URL}"
fi


# ==============================================================================
# RECORD WHAT IS DEPLOYED NOW, BEFORE THE SYNC CHANGES IT
#
# Compared against the post-sync state to find services that were removed from
# the bucket, so their containers can be stopped rather than left running with
# their config deleted out from under them.
# ==============================================================================

mkdir -p "${SERVICES_DIR}"

services_before=()

shopt -s nullglob

for service_path in "${SERVICES_DIR}"/*/; do
  services_before+=("$(basename "${service_path}")")
done

shopt -u nullglob


# ==============================================================================
# SYNC TEAM-PROVIDED FILES FROM THE FLEET DEPLOY BUCKET
#
# Scoped by FLEET_TIER (private/ or internal/ within the shared bucket) rather
# than the bucket root: the two fleets run different applications, so each tier
# only ever syncs -- and is only permitted to read -- its own prefix.
#
# .resolved/ is excluded from --delete's consideration so scratch state is
# never removed mid-run, and is never uploaded because this sync only ever
# reads from S3.
# ==============================================================================

echo "Syncing services from s3://${DEPLOY_BUCKET_NAME}/${FLEET_TIER}/"

aws s3 sync \
  "s3://${DEPLOY_BUCKET_NAME}/${FLEET_TIER}/" \
  "${SERVICES_DIR}/" \
  --delete \
  --exclude "*/.resolved/*" \
  --only-show-errors


# ==============================================================================
# STOP SERVICES THAT WERE REMOVED FROM THE BUCKET
# ==============================================================================

for previous_service in "${services_before[@]:-}"; do

  [[ -z "${previous_service}" ]] && continue

  if [[ ! -d "${SERVICES_DIR}/${previous_service}" ]]; then

    echo "Service '${previous_service}' was removed from the bucket -- stopping it."

    # Best-effort: a service that is already stopped, or was never
    # successfully started, must not abort the whole deploy run.
    docker compose --project-name "${previous_service}" down --remove-orphans || true

  fi

done


# ==============================================================================
# DEPLOY EVERY DISCOVERED SERVICE
#
# Each service runs as its own Compose project, which is what gives services
# isolated networks with no extra wiring: Compose creates a shared network
# automatically within a project, never across projects.
#
# The resolved env file is passed BOTH ways on purpose:
#   --env-file  supplies ${VAR} interpolation into the compose file
#   env_file:   (declared in the compose file) injects into the container
# They are separate mechanisms; --env-file alone puts nothing inside the
# container, which is the single most common way this goes wrong.
#
# One service failing must not prevent the rest of the fleet from deploying --
# a co-tenant's broken config is not this host's problem. Failures are
# collected and reported at the end, and still fail the run so the SSM command
# surfaces as errored.
# ==============================================================================

deployed_count=0
skipped_count=0
failed_services=()

shopt -s nullglob

for service_path in "${SERVICES_DIR}"/*/; do

  service_path="${service_path%/}/"
  service_name="$(basename "${service_path}")"
  env_file="${service_path}.env"

  if ! compose_file="$(find_compose_file "${service_path}")" || [[ ! -f "${env_file}" ]]; then
    echo "WARNING: ${service_name} is missing its compose file or .env -- skipping."
    skipped_count=$((skipped_count + 1))
    continue
  fi

  echo "============================================================"
  echo "Deploying service: ${service_name}"
  echo "============================================================"

  resolved_dir="${service_path}.resolved"
  resolved_env_file="${resolved_dir}/.env"
  service_root="$(cd "${service_path}" && pwd -P)"

  mkdir -p "${resolved_dir}"
  chmod 0700 "${resolved_dir}"

  deploy_status=0

  # The compose guard runs after the env file is resolved because compose
  # refuses to render a file whose env_file: does not exist yet.
  if resolve_env_file "${env_file}" "${resolved_env_file}" \
    && compose_guard "${compose_file}" "${service_path}" "${resolved_env_file}" "[\"${service_root}\"]"; then

    docker compose \
      --project-directory "${service_path}" \
      --file "${compose_file}" \
      --project-name "${service_name}" \
      --env-file "${resolved_env_file}" \
      up \
      --detach \
      --remove-orphans \
      --wait \
      --wait-timeout 120 || deploy_status=$?

  else
    deploy_status=1
  fi

  # Delete the resolved copy immediately -- it must never outlive the one
  # "docker compose up" that needed it. Runs regardless of outcome.
  rm -rf "${resolved_dir}"

  if [[ ${deploy_status} -ne 0 ]]; then
    echo "ERROR: ${service_name} failed to deploy (exit ${deploy_status})."
    failed_services+=("${service_name}")
    continue
  fi

  deployed_count=$((deployed_count + 1))

done

shopt -u nullglob

echo "============================================================"
echo "Deployment complete: ${deployed_count} deployed, ${skipped_count} skipped, ${#failed_services[@]} failed."

if [[ ${#failed_services[@]} -gt 0 ]]; then
  echo "Failed services: ${failed_services[*]}"
  echo "============================================================"
  exit 1
fi

echo "============================================================"
