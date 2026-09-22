#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DATABASE DEPLOY ENGINE
#
# The platforms team owns the database engines. Each engine is a folder holding
# a docker-compose.yaml (or .yml) and a .env, and a single registry lists the
# engines and the port each one is reachable on. They are published to the
# deploy bucket:
#
#   database/registry.json                      { "<engine>": { "port": 20001, "active": true }, ... }
#   database/engines/<engine>/docker-compose.yaml
#   database/engines/<engine>/.env
#
# This script syncs them and runs each active engine as its own Compose project
# named db-<engine>. It is triggered over SSM (the <project>-database-update
# document) after the platforms pipeline uploads a change, and once at boot.
#
# The publishing order matters: the pipeline uploads the engine folders first
# and registry.json LAST. An engine that is not in the registry is never
# started, so a half-finished upload cannot start anything.
#
# WHAT STARTS AND STOPS AN ENGINE
#
#   active: true (or omitted)  -> deployed (compose up --wait)
#   active: false              -> stopped (compose stop)
#   removed from the registry  -> left running, untouched
#   folder removed from S3     -> left running, untouched
#
# A database must never be stopped as a side effect of a file disappearing --
# that is a different rule from the fleet, where removal stops a service. Only
# an explicit "active": false stops an engine, and NOTHING here ever removes a
# container or a volume ("down", "down -v", "rm"). Data lives on the persistent
# data volume regardless.
#
# WHAT AN ENGINE'S COMPOSE FILE CAN RELY ON
#
#   ${DATA_ROOT}   persistent data directory root, e.g. ${DATA_ROOT}/postgres
#   ${ENGINE_NAME} the engine's folder name
#   ${ENGINE_PORT} the port from the registry -- publish it: "${ENGINE_PORT}:5432"
#
# and, in the engine's .env, secrets by reference:
#
#   POSTGRES_PASSWORD=__FROM_SECRET__:CORE_ROOT_SECRET_ARN:root_password
#
# CORE_ROOT_SECRET_ARN is provided by this script (the ARN of the database
# administrator secret). The four names above are reserved: an engine .env may
# not define them. The compose file must load its env with
# "env_file: .resolved/.env", the secret-resolved scratch copy, exactly like a
# fleet service.
#
# The compose guard (deploy-lib.sh) rejects privileged containers, host
# namespaces, the Docker socket, and bind mounts outside the engine's own
# folder and DATA_ROOT -- so a data directory that is NOT on the persistent
# volume is refused instead of silently losing data on the next instance
# replacement. It also refuses images that are not from this account's ECR
# registry when REQUIRE_ECR_IMAGES=true, because the isolated tier has no
# internet path to pull from Docker Hub.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/deploy-lib.sh"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/.env"

: "${PROJECT_NAME:?PROJECT_NAME is not defined}"
: "${DATABASE_WORKSPACE:?DATABASE_WORKSPACE is not defined}"
: "${AWS_REGION:?AWS_REGION is not defined}"
: "${DEPLOY_BUCKET_NAME:?DEPLOY_BUCKET_NAME is not defined}"
: "${DATA_ROOT:?DATA_ROOT is not defined}"
: "${CORE_ROOT_SECRET_ARN:?CORE_ROOT_SECRET_ARN is not defined}"

export AWS_REGION

ENABLE_ECR_ACCESS="${ENABLE_ECR_ACCESS:-false}"
REQUIRE_ECR_IMAGES="${REQUIRE_ECR_IMAGES:-false}"

ENGINES_DIR="${DATABASE_WORKSPACE}/engines"
REGISTRY_FILE="${DATABASE_WORKSPACE}/registry.json"
LOCK_FILE="${DATABASE_LOCK_FILE:-/var/lock/database-update.lock}"

for required_command in docker aws jq flock; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${required_command}"
    exit 1
  fi
done

# Names an engine's .env may not define, because this script provides them.
RESERVED_KEYS_PATTERN='^(DATA_ROOT|ENGINE_NAME|ENGINE_PORT|CORE_ROOT_SECRET_ARN)='


# ==============================================================================
# SERIALISE, AUTHENTICATE
# ==============================================================================

deploy_lock "${LOCK_FILE}"

