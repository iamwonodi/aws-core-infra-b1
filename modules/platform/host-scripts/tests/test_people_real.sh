#!/usr/bin/env bash
# provision-people.sh against REAL PostgreSQL and MySQL servers, at both scopes:
#   platform.<name>   core's platform list, every service's database
#   <service>.<name>  a service's agents, that service's database only
#
# On the database host the engines run in containers and the script reaches them
# with `docker exec`; here tests/real-bin/docker runs the same psql and mysql
# commands locally against test servers. Every check connects AS the person and
# tries: read, write, create a table, reach another service, sign in after removal.
#
# Two services are named so that one's name, read as a LIKE pattern, matches the
# other's (ha_c and haxc differ only where "_" is a wildcard).
#
# Skipped unless the servers are given (the same variables as the provisioning
# function's real tests; the MySQL root account must accept that password):
#   PROVISION_TEST_PG_HOST, PROVISION_TEST_PG_SUPERUSER=postgres, PROVISION_TEST_PG_SUPERPASSWORD
#   PROVISION_TEST_MYSQL_HOST, PROVISION_TEST_MYSQL_ROOT_USER=root, PROVISION_TEST_MYSQL_ROOT_PASSWORD
set -uo pipefail

if [[ -z "${PROVISION_TEST_PG_HOST:-}" || -z "${PROVISION_TEST_MYSQL_HOST:-}" ]]; then
  echo "  skip real-server people tests (set PROVISION_TEST_PG_HOST and PROVISION_TEST_MYSQL_HOST)"
  exit 0
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$(cd "$TESTS_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
export PATH="${TESTS_DIR}/real-bin:${PATH}"
export REAL_SECRETS="$WORK/secrets" REAL_ENGINES="postgres mysql"
mkdir -p "$REAL_SECRETS"

pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }; bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
refused(){ local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }

S="$(tr -dc a-z0-9 </dev/urandom | head -c 6)"
ONE="h_one_${S}" TWO="h_two_${S}" LIKE="ha_c${S}" LOOK="haxc${S}"
PW_ADA="Ada-pw.0123456789" PW_TUNDE="Tunde-pw.0123456789" PW_BOB="Bob-pw.0123456789"
ROOT_PW="${PROVISION_TEST_MYSQL_ROOT_PASSWORD}"

WS="$WORK/ws"; mkdir -p "$WS"
cp "$MODULES/database/host/assets/provision-people.sh" "$WS/"
cat > "$WS/.env" <<E
PROJECT_NAME=core
ENVIRONMENT=development
AWS_REGION=af-south-1
CORE_ROOT_SECRET_ARN=arn_core
E
# One administrator password for both engines, as on the host (one root secret).
printf '{"username":"admin","root_password":"%s"}' "$ROOT_PW" > "$REAL_SECRETS/arn_core"

entries(){ # "name:access:password"... -> { name: {access, password} }
  local json="{}" entry
  for entry in "$@"; do
    IFS=: read -r n a p <<< "$entry"
    json="$(jq -c --arg n "$n" --arg a "$a" --arg p "$p" '. + {($n): {access: $a, password: $p}}' <<< "$json")"
  done
  printf '%s' "$json"
}
platform(){ entries "$@" | jq -c 'with_entries(.key |= "platform." + .)' > "$REAL_SECRETS/core-database-people-development-secret-vault"; }
agents(){ # <service> <engine> entries...: the service's secret and request, then run
  local service="$1" engine="$2"; shift 2
  jq -n --arg s "$service" --arg a "$(entries "$@")" '{db_name: $s, db_user: $s, db_password: "Svc-pw.x", agents: $a}' > "$REAL_SECRETS/arn_$service"
  jq -n --arg s "$service" --arg e "$engine" '{service_name: $s, database_engine: $e, database_secrets_arn: ("arn_" + $s), secret_mappings: {db_key: "db_name", user_key: "db_user", pass_key: "db_password"}}' > "$WORK/request-$service.json"
  bash "$WS/provision-people.sh" service "$WORK/request-$service.json" > "$WORK/out.txt" 2>&1
}
run_platform(){ bash "$WS/provision-people.sh" platform "$@" > "$WORK/out.txt" 2>&1; }

