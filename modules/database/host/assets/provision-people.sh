#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PROVISION THE TEAM'S LOGINS
#
# What the <project>-database-provision-people SSM document runs, and what
# provision-service.sh runs after every service it provisions. Makes each
# engine's agent_<name> logins match core's people secret exactly:
#
#   <project>-database-people-<environment>-secret-vault
#     { "agent_<name>": { "password": "...", "access": "read" | "write" } }
#
# A listed person gets a login with their password, and on EVERY service's
# database "read" (look at and query data) or "write" (also add, change and
# delete rows). Neither can change tables: that is the services' migrations'
# job. An agent_ login no longer listed is removed. The staging and production
# functions do the same on the managed databases (modules/database/provisioning).
#
#   PostgreSQL  two groups, agent_group_read and agent_group_write, granted on
#               each service's database with default privileges, so tables a
#               service creates later are covered too.
#   MySQL       grants on each service's database, given to each person; a
#               database-level grant already covers tables created later.
#   MongoDB     readAnyDatabase or readWriteAnyDatabase, on admin.
#
# A service's database is one owned by (PostgreSQL) or named like (MySQL) a user
# of its own name: core provisions every service that way.
#
# SAFE TO RUN AGAIN. Every step is conditional or idempotent; the passwords are
# set every time.
#
# Usage: provision-people.sh [postgres|mysql|mongodb]
#   With an engine, that engine must be running. Without one, every running
#   engine is done.
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

ENGINES=(postgres mysql mongodb)
REQUESTED="${1:-}"

if [[ $# -gt 1 ]]; then
  echo "ERROR: Usage: ${0} [postgres|mysql|mongodb]" >&2
  exit 1
fi

if [[ -n "${REQUESTED}" ]]; then
  case "${REQUESTED}" in
    postgres|mysql|mongodb) ENGINES=("${REQUESTED}") ;;
    *)
      echo "ERROR: '${REQUESTED}' is not an engine this script provisions people on (postgres, mysql, mongodb)." >&2
      exit 1
      ;;
  esac
fi

# The same patterns the functions use. Everything below is interpolated into SQL
# or JavaScript run as the administrator, so nothing reaches it unchecked.
PERSON_PATTERN='^agent_[a-z][a-z0-9]{1,19}$'
PASSWORD_PATTERN='^[A-Za-z0-9._-]+$'
IDENTIFIER_PATTERN='^[A-Za-z_][A-Za-z0-9_]*$'

# ------------------------------------------------------------------------------
# The people secret
# ------------------------------------------------------------------------------

PEOPLE_SECRET_ID="${PEOPLE_SECRET_ID:-${PROJECT_NAME}-database-people-${ENVIRONMENT}-secret-vault}"

echo "Reading the people secret ${PEOPLE_SECRET_ID}."

if ! PEOPLE_JSON="$(
  aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${PEOPLE_SECRET_ID}" \
    --query 'SecretString' \
    --output text
)"; then
  echo "ERROR: could not read the people secret ${PEOPLE_SECRET_ID}. Core creates it with the people list; has core been applied?" >&2
  exit 1
fi

if ! jq -e 'type == "object"' <<< "${PEOPLE_JSON}" >/dev/null 2>&1; then
  echo "ERROR: the people secret is not a JSON object." >&2
  exit 1
fi

PEOPLE_USERS=()
PEOPLE_ACCESS=()
PEOPLE_PASSWORDS=()

while IFS=$'\t' read -r user access password; do
  [[ -z "${user}" ]] && continue

  if ! [[ "${user}" =~ ${PERSON_PATTERN} ]]; then
    echo "ERROR: '${user}' in the people secret is not agent_<name>." >&2
    exit 1
  fi
  if [[ "${access}" != "read" && "${access}" != "write" ]]; then
    echo "ERROR: ${user} in the people secret has no access level of read or write." >&2
    exit 1
  fi
  if ! [[ "${password}" =~ ${PASSWORD_PATTERN} ]]; then
    echo "ERROR: ${user}'s password is outside core's alphabet (letters, digits and -_.)." >&2
    exit 1
  fi

  PEOPLE_USERS+=("${user}")
  PEOPLE_ACCESS+=("${access}")
  PEOPLE_PASSWORDS+=("${password}")