if [[ "${ENABLE_ECR_ACCESS}" == "true" ]]; then
  : "${ECR_REGISTRY_URL:?ECR_REGISTRY_URL is required when ECR access is enabled}"
  ecr_login "${AWS_REGION}" "${ECR_REGISTRY_URL}"
fi

image_prefix=""

if [[ "${REQUIRE_ECR_IMAGES}" == "true" ]]; then
  : "${ECR_REGISTRY_URL:?ECR_REGISTRY_URL is required when REQUIRE_ECR_IMAGES is true}"
  image_prefix="${ECR_REGISTRY_URL}/"
fi


# ==============================================================================
# SYNC THE PLATFORMS TEAM'S DEFINITIONS
#
# No registry means the platforms team has not published anything yet. That is
# a successful no-op, not an error: the host can be provisioned before they do.
# ==============================================================================

if ! aws s3api head-object \
  --bucket "${DEPLOY_BUCKET_NAME}" \
  --key "database/registry.json" \
  --region "${AWS_REGION}" >/dev/null 2>&1; then

  echo "No database/registry.json in s3://${DEPLOY_BUCKET_NAME}/ -- nothing to deploy."
  exit 0

fi

mkdir -p "${ENGINES_DIR}"

echo "Syncing engine definitions from s3://${DEPLOY_BUCKET_NAME}/database/"

aws s3 sync \
  "s3://${DEPLOY_BUCKET_NAME}/database/engines/" \
  "${ENGINES_DIR}/" \
  --delete \
  --exclude "*/.resolved/*" \
  --only-show-errors

aws s3 cp \
  "s3://${DEPLOY_BUCKET_NAME}/database/registry.json" \
  "${REGISTRY_FILE}.new" \
  --region "${AWS_REGION}" \
  --only-show-errors


# ==============================================================================
# VALIDATE THE REGISTRY BEFORE ACTING ON IT
#
# A bad registry stops the run with the previous registry left in place. The
# same rules should also be enforced in the platforms repository's CI; this is
# the last line of defence on the host.
# ==============================================================================

# "// true" must NOT be used to default "active": in jq, false // true is true,
# which would silently turn "active": false into "active": true.
registry_errors="$(jq -r '
  def is_active: if .value.active == null then true else .value.active end;
  if type != "object" then "registry.json must be a JSON object keyed by engine name"
  else
    (to_entries[]
      | select(
          (.key | test("^[a-z0-9][a-z0-9-]{0,40}$") | not)
          or ((.value | type) != "object")
          or ((.value.port | type) != "number")
          or (.value.port != (.value.port | floor))
          or (.value.port < 1024)
          or (.value.port > 65535)
          or ((is_active | type) != "boolean")
        )
      | "invalid entry \"\(.key)\": needs a lowercase name, an integer port from 1024 to 65535, and a boolean active"),
    ([to_entries[] | select((.value | type) == "object") | select(is_active) | {key, port: .value.port}]
      | group_by(.port) | map(select(length > 1))[]
      | "port \(.[0].port) is used by more than one active engine: \(map(.key) | join(", "))")
  end
' "${REGISTRY_FILE}.new" 2>&1 || true)"

if [[ -n "${registry_errors}" ]]; then
  echo "ERROR: registry.json was rejected; nothing was changed:"
  printf '%s\n' "${registry_errors}" | sed 's/^/       - /'
  rm -f "${REGISTRY_FILE}.new"
  exit 1
fi

mv "${REGISTRY_FILE}.new" "${REGISTRY_FILE}"


# ==============================================================================
# APPLY THE REGISTRY, ONE ENGINE AT A TIME
#
# One engine failing must not stop the others. Failures are collected and
# reported at the end, and still fail the run so the SSM command shows errored.
# ==============================================================================

deployed_count=0
stopped_count=0
failed_engines=()

