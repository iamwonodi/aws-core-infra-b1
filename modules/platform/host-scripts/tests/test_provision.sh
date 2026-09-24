#!/usr/bin/env bash
# provision-service.sh and provision.sh, against stubbed aws and docker.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$(cd "$TESTS_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export PATH="${TESTS_DIR}/bin:${PATH}"
export FAKE_ROOT="$WORK/root"
A="$MODULES/database/host/assets"
WS="$WORK/dbws"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }; bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }

SECRET_ARN='arn:aws:secretsmanager:af-south-1:123456789012:secret:core-auth-development-secret-vault-AbC123'

setup(){
  rm -rf "$FAKE_ROOT" "$WS"
  mkdir -p "$FAKE_ROOT"/{secrets,s3/b,compose-state} "$WS"
  : > "$FAKE_ROOT/calls.log"
  cp "$A/provision.sh" "$A/provision-service.sh" "$A/provision-people.sh" "$WS/"
  # The platform scripts are installed flat in the workspace, as the fetch does.
  cp "$A"/provisioning/* "$WS/"
  cat > "$WS/.env" <<E
PROJECT_NAME=core
ENVIRONMENT=development
DATABASE_WORKSPACE=$WS
AWS_REGION=af-south-1
DEPLOY_BUCKET_NAME=b
CORE_ROOT_SECRET_ARN=arn_core
E
  printf '%s' '{"username":"admin","root_password":"R00t-pw.1"}' > "$FAKE_ROOT/secrets/arn_core"
  # Core's people list: provision-service.sh brings it up to date afterwards.
  printf '%s' '{"agent_ada":{"password":"Ada-pw.0123","access":"read"}}' > "$FAKE_ROOT/secrets/core-database-people-development-secret-vault"
  printf '%s' '{"db_name":"auth","db_user":"auth","db_password":"s3cret-pw.x"}' \
    > "$FAKE_ROOT/secrets/$(printf '%s' "$SECRET_ARN" | tr '/:' '__')"
  # An engine is running, as its own Compose project.
  echo running > "$FAKE_ROOT/compose-state/db-postgres"
}
request(){ # <service> <engine> [secret-arn]
  mkdir -p "$FAKE_ROOT/s3/b/provisioning/$1"
  printf '{"service_name":"%s","database_engine":"%s","database_secrets_arn":"%s","secret_mappings":{"db_key":"db_name","user_key":"db_user","pass_key":"db_password"}}' \
    "$1" "$2" "${3:-$SECRET_ARN}" > "$FAKE_ROOT/s3/b/provisioning/$1/config.json"
}
extra(){ printf '%s' "$2" > "$FAKE_ROOT/s3/b/provisioning/$1/extra.sql"; }
run(){ bash "$WS/provision-service.sh" "$@" < /dev/null; }
execs(){ ls "$FAKE_ROOT/exec"/*.json 2>/dev/null | wc -l | tr -d ' '; }
execn(){ cat "$FAKE_ROOT/exec/$(printf '%03d' "$1").json"; }
export -f execn
# The subshells below need FAKE_ROOT too.
export FAKE_ROOT

echo "== provisioning a service"
setup; request auth postgres
run auth > "$WORK/out.txt" 2>&1; rc=$?
check "succeeds"                                          test $rc -eq 0
check "the standard script, then the people step's query and script" test "$(execs)" = 3
people_step_on(){ execn "$1" | jq -r .stdin | grep -q agent_group_read && execn "$1" | jq -r '.args | join(" ")' | grep -q "container-db-$2"; }
check "the people step runs on the same engine, after"    people_step_on 3 postgres
check "it ran against the engine's own container"         bash -c "execn 1 | jq -e '.args | index(\"container-db-postgres\") != null' >/dev/null"
check "as the administrator (psql -U postgres)"           bash -c "execn 1 | jq -e '(.args | index(\"postgres\")) != null and (.args | index(\"psql\")) != null' >/dev/null"
check "psql stops on the first error"                     bash -c "execn 1 | jq -e '.args | index(\"ON_ERROR_STOP=1\") != null' >/dev/null"
check "the credentials came from the service's secret"    bash -c "execn 1 | jq -r .stdin | grep -q \"set target_user 'auth'\" && execn 1 | jq -r .stdin | grep -q 's3cret-pw.x'"
check "core's own SQL was what ran"                       bash -c "execn 1 | jq -r .stdin | grep -q 'CREATE DATABASE' && execn 1 | jq -r .stdin | grep -q 'REVOKE ALL ON DATABASE'"
check "the request was fetched from the service's prefix" grep -q 'provisioning/auth/config.json' "$FAKE_ROOT/calls.log"
check "no secret value is printed"                        bash -c "! grep -q 's3cret-pw.x' '$WORK/out.txt'"

echo "== running it again (Terraform triggers every apply)"
before="$(execs)"; run auth >/dev/null 2>&1
check "is still successful"                               test $? -eq 0
check "and runs the same script and people step again"   test "$(execs)" = $((before + 3))

echo "== the service's own extra SQL"
setup; request auth postgres; extra auth 'CREATE EXTENSION IF NOT EXISTS pg_trgm;'
run auth >/dev/null 2>&1
check "the standard script, the extra, then people"      test "$(execs)" = 4
check "the extra runs as the SERVICE's user, not postgres" bash -c "execn 2 | jq -e '(.args | index(\"auth\")) != null and (.args | index(\"postgres\") == null)' >/dev/null"
check "on the service's own database"                     bash -c "execn 2 | jq -e '.args | index(\"-d\") != null' >/dev/null"
check "with the service's password, never root's"         bash -c "execn 2 | jq -r '.args | join(\" \")' | grep -q 's3cret-pw.x' && ! execn 2 | jq -r '.args | join(\" \")' | grep -q 'R00t-pw.1'"
setup; request auth postgres; extra auth 'SELECT 1;'
check "a failing extra script fails the run"              bash -c "! FAKE_EXEC_FAIL=1 run auth >/dev/null 2>&1"

echo "== other engines"
setup; request auth mysql; echo running > "$FAKE_ROOT/compose-state/db-mysql"
run auth >/dev/null 2>&1
check "mysql: runs as root with MYSQL_PWD, not -p"        bash -c "execn 1 | jq -r '.args | join(\" \")' | grep -q 'MYSQL_PWD=R00t-pw.1' && execn 1 | jq -e '.args | index(\"-uroot\") != null' >/dev/null"
check "mysql: core's SQL, with identifiers prepared"      bash -c "execn 1 | jq -r .stdin | grep -q 'CREATE DATABASE IF NOT EXISTS' && execn 1 | jq -r .stdin | grep -q 'PREPARE statement'"
setup; request auth mongodb; echo running > "$FAKE_ROOT/compose-state/db-mongodb"
run auth >/dev/null 2>&1
check "mongodb: runs mongosh as the administrator"        bash -c "execn 1 | jq -e '.args | index(\"mongosh\") != null' >/dev/null && execn 1 | jq -r .stdin | grep -q 'createUser'"
check "mongodb: the user lives in admin, as DocumentDB's do" bash -c "execn 1 | jq -r .stdin | grep -q 'getSiblingDB(\"admin\")' && execn 1 | jq -r .stdin | grep -q 'role: \"readWrite\", db: target_db'"

echo "== refusals"
setup
check "no request published: refused"                     bash -c "! run auth >/dev/null 2>&1"
request other postgres
check "and nothing was executed"                          test "$(execs)" = 0
setup; mkdir -p "$FAKE_ROOT/s3/b/provisioning/auth"
printf '{"service_name":"billing","database_engine":"postgres","database_secrets_arn":"%s","secret_mappings":{"db_key":"db_name","user_key":"db_user","pass_key":"db_password"}}' "$SECRET_ARN" > "$FAKE_ROOT/s3/b/provisioning/auth/config.json"
check "a request naming another service is refused"       bash -c "! run auth >/dev/null 2>&1"
check "and nothing was executed"                          test "$(execs)" = 0
setup; request auth redis; echo running > "$FAKE_ROOT/compose-state/db-redis"
check "an engine core has no script for is refused"       bash -c "! run auth >/dev/null 2>&1"
setup; request auth postgres; rm -f "$FAKE_ROOT/compose-state/db-postgres"
check "an engine that is not running is refused"          bash -c "! run auth >/dev/null 2>&1"
setup; request auth postgres
check "a service name that is a path is refused"          bash -c "! run '../other' >/dev/null 2>&1"
check "an empty service name is refused"                  bash -c "! run '' >/dev/null 2>&1"
check "too many arguments are refused"                    bash -c "! run auth extra >/dev/null 2>&1"
setup; printf '%s' '{"db_name":"auth;DROP","db_user":"auth","db_password":"pw"}' > "$FAKE_ROOT/secrets/$(printf '%s' "$SECRET_ARN" | tr '/:' '__')"; request auth postgres
check "a credential that is not a plain identifier is refused" bash -c "! run auth >/dev/null 2>&1"
check "and nothing reached the engine"                    test "$(execs)" = 0

echo "== provision.sh's own mode argument"
setup; request auth postgres
check "an unknown mode is refused"                        bash -c "! bash '$WS/provision.sh' '$FAKE_ROOT/s3/b/provisioning/auth/config.json' '$WS/provision-postgres.sql' superuser >/dev/null 2>&1"

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
