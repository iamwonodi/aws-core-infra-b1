#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PROVISION PEOPLE'S LOGINS
#
# People's own database logins are <scope>.<name>, at two scopes:
#
#   platform  platform.<name>, core's platform list, on EVERY service's database.
#             From <project>-database-people-<environment>-secret-vault:
#               { "platform.<name>": { "password", "access" } }
#             Run by the <project>-database-provision-people SSM document (after
#             core's apply) and after every service is provisioned.
#
#   service   <service>.<name>, a service's agents, on THAT service's database
#             only. From the "agents" entry of the service's own secret, a JSON
#             object { "<name>": { "password", "access" } }. Run by
#             provision-service.sh whenever the service is provisioned.
#
# Each run makes the engine's logins of ITS scope match the list exactly: a
# listed person gets their login with their password and "read" (look at and
# query data) or "write" (also add, change and delete rows); neither can change
# tables. A login of the scope no longer listed is removed. Logins of any other
# scope are never touched: which logins are the scope's is decided by an exact
# pattern, never by LIKE, where "_" in a service's name would be a wildcard.
#
#   PostgreSQL  the scope's groups, <scope>.group_read and <scope>.group_write,
#               granted on its databases with default privileges, so tables a
#               service creates later are covered too.
#   MySQL       grants on its databases given to each person; a database-level
#               grant already covers tables created later.
#   MongoDB     platform: readAnyDatabase / readWriteAnyDatabase on admin;
#               service: read / readWrite on the service's database.
#
# The staging and production functions do the same on the managed databases
# (modules/database/provisioning). SAFE TO RUN AGAIN.
#
# Usage:
#   provision-people.sh [platform [postgres|mysql|mongodb]]
#       Without an engine, every running engine.
#   provision-people.sh service <provisioning-request.json>
#       The request provision-service.sh fetched: engine, secret, key names.
#
# Configuration comes from the database workspace's .env: PROJECT_NAME,
# ENVIRONMENT, AWS_REGION, CORE_ROOT_SECRET_ARN.
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

for name in PROJECT_NAME ENVIRONMENT AWS_REGION CORE_ROOT_SECRET_ARN; do
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: ${name} is not set in ${ENV_FILE}." >&2
    exit 1
  fi
done

NAME_PATTERN='^[a-z][a-z0-9]{1,19}$'
PASSWORD_PATTERN='^[A-Za-z0-9._-]+$'
IDENTIFIER_PATTERN='^[A-Za-z_][A-Za-z0-9_]*$'
SCOPE_PATTERN='^[a-z][a-z0-9_]{1,21}$'
LOGIN_MAX=32 # MySQL's limit, held on every engine

MODE="${1:-platform}"
ENGINES=(postgres mysql mongodb)
REQUESTED=""
SCOPE=""
SERVICE_DATABASE=""

aws_secret() {
  aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "$1" \
    --query 'SecretString' \
    --output text
}

case "${MODE}" in
  platform)
    if [[ $# -gt 2 ]]; then
      echo "ERROR: Usage: ${0} [platform [postgres|mysql|mongodb]] | service <request.json>" >&2
      exit 1
    fi
    REQUESTED="${2:-}"
    SCOPE="platform"
    ;;
  service)
    if [[ $# -ne 2 || ! -f "$2" ]]; then
      echo "ERROR: Usage: ${0} service <provisioning-request.json>" >&2
      exit 1
    fi
    REQUESTED="$(jq -r '.database_engine // empty' "$2")"
    ;;
  *)
    echo "ERROR: '${MODE}' is not a mode: platform or service." >&2
    exit 1
    ;;
esac

if [[ -n "${REQUESTED}" ]]; then
  case "${REQUESTED}" in
    postgres|mysql|mongodb) ENGINES=("${REQUESTED}") ;;
    *)
      echo "ERROR: '${REQUESTED}' is not an engine this script provisions people on (postgres, mysql, mongodb)." >&2
      exit 1
      ;;
  esac
fi

# ------------------------------------------------------------------------------
# The list
# ------------------------------------------------------------------------------
# Into PEOPLE_NAMES / PEOPLE_ACCESS / PEOPLE_PASSWORDS, every value checked:
# everything below is interpolated into SQL or JavaScript run as the
# administrator, so nothing reaches it unchecked.