done < <(jq -r 'to_entries | sort_by(.key)[] | [.key, (.value.access // ""), (.value.password // "")] | @tsv' <<< "${PEOPLE_JSON}")

PEOPLE_JSON=""

echo "The people list has ${#PEOPLE_USERS[@]} person(s)."

is_listed() {
  local candidate="$1" user
  for user in "${PEOPLE_USERS[@]}"; do
    [[ "${user}" == "${candidate}" ]] && return 0
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
  local container="$1" databases=() database user i member other listed=""

  while IFS= read -r database; do
    [[ -z "${database}" ]] && continue
    [[ "${database}" =~ ${IDENTIFIER_PATTERN} ]] && databases+=("${database}")
  done < <(psql_query "${container}" postgres \
    "SELECT d.datname FROM pg_database d JOIN pg_roles r ON r.oid = d.datdba WHERE r.rolname = d.datname AND NOT d.datistemplate AND d.datname <> 'postgres' ORDER BY 1")

  echo "PostgreSQL: ${#databases[@]} service database(s)."

  for user in "${PEOPLE_USERS[@]}"; do
    listed+="${listed:+,}'${user}'"
  done

  {
    echo '\set ON_ERROR_STOP on'

    for group in agent_group_read agent_group_write; do
      echo "SELECT 'CREATE ROLE ${group} NOLOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${group}')"
      echo '\gexec'
    done

    for database in "${databases[@]}"; do
      echo "GRANT CONNECT ON DATABASE \"${database}\" TO agent_group_read, agent_group_write;"
    done

    for i in "${!PEOPLE_USERS[@]}"; do
      user="${PEOPLE_USERS[$i]}"
      if [[ "${PEOPLE_ACCESS[$i]}" == "write" ]]; then member=agent_group_write other=agent_group_read
      else member=agent_group_read other=agent_group_write; fi

      echo "SELECT 'CREATE ROLE ${user} LOGIN' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${user}')"
      echo '\gexec'
      echo "ALTER ROLE \"${user}\" WITH LOGIN PASSWORD '${PEOPLE_PASSWORDS[$i]}';"
      echo "GRANT ${member} TO \"${user}\";"
      echo "REVOKE ${other} FROM \"${user}\";"
    done

    # Anyone agent_<name> no longer listed.
    echo "SELECT format('DROP ROLE %I', rolname) FROM pg_roles WHERE rolname ~ '${PERSON_PATTERN}' AND rolname <> ALL (ARRAY[${listed}]::text[])"
    echo '\gexec'

    for database in "${databases[@]}"; do
      echo "\\connect ${database}"
      echo "GRANT USAGE ON SCHEMA public TO agent_group_read, agent_group_write;"
      echo "GRANT SELECT ON ALL TABLES IN SCHEMA public TO agent_group_read;"
      echo "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO agent_group_read;"
      echo "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO agent_group_write;"
      echo "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO agent_group_write;"
      # Tables and sequences the service creates later, through its migrations.
      echo "ALTER DEFAULT PRIVILEGES FOR ROLE \"${database}\" IN SCHEMA public GRANT SELECT ON TABLES TO agent_group_read;"
      echo "ALTER DEFAULT PRIVILEGES FOR ROLE \"${database}\" IN SCHEMA public GRANT SELECT ON SEQUENCES TO agent_group_read;"
      echo "ALTER DEFAULT PRIVILEGES FOR ROLE \"${database}\" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO agent_group_write;"
      echo "ALTER DEFAULT PRIVILEGES FOR ROLE \"${database}\" IN SCHEMA public GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO agent_group_write;"
    done
  } | docker exec -i "${container}" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1
}