mapfile -t registry_lines < <(jq -r '
  def is_active: if .value.active == null then true else .value.active end;
  to_entries | sort_by(.key)[]
  | [.key, (.value.port | tostring), (is_active | tostring)] | @tsv
' "${REGISTRY_FILE}")

for line in "${registry_lines[@]:-}"; do

  [[ -z "${line}" ]] && continue

  IFS=$'\t' read -r engine port active <<< "${line}"

  project="db-${engine}"

  echo "============================================================"
  echo "Engine: ${engine} (port ${port}, active: ${active})"
  echo "============================================================"

  if [[ "${active}" == "false" ]]; then
    echo "Stopping ${project} (active: false). Data is kept."
    docker compose --project-name "${project}" stop || true
    stopped_count=$((stopped_count + 1))
    continue
  fi

  engine_dir="${ENGINES_DIR}/${engine}"
  env_file="${engine_dir}/.env"

  if ! compose_file="$(find_compose_file "${engine_dir}")" || [[ ! -f "${env_file}" ]]; then
    echo "ERROR: ${engine} is registered but its folder is missing a compose file or .env."
    failed_engines+=("${engine}")
    continue
  fi

  if grep -qE "${RESERVED_KEYS_PATTERN}" "${env_file}"; then
    echo "ERROR: ${env_file} defines a reserved name. DATA_ROOT, ENGINE_NAME, ENGINE_PORT and CORE_ROOT_SECRET_ARN are provided by the platform."
    failed_engines+=("${engine}")
    continue
  fi

  engine_root="$(cd "${engine_dir}" && pwd -P)"
  data_root="$(realpath -m "${DATA_ROOT}")"

  resolved_dir="${engine_dir}/.resolved"
  source_env="${resolved_dir}/.source.env"
  resolved_env="${resolved_dir}/.env"

  mkdir -p "${resolved_dir}"
  chmod 0700 "${resolved_dir}"

  # The platform values come FIRST. The secret resolver looks up an ARN
  # variable by its first occurrence while Compose lets the last one win; the
  # reserved-name check above is what keeps the two from ever disagreeing.
  # "sed" adds the trailing newline an env file may lack.
  {
    printf 'DATA_ROOT=%s\n' "${data_root}"
    printf 'ENGINE_NAME=%s\n' "${engine}"
    printf 'ENGINE_PORT=%s\n' "${port}"
    printf 'CORE_ROOT_SECRET_ARN=%s\n' "${CORE_ROOT_SECRET_ARN}"
    sed '$a\' "${env_file}"
  } > "${source_env}"

  chmod 0600 "${source_env}"

  deploy_status=0

  if resolve_env_file "${source_env}" "${resolved_env}" \
    && compose_guard "${compose_file}" "${engine_dir}" "${resolved_env}" \
      "$(jq -cn --arg a "${engine_root}" --arg b "${data_root}" '[$a, $b]')" "${image_prefix}"; then

    docker compose \
      --project-directory "${engine_dir}" \
      --file "${compose_file}" \
      --project-name "${project}" \
      --env-file "${resolved_env}" \
      up \
      --detach \
      --remove-orphans \
      --wait \
      --wait-timeout 180 || deploy_status=$?

  else
    deploy_status=1
  fi

  # The resolved copy must never outlive the one "docker compose up" that
  # needed it. Runs regardless of outcome.
  rm -rf "${resolved_dir}"

  if [[ ${deploy_status} -ne 0 ]]; then
    echo "ERROR: ${engine} failed to deploy (exit ${deploy_status})."
    failed_engines+=("${engine}")
    continue
  fi

  deployed_count=$((deployed_count + 1))

done


# ==============================================================================
# FOLDERS THAT ARE NOT IN THE REGISTRY
#
# Worth a warning -- usually a forgotten registry entry -- but never acted on.
# ==============================================================================

shopt -s nullglob

for engine_path in "${ENGINES_DIR}"/*/; do

  engine="$(basename "${engine_path}")"

  if ! jq -e --arg e "${engine}" 'has($e)' "${REGISTRY_FILE}" >/dev/null; then
    echo "WARNING: ${engine} has a folder but no entry in registry.json -- it is not started."
  fi

done

shopt -u nullglob

echo "============================================================"
echo "Database update complete: ${deployed_count} deployed, ${stopped_count} stopped, ${#failed_engines[@]} failed."

if [[ ${#failed_engines[@]} -gt 0 ]]; then
  echo "Failed engines: ${failed_engines[*]}"
  echo "============================================================"
  exit 1
fi

echo "============================================================"
