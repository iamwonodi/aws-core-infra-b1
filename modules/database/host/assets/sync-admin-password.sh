#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# BRING EACH ENGINE'S ADMINISTRATOR PASSWORD IN LINE WITH CORE'S SECRET
#
# The engine images read their administrator password only when their data
# folder is first created (POSTGRES_PASSWORD, MYSQL_ROOT_PASSWORD,
# MONGO_INITDB_ROOT_PASSWORD). After that, a new password in core's secret
# (terraform apply -replace on it) never reaches a running engine by itself, and
# everything that signs in as the administrator -- provisioning, the people step,
# an emergency sign-in -- would be refused. This makes each running engine's
# administrator password the secret's current one.
#
#   PostgreSQL  set every time, over the container's local socket, where the
#               image trusts "postgres" without a password.
#   MySQL       if the current password already works, nothing. Otherwise the
#   MongoDB     secret's previous version (AWSPREVIOUS, which Secrets Manager
#               keeps whenever the value changes) is used to sign in and set
#               the current one.
#
# A password that matches neither version (changed twice before the engine saw
# either, or by hand) stops the run with a message: see the runbook.
#
# Run by the <project>-database-provision-people document before the people step
# (core's apply), and by provision-service.sh before it provisions. SAFE TO RUN
# AGAIN; no password is ever printed.
#
# Usage: sync-admin-password.sh [postgres|mysql|mongodb]
#        Without an engine, every running engine.
#
# Configuration comes from the database workspace's .env: AWS_REGION,
# CORE_ROOT_SECRET_ARN.
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

for name in AWS_REGION CORE_ROOT_SECRET_ARN; do
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: ${name} is not set in ${ENV_FILE}." >&2
    exit 1
  fi
done

if [[ $# -gt 1 ]]; then
  echo "ERROR: Usage: ${0} [postgres|mysql|mongodb]" >&2
  exit 1
fi

REQUESTED="${1:-}"
ENGINES=(postgres mysql mongodb)

if [[ -n "${REQUESTED}" ]]; then
  case "${REQUESTED}" in
    postgres|mysql|mongodb) ENGINES=("${REQUESTED}") ;;
    *)
      echo "ERROR: '${REQUESTED}' is not an engine this script knows (postgres, mysql, mongodb)." >&2
      exit 1
      ;;
  esac
fi

# Core generates the password from letters, digits and -_., and the username is a
# plain name; both are interpolated into SQL or JavaScript run as the
# administrator, so nothing else is accepted.
PASSWORD_PATTERN='^[A-Za-z0-9._-]+$'
USERNAME_PATTERN='^[A-Za-z_][A-Za-z0-9_]*$'

secret_version() { # <AWSCURRENT|AWSPREVIOUS>
  aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${CORE_ROOT_SECRET_ARN}" \
    --version-stage "$1" \
    --query 'SecretString' \
    --output text
}

if ! CURRENT_JSON="$(secret_version AWSCURRENT)"; then
  echo "ERROR: could not read the administrator secret." >&2
  exit 1
fi

CURRENT="$(jq -r '.root_password // empty' <<< "${CURRENT_JSON}")"
ADMIN_USER="$(jq -r '.username // empty' <<< "${CURRENT_JSON}")"
CURRENT_JSON=""

if ! [[ "${CURRENT}" =~ ${PASSWORD_PATTERN} ]]; then
  echo "ERROR: the administrator secret's root_password is missing or outside core's alphabet (letters, digits and -_.)." >&2
  exit 1
fi

if ! [[ "${ADMIN_USER}" =~ ${USERNAME_PATTERN} ]]; then
  echo "ERROR: the administrator secret's username is missing or not a plain name." >&2
  exit 1
fi

# Read only when an engine refuses the current password: most runs need nothing
# but the current version.
PREVIOUS=""