people_mysql() {
  local container="$1" databases=() existing=() database user i privileges

  while IFS= read -r database; do
    [[ -z "${database}" ]] && continue
    [[ "${database}" =~ ${IDENTIFIER_PATTERN} && ! "${database}" =~ ${PERSON_PATTERN} ]] && databases+=("${database}")
  done < <(mysql_query "${container}" \
    "SELECT s.SCHEMA_NAME FROM information_schema.SCHEMATA s WHERE s.SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys') AND EXISTS (SELECT 1 FROM mysql.user u WHERE u.User = s.SCHEMA_NAME) ORDER BY 1")

  while IFS= read -r user; do
    [[ "${user}" =~ ${PERSON_PATTERN} ]] && existing+=("${user}")
  done < <(mysql_query "${container}" "SELECT User FROM mysql.user WHERE Host = '%' AND User LIKE 'agent\\_%' ORDER BY 1")

  echo "MySQL: ${#databases[@]} service database(s)."

  {
    for user in "${existing[@]}"; do
      if ! is_listed "${user}"; then
        echo "DROP USER '${user}'@'%';"
      fi
    done

    for i in "${!PEOPLE_USERS[@]}"; do
      user="${PEOPLE_USERS[$i]}"
      echo "CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${PEOPLE_PASSWORDS[$i]}';"
      echo "ALTER USER '${user}'@'%' IDENTIFIED BY '${PEOPLE_PASSWORDS[$i]}';"
      # From nothing each time, so a change from write to read leaves no grant behind.
      echo "REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${user}'@'%';"

      if [[ "${PEOPLE_ACCESS[$i]}" == "write" ]]; then privileges="SELECT, INSERT, UPDATE, DELETE"
      else privileges="SELECT"; fi

      for database in "${databases[@]}"; do
        # "_" is a wildcard in a database-level grant: escaped, as for services.
        echo "GRANT ${privileges} ON \`${database//_/\\_}\`.* TO '${user}'@'%';"
      done
    done
  } | docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "${container}" mysql -uroot

  for user in "${existing[@]}"; do
    is_listed "${user}" || echo "Removed ${user}."
  done
}

people_mongodb() {
  local container="$1" people i

  # Rebuilt from the checked values, not passed through from the secret.
  people="$(
    for i in "${!PEOPLE_USERS[@]}"; do
      printf '%s\t%s\t%s\n' "${PEOPLE_USERS[$i]}" "${PEOPLE_PASSWORDS[$i]}" "${PEOPLE_ACCESS[$i]}"
    done | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): {password: .[1], access: .[2]}}) | add // {}'
  )"

  {
    echo "db.getSiblingDB('admin').auth('admin', process.env.MONGO_ROOT_PWD);"
    echo "const people = ${people};"
    cat <<'JS'
const admin = db.getSiblingDB("admin");
const person = /^agent_[a-z][a-z0-9]{1,19}$/;
const existing = admin.runCommand({ usersInfo: 1 }).users.map((u) => u.user);

for (const user of existing) {
  if (person.test(user) && !(user in people)) {
    admin.dropUser(user);
    print("Removed " + user + ".");
  }
}

for (const [user, entry] of Object.entries(people)) {
  const roles = [{ role: entry.access === "write" ? "readWriteAnyDatabase" : "readAnyDatabase", db: "admin" }];
  if (existing.includes(user)) {
    admin.updateUser(user, { pwd: entry.password, roles: roles });
  } else {
    admin.createUser({ user: user, pwd: entry.password, roles: roles });
    print("Created " + user + ".");
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

  echo "Provisioning people on ${engine} (${container})."
  "people_${engine}" "${container}"
  done_any=true
done

if [[ "${done_any}" != "true" ]]; then
  echo "No engine is running on this host; nothing to do."
fi

DB_ROOT_PASSWORD=""
PEOPLE_PASSWORDS=()

echo "People provisioned."