sup(){ PGPASSWORD="$PROVISION_TEST_PG_SUPERPASSWORD" psql -h "$PROVISION_TEST_PG_HOST" -U "$PROVISION_TEST_PG_SUPERUSER" -d postgres -v ON_ERROR_STOP=1 -qtA "$@"; }
pg_as(){ PGPASSWORD="$2" psql -h "$PROVISION_TEST_PG_HOST" -U "$1" -d "$3" -v ON_ERROR_STOP=1 -qtA -c "$4"; }
root(){ MYSQL_PWD="$ROOT_PW" mysql -h "$PROVISION_TEST_MYSQL_HOST" -u"$PROVISION_TEST_MYSQL_ROOT_USER" -N -e "$1"; }
my_as(){ MYSQL_PWD="$2" mysql -h "$PROVISION_TEST_MYSQL_HOST" -u"$1" -D "$3" -N -e "$4"; }

cleanup(){
  for d in "$ONE" "$TWO" "$LIKE" "$LOOK"; do sup -c "DROP DATABASE IF EXISTS \"$d\" WITH (FORCE)" >/dev/null 2>&1; done
  sup -c "SELECT rolname FROM pg_roles WHERE rolname LIKE 'platform.%' OR rolname LIKE '%${S}.%'" 2>/dev/null | while read -r r; do sup -c "DROP ROLE IF EXISTS \"$r\"" >/dev/null 2>&1; done
  for d in "$ONE" "$TWO" "$LIKE" "$LOOK"; do sup -c "DROP ROLE IF EXISTS \"$d\"" >/dev/null 2>&1; root "DROP DATABASE IF EXISTS \`$d\`; DROP USER IF EXISTS '$d'@'%';" >/dev/null 2>&1; done
  root "SELECT User FROM mysql.user WHERE User LIKE 'platform.%' OR User LIKE '%${S}.%'" 2>/dev/null | while read -r u; do root "DROP USER IF EXISTS '$u'@'%';" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Four services on each engine, as core provisions them (database owned by / named
# like a user of its own name); ONE has a table with a row.
for d in "$ONE" "$TWO" "$LIKE" "$LOOK"; do
  sup -c "CREATE ROLE \"$d\" LOGIN PASSWORD 'Svc-pw.x'" -c "CREATE DATABASE \"$d\" OWNER \"$d\"" -c "REVOKE ALL ON DATABASE \"$d\" FROM PUBLIC"
  root "CREATE DATABASE \`$d\`; CREATE USER '$d'@'%' IDENTIFIED BY 'Svc-pw.x'; GRANT ALL ON \`${d//_/\\_}\`.* TO '$d'@'%';"
done
pg_as "$ONE" Svc-pw.x "$ONE" "CREATE TABLE before_people (id serial PRIMARY KEY, v text); INSERT INTO before_people (v) VALUES ('seed')"
my_as "$ONE" Svc-pw.x "$ONE" "CREATE TABLE before_people (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(20)); INSERT INTO before_people (v) VALUES ('seed')"

for engine in postgres mysql; do
  if [[ $engine == postgres ]]; then as=pg_as E=PostgreSQL; else as=my_as E=MySQL; fi

  echo "== $E: a service's agents"
  agents "$ONE" $engine "ada:write:$PW_ADA" "bob:read:$PW_BOB"; rc=$?
  check   "$E: succeeds"                                  test $rc -eq 0
  [[ $rc -eq 0 ]] || cat "$WORK/out.txt"
  agents "$TWO" $engine "ada:read:$PW_ADA"
  check   "$E: write on its own service"                  $as "$ONE.ada" "$PW_ADA" "$ONE" "INSERT INTO before_people (v) VALUES ('a'); DELETE FROM before_people WHERE v = 'a'"
  check   "$E: read on its own service"                   $as "$ONE.bob" "$PW_BOB" "$ONE" "SELECT v FROM before_people"
  refused "$E: read cannot write"                         $as "$ONE.bob" "$PW_BOB" "$ONE" "INSERT INTO before_people (id, v) VALUES (1000, 'x')"
  refused "$E: never another service's database"          $as "$ONE.ada" "$PW_ADA" "$TWO" "SELECT 1"
  refused "$E: agents create no tables"                   $as "$ONE.ada" "$PW_ADA" "$ONE" "CREATE TABLE mine (v INT)"

  echo "== $E: the platform's people"
  platform "ada:write:$PW_ADA" "tunde:read:$PW_TUNDE"
  run_platform $engine; rc=$?
  check   "$E: succeeds"                                  test $rc -eq 0
  check   "$E: platform reads every service"              $as "platform.tunde" "$PW_TUNDE" "$TWO" "SELECT 1"
  check   "$E: platform write writes"                     $as "platform.ada" "$PW_ADA" "$ONE" "INSERT INTO before_people (v) VALUES ('p'); DELETE FROM before_people WHERE v = 'p'"
  refused "$E: platform read cannot write"                $as "platform.tunde" "$PW_TUNDE" "$ONE" "DELETE FROM before_people"

  echo "== $E: removing, scope by scope"
  agents "$ONE" $engine "ada:read:$PW_ADA"
  refused "$E: write -> read stops writing"               $as "$ONE.ada" "$PW_ADA" "$ONE" "INSERT INTO before_people (id, v) VALUES (1001, 'x')"
  refused "$E: a removed agent cannot sign in"            $as "$ONE.bob" "$PW_BOB" "$ONE" "SELECT 1"
  check   "$E: another service's agent stays"             $as "$TWO.ada" "$PW_ADA" "$TWO" "SELECT 1"
  check   "$E: the platform's people stay"                $as "platform.ada" "$PW_ADA" "$ONE" "SELECT 1"
  platform "ada:write:$PW_ADA"; run_platform $engine
  refused "$E: a removed platform person cannot sign in"  $as "platform.tunde" "$PW_TUNDE" "$ONE" "SELECT 1"
  check   "$E: agents untouched by the platform list"     $as "$ONE.ada" "$PW_ADA" "$ONE" "SELECT 1"

  echo "== $E: the wildcard trap"
  agents "$LOOK" $engine "ada:read:$PW_ADA"
  agents "$LIKE" $engine "ada:read:$PW_ADA"
  refused "$E: ${LIKE}.ada never reaches ${LOOK}"         $as "$LIKE.ada" "$PW_ADA" "$LOOK" "SELECT 1"
  agents "$LIKE" $engine
  refused "$E: ${LIKE}'s agent is removed"                $as "$LIKE.ada" "$PW_ADA" "$LIKE" "SELECT 1"
  check   "$E: ${LOOK}'s agent survives"                  $as "$LOOK.ada" "$PW_ADA" "$LOOK" "SELECT 1"

  echo "== $E: later tables"
  if [[ $engine == postgres ]]; then pg_as "$TWO" Svc-pw.x "$TWO" "CREATE TABLE IF NOT EXISTS after_people (id serial PRIMARY KEY, v text)"
  else my_as "$TWO" Svc-pw.x "$TWO" "CREATE TABLE IF NOT EXISTS after_people (v INT)"; fi
  check   "$E: an agent reads a table created later"      $as "$TWO.ada" "$PW_ADA" "$TWO" "SELECT * FROM after_people"
  check   "$E: the platform too"                          $as "platform.ada" "$PW_ADA" "$TWO" "SELECT * FROM after_people"
done

echo "== refusals"
agents "$ONE" postgres "abcdefghijklmnopqrst:read:$PW_ADA"; rc=$?
check "a login longer than 32 characters is refused" bash -c "[[ $rc -ne 0 ]] && grep -q '32' '$WORK/out.txt'"
REAL_ENGINES="mysql" run_platform postgres; rc=$?
check "an engine asked for but not running fails"    test $rc -ne 0

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