load_previous() {
  local json

  [[ -n "${PREVIOUS}" ]] && return 0

  if ! json="$(secret_version AWSPREVIOUS 2>/dev/null)"; then
    echo "ERROR: the engine refuses the secret's current administrator password, and the secret has no previous version to sign in with." >&2
    return 1
  fi

  PREVIOUS="$(jq -r '.root_password // empty' <<< "${json}")"

  if ! [[ "${PREVIOUS}" =~ ${PASSWORD_PATTERN} ]]; then
    PREVIOUS=""
    echo "ERROR: the administrator secret's previous version has no usable root_password." >&2
    return 1
  fi
}

mismatch() { # <engine>
  echo "ERROR: ${1}'s administrator password matches neither the secret's current nor its previous version." >&2
  echo "       It was changed more than once since the engine last saw it, or by hand. See the runbook," >&2
  echo "       \"Changing an administrator password\"." >&2
}

container_for() {
  docker ps \
    --filter "label=com.docker.compose.project=db-$1" \
    --format '{{.Names}}' | head -n 1 || true
}

# ------------------------------------------------------------------------------
# Engines
# ------------------------------------------------------------------------------
# Each is called as "sync_<engine> || status=1", where set -e does not apply, so
# every step that changes something checks its own result.

sync_postgres() {
  local container="$1"

  # The statement goes in on stdin, never on the command line.
  printf "ALTER ROLE postgres WITH PASSWORD '%s';\n" "${CURRENT}" |
    docker exec -i "${container}" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 || return 1

  echo "postgres: the administrator password is the secret's current one."
}

mysql_works() { # <container> <password>
  docker exec -i -e MYSQL_PWD="$2" "$1" mysql -uroot -N -B -e "SELECT 1" >/dev/null 2>&1
}

sync_mysql() {
  local container="$1"

  if mysql_works "${container}" "${CURRENT}"; then
    echo "mysql: the administrator password is already the secret's current one."
    return 0
  fi

  load_previous || return 1

  if ! mysql_works "${container}" "${PREVIOUS}"; then
    mismatch mysql
    return 1
  fi

  # CURRENT_USER() is the account just signed in as, whichever host it names.
  printf "ALTER USER CURRENT_USER() IDENTIFIED BY '%s';\n" "${CURRENT}" |
    docker exec -i -e MYSQL_PWD="${PREVIOUS}" "${container}" mysql -uroot || return 1

  echo "mysql: the administrator password was the previous one; it is now the secret's current one."
}

mongodb_works() { # <container> <password>
  printf '%s\n' \
    "try { db.getSiblingDB('admin').auth(process.env.ADMIN_USER, process.env.ADMIN_PWD); } catch (e) { quit(3); }" |
    docker exec -i -e ADMIN_USER="${ADMIN_USER}" -e ADMIN_PWD="$2" "$1" mongosh --quiet >/dev/null 2>&1
}

sync_mongodb() {
  local container="$1"

  if mongodb_works "${container}" "${CURRENT}"; then
    echo "mongodb: the administrator password is already the secret's current one."
    return 0
  fi

  load_previous || return 1

  if ! mongodb_works "${container}" "${PREVIOUS}"; then
    mismatch mongodb
    return 1
  fi

  printf '%s\n' \
    "db.getSiblingDB('admin').auth(process.env.ADMIN_USER, process.env.ADMIN_PWD);" \
    "db.getSiblingDB('admin').changeUserPassword(process.env.ADMIN_USER, process.env.NEW_PWD);" |
    docker exec -i -e ADMIN_USER="${ADMIN_USER}" -e ADMIN_PWD="${PREVIOUS}" -e NEW_PWD="${CURRENT}" "${container}" mongosh --quiet || return 1

  echo "mongodb: the administrator password was the previous one; it is now the secret's current one."
}

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

status=0

for engine in "${ENGINES[@]}"; do
  container="$(container_for "${engine}")"

  if [[ -z "${container}" ]]; then
    if [[ -n "${REQUESTED}" ]]; then
      echo "ERROR: no running container for ${engine} (Compose project db-${engine})." >&2
      status=1
    fi
    continue
  fi

  "sync_${engine}" "${container}" || status=1
done

CURRENT=""
PREVIOUS=""

exit "${status}"