if [[ "${MODE}" == "platform" ]]; then
  PEOPLE_SECRET_ID="${PEOPLE_SECRET_ID:-${PROJECT_NAME}-database-people-${ENVIRONMENT}-secret-vault}"
  echo "Reading the platform list, ${PEOPLE_SECRET_ID}."

  if ! SECRET_JSON="$(aws_secret "${PEOPLE_SECRET_ID}")"; then
    echo "ERROR: could not read the people secret ${PEOPLE_SECRET_ID}. Core creates it with the people list; has core been applied?" >&2
    exit 1
  fi
  if ! jq -e 'type == "object"' <<< "${SECRET_JSON}" >/dev/null 2>&1; then
    echo "ERROR: the people secret is not a JSON object." >&2
    exit 1
  fi
  if jq -e 'keys | map(select(startswith("platform.") | not)) | length > 0' <<< "${SECRET_JSON}" >/dev/null; then
    echo "ERROR: every login in the people secret must be platform.<name>." >&2
    exit 1
  fi
  LIST_JSON="$(jq -c 'with_entries(.key |= ltrimstr("platform."))' <<< "${SECRET_JSON}")"
else
  REQUEST="$2"
  SECRET_ARN="$(jq -r '.database_secrets_arn // empty' "${REQUEST}")"
  DB_KEY="$(jq -r '.secret_mappings.db_key // empty' "${REQUEST}")"
  USER_KEY="$(jq -r '.secret_mappings.user_key // empty' "${REQUEST}")"

  if [[ -z "${SECRET_ARN}" || -z "${DB_KEY}" || -z "${USER_KEY}" ]]; then
    echo "ERROR: the provisioning request names no secret or key names." >&2
    exit 1
  fi

  SECRET_JSON="$(aws_secret "${SECRET_ARN}")"
  SERVICE_DATABASE="$(jq -r --arg k "${DB_KEY}" '.[$k] // empty' <<< "${SECRET_JSON}")"
  SCOPE="$(jq -r --arg k "${USER_KEY}" '.[$k] // empty' <<< "${SECRET_JSON}")"

  if ! [[ "${SERVICE_DATABASE}" =~ ${IDENTIFIER_PATTERN} && "${SCOPE}" =~ ${SCOPE_PATTERN} ]]; then
    echo "ERROR: the service's database or user in its secret is not a plain name." >&2
    exit 1
  fi

  # The agents entry is itself JSON, as a string (the secret's values are strings).
  if ! LIST_JSON="$(jq -c '(.agents // "{}") | if type == "string" then fromjson else . end' <<< "${SECRET_JSON}" 2>/dev/null)"; then
    echo "ERROR: the service secret's agents entry is not JSON." >&2
    exit 1
  fi
  echo "Reading ${SCOPE}'s agents from its secret."
fi

SECRET_JSON=""

if ! jq -e 'type == "object"' <<< "${LIST_JSON}" >/dev/null 2>&1; then
  echo "ERROR: the ${SCOPE} list is not a JSON object." >&2
  exit 1
fi

PEOPLE_NAMES=()
PEOPLE_ACCESS=()
PEOPLE_PASSWORDS=()

