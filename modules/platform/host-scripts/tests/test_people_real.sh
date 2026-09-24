#!/usr/bin/env bash
# provision-people.sh against REAL PostgreSQL and MySQL servers.
#
# On the database host the engines run in containers and the script reaches them
# with `docker exec`; here tests/real-bin/docker runs the same psql and mysql
# commands locally against test servers. Every check connects AS the person and
# tries: read, write, create a table, sign in after removal.
#
# Skipped unless the servers are given (the same variables as the provisioning
# function's real tests; the MySQL root account must accept the password below):
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
ADA="agent_ada${S}" TUNDE="agent_tunde${S}" GONE="agent_gone${S}"
PW_ADA="Ada-pw.0123456789" PW_TUNDE="Tunde-pw.0123456789"
SVC="ph_one_${S}" SVC2="ph_two_${S}" LOOK="phxone_${S}"
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

people(){ # writes the people secret from "user:access:password" arguments
  local json="{}" entry
  for entry in "$@"; do
    IFS=: read -r u a p <<< "$entry"
    json="$(jq -c --arg u "$u" --arg a "$a" --arg p "$p" '. + {($u): {access: $a, password: $p}}' <<< "$json")"
  done
  printf '%s' "$json" > "$REAL_SECRETS/core-database-people-development-secret-vault"
}
run(){ bash "$WS/provision-people.sh" "$@" > "$WORK/out.txt" 2>&1; }

sup(){ PGPASSWORD="$PROVISION_TEST_PG_SUPERPASSWORD" psql -h "$PROVISION_TEST_PG_HOST" -U "$PROVISION_TEST_PG_SUPERUSER" -v ON_ERROR_STOP=1 -qtA "$@"; }
pg_as(){ PGPASSWORD="$2" psql -h "$PROVISION_TEST_PG_HOST" -U "$1" -d "$3" -v ON_ERROR_STOP=1 -qtA -c "$4"; }
root(){ MYSQL_PWD="$ROOT_PW" mysql -h "$PROVISION_TEST_MYSQL_HOST" -u"$PROVISION_TEST_MYSQL_ROOT_USER" -N -e "$1"; }
my_as(){ MYSQL_PWD="$2" mysql -h "$PROVISION_TEST_MYSQL_HOST" -u"$1" -D "$3" -N -e "$4"; }

