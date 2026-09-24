#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PROVISION ONE SERVICE'S DATABASE
#
# What the <project>-database-provision SSM document runs. A service's
# infrastructure repository publishes its provisioning request to the deploy
# bucket and then sends that document; this fetches the request and carries it
# out against the running engine.
#
#   s3://<deploy bucket>/provisioning/<service>/config.json   (required)
#   s3://<deploy bucket>/provisioning/<service>/extra.sql     (optional)
#
# WHO WRITES THE SQL. Core does. The database, the user, its password and its
# grants are created by core's own script for the engine (provisioning/<engine>),
# so every service is provisioned the same way and no service writes its own
# CREATE DATABASE. A service may add extra.sql for its own needs (an extension, a
# schema), and that runs as the SERVICE's user on the service's own database,
# never as the administrator: otherwise a line of a service's SQL would have full
# control of every other service's data on the same engine.
#
# SAFE TO RUN AGAIN. Terraform triggers this on every apply of the service, so
# every step is conditional and the password is set each time -- which is what
# makes a rotated secret heal itself on the next apply.
#
# AFTERWARDS it runs provision-people.sh on the same engine, so the team's own
# logins can reach the new database at once.
#
# WHAT IT DOES NOT DO: create the secret (the service's infrastructure repository
# does, and generates the credentials into it), start or deploy an engine
# (update.sh does), or reach any service other than the one named.
#
# Usage: provision-service.sh <service>
#
# Configuration comes from the database workspace's .env, as for the other
# database scripts: PROJECT_NAME, ENVIRONMENT, AWS_REGION, DATABASE_WORKSPACE,
# DEPLOY_BUCKET_NAME.
# ==============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: the database host's environment file is missing: ${ENV_FILE}" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

SERVICE="${1:-}"

if [[ $# -ne 1 ]]; then
  echo "ERROR: Usage: ${0} <service>" >&2
  exit 1
fi

# The service name arrives as an SSM document parameter, and is used to build an
# S3 key and file paths. Holding it to core's own service-name rule is what stops
# a name like "../other" reaching another service's request.
if ! [[ "${SERVICE}" =~ ^[a-z][a-z0-9-]{1,20}[a-z0-9]$ ]]; then
  echo "ERROR: '${SERVICE}' is not a valid service name." >&2
  exit 1
fi

for name in AWS_REGION DATABASE_WORKSPACE DEPLOY_BUCKET_NAME; do
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: ${name} is not set in ${ENV_FILE}." >&2
    exit 1
  fi
done

CONFIGS_DIR="${DATABASE_WORKSPACE}/configs"
INITS_DIR="${DATABASE_WORKSPACE}/inits"

mkdir -p "${CONFIGS_DIR}" "${INITS_DIR}"

CONFIG_FILE="${CONFIGS_DIR}/${SERVICE}.json"
EXTRA_FILE="${INITS_DIR}/${SERVICE}-extra.sql"

# Whatever a previous run left behind is not this run's request.
rm -f "${CONFIG_FILE}" "${EXTRA_FILE}"

# ------------------------------------------------------------------------------
# Fetch the request
# ------------------------------------------------------------------------------

echo "Fetching the provisioning request for '${SERVICE}'."

if ! aws s3api get-object \
  --bucket "${DEPLOY_BUCKET_NAME}" \
  --key "provisioning/${SERVICE}/config.json" \
  --region "${AWS_REGION}" \
  "${CONFIG_FILE}" >/dev/null 2>&1; then

  echo "ERROR: no provisioning request at s3://${DEPLOY_BUCKET_NAME}/provisioning/${SERVICE}/config.json." >&2
  echo "       The service's infrastructure repository publishes it; has it applied yet?" >&2
  exit 1
fi

HAS_EXTRA=false

if aws s3api get-object \
  --bucket "${DEPLOY_BUCKET_NAME}" \
  --key "provisioning/${SERVICE}/extra.sql" \
  --region "${AWS_REGION}" \
  "${EXTRA_FILE}" >/dev/null 2>&1; then
  HAS_EXTRA=true
  echo "The service also published extra.sql."
fi

# ------------------------------------------------------------------------------
# Check the request
# ------------------------------------------------------------------------------

if ! jq -e 'type == "object"' "${CONFIG_FILE}" >/dev/null 2>&1; then
  echo "ERROR: the provisioning request is not a JSON object." >&2
  exit 1
fi

CONFIG_SERVICE="$(jq -r '.service_name // empty' "${CONFIG_FILE}")"
ENGINE="$(jq -r '.database_engine // empty' "${CONFIG_FILE}")"

# A request published under one service's prefix must not provision another's.
if [[ "${CONFIG_SERVICE}" != "${SERVICE}" ]]; then
  echo "ERROR: the request under provisioning/${SERVICE}/ names the service '${CONFIG_SERVICE}'." >&2
  exit 1
fi

INIT_SCRIPT=""

# The platform scripts are installed flat in the workspace, each named after its
# S3 key's last segment.
case "${ENGINE}" in
  postgres) INIT_SCRIPT="${SCRIPT_DIR}/provision-postgres.sql" ;;
  mysql)    INIT_SCRIPT="${SCRIPT_DIR}/provision-mysql.sql" ;;
  mongodb)  INIT_SCRIPT="${SCRIPT_DIR}/provision-mongodb.js" ;;
  *)
    echo "ERROR: core has no provisioning script for the engine '${ENGINE}'." >&2
    echo "       Supported: postgres, mysql, mongodb." >&2
    exit 1
    ;;
esac

if [[ ! -s "${INIT_SCRIPT}" ]]; then
  echo "ERROR: core's provisioning script is missing: ${INIT_SCRIPT}" >&2
  echo "       Refresh the host's platform scripts (<project>-database-refresh-scripts)." >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Provision
# ------------------------------------------------------------------------------

echo "Creating the database and user for '${SERVICE}' on ${ENGINE}."

bash "${SCRIPT_DIR}/provision.sh" "${CONFIG_FILE}" "${INIT_SCRIPT}" admin

if [[ "${HAS_EXTRA}" == "true" ]]; then
  echo "Running the service's extra script as its own user."
  bash "${SCRIPT_DIR}/provision.sh" "${CONFIG_FILE}" "${EXTRA_FILE}" service
fi

# The team's logins (agent_<name>, core's people list) reach the new database
# straight away, rather than at core's next apply.
echo "Bringing the team's logins up to date on ${ENGINE}."
bash "${SCRIPT_DIR}/provision-people.sh" "${ENGINE}"

echo "Provisioned '${SERVICE}'."