while IFS=$'\t' read -r name access password; do
  [[ -z "${name}" ]] && continue

  if ! [[ "${name}" =~ ${NAME_PATTERN} ]]; then
    echo "ERROR: '${name}' in the ${SCOPE} list is not a name: 2-20 lowercase letters and digits, starting with a letter." >&2
    exit 1
  fi
  if [[ $(( ${#SCOPE} + 1 + ${#name} )) -gt ${LOGIN_MAX} ]]; then
    echo "ERROR: ${SCOPE}.${name} is longer than ${LOGIN_MAX} characters, MySQL's limit: shorten the name." >&2
    exit 1
  fi
  if [[ "${access}" != "read" && "${access}" != "write" ]]; then
    echo "ERROR: ${SCOPE}.${name} has no access level of read or write." >&2
    exit 1
  fi
  if ! [[ "${password}" =~ ${PASSWORD_PATTERN} ]]; then
    echo "ERROR: ${SCOPE}.${name}'s password is outside core's alphabet (letters, digits and -_.)." >&2
    exit 1
  fi

  PEOPLE_NAMES+=("${name}")
  PEOPLE_ACCESS+=("${access}")
  PEOPLE_PASSWORDS+=("${password}")
done < <(jq -r 'to_entries | sort_by(.key)[] | [.key, (.value.access // ""), (.value.password // "")] | @tsv' <<< "${LIST_JSON}")

LIST_JSON=""

# Exactly this scope's people logins: <scope>.<name>, nothing else.
LOGIN_OF_SCOPE="^${SCOPE}\\.[a-z][a-z0-9]{1,19}\$"

echo "The ${SCOPE} list has ${#PEOPLE_NAMES[@]} person(s)."

is_listed() {
  local candidate="$1" name
  for name in "${PEOPLE_NAMES[@]}"; do
    [[ "${SCOPE}.${name}" == "${candidate}" ]] && return 0
  done
  return 1
}

# ------------------------------------------------------------------------------
# The administrator
# ------------------------------------------------------------------------------

DB_ROOT_PASSWORD="$(
  aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${CORE_ROOT_SECRET_ARN}" \
    --query 'SecretString' \
    --output text | jq -er '.root_password'
)"

# ------------------------------------------------------------------------------
# Engines
# ------------------------------------------------------------------------------

container_for() {
  docker ps \
    --filter "label=com.docker.compose.project=db-$1" \
    --format '{{.Names}}' | head -n 1 || true
}

psql_query() { # <container> <database> <sql>
  docker exec -i "$1" psql -U postgres -d "$2" -tA -v ON_ERROR_STOP=1 -c "$3"
}

mysql_query() { # <container> <sql>
  docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "$1" mysql -uroot -N -B -e "$2"
}

people_postgres() {
  local container="$1" databases=() existing=() database login i member other
  local read="\"${SCOPE}.group_read\"" write="\"${SCOPE}.group_write\""

  if [[ "${MODE}" == "service" ]]; then
    databases=("${SERVICE_DATABASE}")
  else
    # Every service's database: owned by a role of its own name (core's convention).
    while IFS= read -r database; do
      [[ -z "${database}" ]] && continue
      [[ "${database}" =~ ${IDENTIFIER_PATTERN} ]] && databases+=("${database}")
    done < <(psql_query "${container}" postgres \
      "SELECT d.datname FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba WHERE r.rolname = d.datname AND NOT d.datistemplate AND d.datname <> 'postgres' ORDER BY 1")
  fi

  # This scope's people logins now: candidates by prefix, then the exact pattern.
  while IFS= read -r login; do
    [[ "${login}" =~ ${LOGIN_OF_SCOPE} ]] && existing+=("${login}")
  done < <(psql_query "${container}" postgres "SELECT rolname FROM pg_roles WHERE starts_with(rolname, '${SCOPE}.') ORDER BY 1")

  echo "PostgreSQL: ${#databases[@]} database(s) for ${SCOPE}."

  {
    echo '\set ON_ERROR_STOP on'

    for group in "${SCOPE}.group_read" "${SCOPE}.group_write"; do
      echo "SELECT 'CREATE ROLE \"${group}\" NOLOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${group}')"
      echo '\gexec'
    done

    for database in "${databases[@]}"; do
      echo "GRANT CONNECT ON DATABASE \"${database}\" TO ${read}, ${write};"
    done

    for i in "${!PEOPLE_NAMES[@]}"; do
      login="${SCOPE}.${PEOPLE_NAMES[$i]}"
      if [[ "${PEOPLE_ACCESS[$i]}" == "write" ]]; then member="${write}" other="${read}"
      else member="${read}" other="${write}"; fi

      echo "SELECT 'CREATE ROLE \"${login}\" LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${login}')"
      echo '\gexec'
      echo "ALTER ROLE \"${login}\" WITH LOGIN PASSWORD '${PEOPLE_PASSWORDS[$i]}';"
      echo "GRANT ${member} TO \"${login}\";"
      echo "REVOKE ${other} FROM \"${login}\";"
    done

    for login in "${existing[@]}"; do
      is_listed "${login}" || echo "DROP ROLE \"${login}\";"
    done

    for database in "${databases[@]}"; do
      echo "\\connect ${database}"
      echo "GRANT USAGE ON SCHEMA public TO ${read}, ${write};"
      echo "GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${read};"
      echo "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ${read};"
      echo "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${write};"
      echo "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO ${write};"
      # Tables and sequences the service creates later, through its migrations.
      echo "ALTER DEFAULT PRIVILEGES FOR ROLE \"${database}\" IN SCHEMA public GRANT SELECT ON TABLES TO ${read};"
      echo "ALTER DEFAULT PRIVILEGES FOR ROLE \"${database}\" IN SCHEMA public GRANT SELECT ON SEQUENCES TO ${read};"
      echo "ALTER DEFAULT PRIVILEGES FOR ROLE \"${database}\" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${write};"
      echo "ALTER DEFAULT PRIVILEGES FOR ROLE \"${database}\" IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO ${write};"
    done
  } | docker exec -i "${container}" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1

  for login in "${existing[@]}"; do
    is_listed "${login}" || echo "Removed ${login}."
  done
}

people_mysql() {
  local container="$1" databases=() existing=() database login i privileges

  if [[ "${MODE}" == "service" ]]; then
    databases=("${SERVICE_DATABASE}")
  else
    # A service's database has a user of the same name (core's convention).
    while IFS= read -r database; do
      [[ -z "${database}" ]] && continue
      [[ "${database}" =~ ${IDENTIFIER_PATTERN} ]] && databases+=("${database}")
    done < <(mysql_query "${container}" \
      "SELECT s.SCHEMA_NAME FROM information_schema.SCHEMATA s WHERE s.SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys') AND EXISTS (SELECT 1 FROM mysql.user u WHERE u.User = s.SCHEMA_NAME) ORDER BY 1")
  fi

  # This scope's people logins now: candidates by an exact prefix (not LIKE, where
  # "_" is a wildcard), then the exact pattern.
  while IFS= read -r login; do
    [[ "${login}" =~ ${LOGIN_OF_SCOPE} ]] && existing+=("${login}")
  done < <(mysql_query "${container}" "SELECT User FROM mysql.user WHERE Host = '%' AND LEFT(User, $(( ${#SCOPE} + 1 ))) = '${SCOPE}.' ORDER BY 1")

  echo "MySQL: ${#databases[@]} database(s) for ${SCOPE}."

  {
    for login in "${existing[@]}"; do
      is_listed "${login}" || echo "DROP USER '${login}'@'%';"
    done

    for i in "${!PEOPLE_NAMES[@]}"; do
      login="${SCOPE}.${PEOPLE_NAMES[$i]}"
      echo "CREATE USER IF NOT EXISTS '${login}'@'%' IDENTIFIED BY '${PEOPLE_PASSWORDS[$i]}';"
      echo "ALTER USER '${login}'@'%' IDENTIFIED BY '${PEOPLE_PASSWORDS[$i]}';"
      # From nothing each time, so a change from write to read leaves no grant behind.
      echo "REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${login}'@'%';"

      if [[ "${PEOPLE_ACCESS[$i]}" == "write" ]]; then privileges="SELECT, INSERT, UPDATE, DELETE"
      else privileges="SELECT"; fi

      for database in "${databases[@]}"; do
        # "_" is a wildcard in a database-level grant: escaped, as for services.
        echo "GRANT ${privileges} ON \`${database//_/\\_}\`.* TO '${login}'@'%';"
      done
    done
  } | docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "${container}" mysql -uroot

  for login in "${existing[@]}"; do
    is_listed "${login}" || echo "Removed ${login}."
  done
}

people_mongodb() {
  local container="$1" people i

  # Rebuilt from the checked values, keyed by full login, not passed through.
  people="$(
    for i in "${!PEOPLE_NAMES[@]}"; do
      printf '%s\t%s\t%s\n' "${SCOPE}.${PEOPLE_NAMES[$i]}" "${PEOPLE_PASSWORDS[$i]}" "${PEOPLE_ACCESS[$i]}"
    done | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): {password: .[1], access: .[2]}}) | add // {}'
  )"

  {
    echo "db.getSiblingDB('admin').auth('admin', process.env.MONGO_ROOT_PWD);"
    echo "const people = ${people};"
    echo "const mine = new RegExp($(jq -Rn --arg p "${LOGIN_OF_SCOPE}" '$p'));"
    # null: every database (the platform); otherwise the service's own.
    if [[ "${MODE}" == "service" ]]; then echo "const database = \"${SERVICE_DATABASE}\";"
    else echo "const database = null;"; fi
    cat <<'JS'
const admin = db.getSiblingDB("admin");
const existing = admin.runCommand({ usersInfo: 1 }).users.map((u) => u.user);

for (const login of existing) {
  if (mine.test(login) && !(login in people)) {
    admin.dropUser(login);
    print("Removed " + login + ".");
  }
}

for (const [login, entry] of Object.entries(people)) {
  const writes = entry.access === "write";
  const roles = database === null
    ? [{ role: writes ? "readWriteAnyDatabase" : "readAnyDatabase", db: "admin" }]
    : [{ role: writes ? "readWrite" : "read", db: database }];
  if (existing.includes(login)) {
    admin.updateUser(login, { pwd: entry.password, roles: roles });
  } else {
    admin.createUser({ user: login, pwd: entry.password, roles: roles });
    print("Created " + login + ".");
  }
}
JS
  } | docker exec -i -e MONGO_ROOT_PWD="${DB_ROOT_PASSWORD}" "${container}" mongosh --quiet
}

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

done_any=false

for engine in "${ENGINES[@]}"; do
  container="$(container_for "${engine}")"

  if [[ -z "${container}" ]]; then
    if [[ -n "${REQUESTED}" ]]; then
      echo "ERROR: no running container for ${engine} (Compose project db-${engine})." >&2
      exit 1
    fi
    continue
  fi

  echo "Provisioning ${SCOPE} logins on ${engine} (${container})."
  "people_${engine}" "${container}"
  done_any=true
done

if [[ "${done_any}" != "true" ]]; then
  echo "No engine is running on this host; nothing to do."
fi

DB_ROOT_PASSWORD=""
PEOPLE_PASSWORDS=()

echo "${SCOPE} logins provisioned."