cleanup(){
  for d in "$SVC" "$SVC2"; do sup -d postgres -c "DROP DATABASE IF EXISTS \"$d\" WITH (FORCE)" >/dev/null 2>&1; done
  for r in "$ADA" "$TUNDE" "$GONE" "$SVC" "$SVC2" agent_group_read agent_group_write; do sup -d postgres -c "DROP ROLE IF EXISTS \"$r\"" >/dev/null 2>&1; done
  for d in "$SVC" "$SVC2" "$LOOK"; do root "DROP DATABASE IF EXISTS \`$d\`; DROP USER IF EXISTS '$d'@'%';" >/dev/null 2>&1; done
  for u in "$ADA" "$TUNDE" "$GONE"; do root "DROP USER IF EXISTS '$u'@'%';" >/dev/null 2>&1; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# Two services on each engine, as core provisions them (database owned by / named
# like a user of its own name), one with a table and a row. A person who has since
# left, and a MySQL database that only looks like a service's.
for d in "$SVC" "$SVC2"; do
  sup -d postgres -c "CREATE ROLE \"$d\" LOGIN PASSWORD 'Svc-pw.x'" -c "CREATE DATABASE \"$d\" OWNER \"$d\"" -c "REVOKE ALL ON DATABASE \"$d\" FROM PUBLIC"
  root "CREATE DATABASE \`$d\`; CREATE USER '$d'@'%' IDENTIFIED BY 'Svc-pw.x'; GRANT ALL ON \`${d//_/\\_}\`.* TO '$d'@'%';"
done
pg_as "$SVC" Svc-pw.x "$SVC" "CREATE TABLE before_people (id serial PRIMARY KEY, v text); INSERT INTO before_people (v) VALUES ('seed')"
my_as "$SVC" Svc-pw.x "$SVC" "CREATE TABLE before_people (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(20)); INSERT INTO before_people (v) VALUES ('seed')"
sup -d postgres -c "CREATE ROLE \"$GONE\" LOGIN PASSWORD 'Gone-pw.1'"
root "CREATE USER '$GONE'@'%' IDENTIFIED BY 'Gone-pw.1'; CREATE DATABASE \`$LOOK\`; CREATE TABLE \`$LOOK\`.t (v INT);"

echo "== provisioning people on every running engine"
people "$ADA:write:$PW_ADA" "$TUNDE:read:$PW_TUNDE"
run; rc=$?
check "succeeds"                                   test $rc -eq 0
[[ $rc -eq 0 ]] || cat "$WORK/out.txt"

for engine in pg my; do
  if [[ $engine == pg ]]; then as=pg_as; E=PostgreSQL; else as=my_as; E=MySQL; fi
  check    "$E: read can read"                         $as "$TUNDE" "$PW_TUNDE" "$SVC" "SELECT v FROM before_people"
  refused  "$E: read cannot insert"                    $as "$TUNDE" "$PW_TUNDE" "$SVC" "INSERT INTO before_people (id, v) VALUES (1000, 'x')"
  refused  "$E: read cannot delete"                    $as "$TUNDE" "$PW_TUNDE" "$SVC" "DELETE FROM before_people"
  check    "$E: write can insert and delete"           $as "$ADA" "$PW_ADA" "$SVC" "INSERT INTO before_people (v) VALUES ('ada'); DELETE FROM before_people WHERE v = 'ada'"
  refused  "$E: write cannot create a table"           $as "$ADA" "$PW_ADA" "$SVC" "CREATE TABLE mine (v INT)"
  check    "$E: every service's database"              $as "$TUNDE" "$PW_TUNDE" "$SVC2" "SELECT 1"
  refused  "$E: the person who left is removed"        $as "$GONE" "Gone-pw.1" "$SVC" "SELECT 1"
done

pg_as "$SVC2" Svc-pw.x "$SVC2" "CREATE TABLE after_people (id serial PRIMARY KEY, v text)"
my_as "$SVC2" Svc-pw.x "$SVC2" "CREATE TABLE after_people (v INT)"
check   "PostgreSQL: a table created later is readable"   pg_as "$TUNDE" "$PW_TUNDE" "$SVC2" "SELECT * FROM after_people"
check   "PostgreSQL: and writable, sequence included"     pg_as "$ADA" "$PW_ADA" "$SVC2" "INSERT INTO after_people (v) VALUES ('x')"
check   "MySQL: a table created later is readable"        my_as "$TUNDE" "$PW_TUNDE" "$SVC2" "SELECT * FROM after_people"
refused "MySQL: a lookalike database is not reached"      my_as "$ADA" "$PW_ADA" "$LOOK" "SELECT * FROM t"
check   "the service keeps full control"                  pg_as "$SVC" Svc-pw.x "$SVC" "CREATE TABLE svc_still_owns (v INT)"

echo "== changing access and removing someone"
people "$ADA:read:$PW_ADA"
run; rc=$?
check   "succeeds"                                        test $rc -eq 0
refused "PostgreSQL: write -> read stops writing"         pg_as "$ADA" "$PW_ADA" "$SVC" "INSERT INTO before_people (id, v) VALUES (1001, 'x')"
refused "MySQL: write -> read stops writing"              my_as "$ADA" "$PW_ADA" "$SVC" "INSERT INTO before_people (id, v) VALUES (1001, 'x')"
refused "PostgreSQL: a removed person cannot sign in"     pg_as "$TUNDE" "$PW_TUNDE" "$SVC" "SELECT 1"
refused "MySQL: a removed person cannot sign in"          my_as "$TUNDE" "$PW_TUNDE" "$SVC" "SELECT 1"

echo "== running again"
run; rc=$?
check "running again succeeds"                            test $rc -eq 0
check "and changes nothing"                               pg_as "$ADA" "$PW_ADA" "$SVC" "SELECT 1 FROM before_people"

echo "== one engine only"
REAL_ENGINES="mysql" bash "$WS/provision-people.sh" postgres > "$WORK/out.txt" 2>&1; rc=$?
check "an engine asked for but not running fails"         test $rc -ne 0

echo "== nobody listed"
people
run; rc=$?
check   "succeeds"                                        test $rc -eq 0
refused "PostgreSQL: everyone is removed"                 pg_as "$ADA" "$PW_ADA" "$SVC" "SELECT 1"
refused "MySQL: everyone is removed"                      my_as "$ADA" "$PW_ADA" "$SVC" "SELECT 1"
check   "the services are untouched"                      my_as "$SVC" Svc-pw.x "$SVC" "SELECT 1"

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
