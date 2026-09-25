#!/usr/bin/env bash
# provision-people.sh against stubbed aws and docker, in both modes: what it
# refuses, which engines it touches, and what reaches the engine. What a person
# can actually do on a real server is test_people_real.sh.
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

PEOPLE_ID="core-database-people-development-secret-vault"
SERVICE_ARN="arn_orders"

setup(){
  rm -rf "$FAKE_ROOT" "$WS"
  mkdir -p "$FAKE_ROOT"/{secrets,compose-state,exec-out} "$WS"
  : > "$FAKE_ROOT/calls.log"
  cp "$A/provision-people.sh" "$WS/"
  cat > "$WS/.env" <<E
PROJECT_NAME=core
ENVIRONMENT=development
AWS_REGION=af-south-1
CORE_ROOT_SECRET_ARN=arn_core
E
  printf '%s' '{"username":"admin","root_password":"R00t-pw.1"}' > "$FAKE_ROOT/secrets/arn_core"
  platform '{"platform.ada":{"password":"Ada-pw.0123","access":"write"},"platform.tunde":{"password":"Tunde-pw.0123","access":"read"}}'
  agents '{"bob":{"password":"Bob-pw.0123","access":"write"},"eve":{"password":"Eve-pw.0123","access":"read"}}'
}
platform(){ printf '%s' "$1" > "$FAKE_ROOT/secrets/$PEOPLE_ID"; }
agents(){ # the service's secret, with its agents as a JSON string
  jq -n --arg a "$1" '{db_name: "orders", db_user: "orders", db_password: "Svc-pw.x", agents: $a}' > "$FAKE_ROOT/secrets/$SERVICE_ARN"
  jq -n --arg e "${2:-postgres}" '{service_name: "orders", database_engine: $e, database_secrets_arn: "arn_orders", secret_mappings: {db_key: "db_name", user_key: "db_user", pass_key: "db_password"}}' > "$WORK/request.json"
}
running(){ for e in "$@"; do echo running > "$FAKE_ROOT/compose-state/db-$e"; done; }
prepare(){ printf '%s\n' "$2" > "$FAKE_ROOT/exec-out/$(printf '%03d' "$1")"; }
run(){ timeout 60 bash "$WS/provision-people.sh" "$@" > "$WORK/out.txt" 2>&1 < /dev/null; }
execs(){ ls "$FAKE_ROOT/exec"/*.json 2>/dev/null | wc -l | tr -d ' '; }
stdin_of(){ jq -r .stdin "$FAKE_ROOT/exec/$(printf '%03d' "$1").json"; }
args_of(){ jq -r '.args | join(" ")' "$FAKE_ROOT/exec/$(printf '%03d' "$1").json"; }
has(){ grep -qF -- "$2" <<< "$(stdin_of "$1")"; }
lacks(){ ! grep -qF -- "$2" <<< "$(stdin_of "$1")"; }
count(){ grep -cF -- "$2" <<< "$(stdin_of "$1")"; }
args_have(){ grep -qF -- "$2" <<< "$(args_of "$1")"; }
all(){ local c; for c in "$@"; do eval "$c" || return 1; done; }

echo "== platform, PostgreSQL"
setup; running postgres
prepare 1 $'orders\nbilling'                       # the service databases
prepare 2 $'platform.ada\nplatform.gone\nplatform.group_read'  # this scope's logins now
run platform; rc=$?
check "succeeds"                                         test $rc -eq 0
check "two queries, then one script"                     test "$(execs)" = 3
check "as postgres, stopping on the first error"         bash -c "[[ '$(args_of 3)' == *'psql -U postgres -d postgres -q -v ON_ERROR_STOP=1'* ]]"
check "each person gets their scope's group"             all "has 3 'GRANT \"platform.group_write\" TO \"platform.ada\";'" "has 3 'GRANT \"platform.group_read\" TO \"platform.tunde\";'"
check "a platform login no longer listed is dropped"     has 3 'DROP ROLE "platform.gone";'
check "the groups are never dropped"                     bash -c "! grep -q 'DROP ROLE \"platform.group' <<< '$(stdin_of 3)'"
check "every service database is granted"                all "has 3 'GRANT CONNECT ON DATABASE \"orders\"'" "has 3 'GRANT CONNECT ON DATABASE \"billing\"'"
check "and covered for tables created later"             has 3 'ALTER DEFAULT PRIVILEGES FOR ROLE "billing" IN SCHEMA public'
check "passwords go by stdin, never a command line"      all "! grep -q Ada-pw '$FAKE_ROOT/calls.log'" "has 3 Ada-pw.0123"
check "reports who was removed"                          grep -q "Removed platform.gone." "$WORK/out.txt"

echo "== service, PostgreSQL"
setup; running postgres
prepare 1 $'orders.bob\norders.gone'              # this scope's logins now
run service "$WORK/request.json"; rc=$?
check "succeeds"                                         test $rc -eq 0
check "no search for databases: one query, one script"   test "$(execs)" = 2
check "logins are <service>.<name>"                      all "has 2 'ALTER ROLE \"orders.bob\"'" "has 2 'ALTER ROLE \"orders.eve\"'"
check "with the service's own groups"                    has 2 'GRANT "orders.group_write" TO "orders.bob";'
check "on the service's database only"                   all "[[ \$(count 2 'GRANT CONNECT ON DATABASE') == 1 ]]" "has 2 'GRANT CONNECT ON DATABASE \"orders\"'"
check "its agent no longer listed is dropped"            has 2 'DROP ROLE "orders.gone";'

echo "== service, MySQL"
setup; agents '{"bob":{"password":"Bob-pw.0123","access":"write"}}' mysql; running mysql
prepare 1 $'orders.bob\norders.gone'
run service "$WORK/request.json"; rc=$?
check "succeeds"                                         test $rc -eq 0
check "as root, its password in the environment"         bash -c "[[ '$(args_of 2)' == *'MYSQL_PWD=R00t-pw.1'*'mysql -uroot' ]]"
check "finds its logins by exact prefix, not LIKE"       args_have 1 "LEFT(User, 7) = 'orders.'"
check "write on the service's database only"             all "has 2 \"GRANT SELECT, INSERT, UPDATE, DELETE ON \\\`orders\\\`.* TO 'orders.bob'@'%';\"" "[[ \$(count 2 'GRANT SELECT') == 1 ]]"
check "grants start from nothing each time"              has 2 "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'orders.bob'@'%';"
check "its agent no longer listed is dropped"            has 2 "DROP USER 'orders.gone'@'%';"

echo "== MongoDB"
setup; agents '{"bob":{"password":"Bob-pw.0123","access":"read"}}' mongodb; running mongodb
run service "$WORK/request.json"; rc=$?
check "service: succeeds, one script"                    bash -c "[[ $rc -eq 0 && $(execs) == 1 ]]"
check "service: the checked list, keyed by login"        has 1 'const people = {"orders.bob":{"password":"Bob-pw.0123","access":"read"}};'
check "service: on its database only"                    has 1 'const database = "orders";'
check "service: removal limited to its exact logins"     has 1 'const mine = new RegExp("^orders\\.[a-z][a-z0-9]{1,19}$");'
setup; running mongodb
run platform; rc=$?
check "platform: every database"                         bash -c "[[ $rc -eq 0 ]] && grep -qF 'const database = null;' <<< '$(stdin_of 1)'"
check "platform: as the administrator"                   bash -c "[[ '$(args_of 1)' == *'MONGO_ROOT_PWD=R00t-pw.1'*'mongosh --quiet' ]]"

echo "== which engines"
setup; running postgres mysql
run platform; rc=$?
check "platform: every running engine"                   bash -c "[[ $rc -eq 0 ]] && grep -q 'logins on postgres' '$WORK/out.txt' && grep -q 'logins on mysql' '$WORK/out.txt'"
setup; running postgres mysql
run platform postgres; rc=$?
check "platform: only the engine named"                  bash -c "[[ $rc -eq 0 ]] && ! grep -q 'logins on mysql' '$WORK/out.txt'"
setup; run platform mysql; rc=$?
check "an engine named but not running fails"            test $rc -ne 0
setup; run platform; rc=$?
check "no engine running is not an error"                bash -c "[[ $rc -eq 0 ]] && grep -q 'nothing to do' '$WORK/out.txt'"
setup; run platform oracle; rc=$?
check "an unknown engine is refused"                     test $rc -ne 0
setup; run nonsense; rc=$?
check "an unknown mode is refused"                       test $rc -ne 0

echo "== refusals: nothing reaches an engine"
refuse_platform(){ setup; running postgres; platform "$2"; run platform; rc=$?; check "$1" bash -c "[[ $rc -ne 0 && \$(ls $FAKE_ROOT/exec 2>/dev/null | wc -l) == 0 ]]"; }
refuse_agents(){ setup; running postgres; agents "$2"; run service "$WORK/request.json"; rc=$?; check "$1" bash -c "[[ $rc -ne 0 && \$(ls $FAKE_ROOT/exec 2>/dev/null | wc -l) == 0 ]]"; }
refuse_platform "a platform login that is not platform.<name>"  '{"ada":{"password":"Ada-pw.0","access":"read"}}'
refuse_platform "another scope's login on the platform list"    '{"orders.ada":{"password":"Ada-pw.0","access":"read"}}'
refuse_platform "a name carrying a quote"                       "{\"platform.a'da\":{\"password\":\"Ada-pw.0\",\"access\":\"read\"}}"
refuse_platform "a platform list that is not an object"         '["platform.ada"]'
refuse_agents   "an agent name that is not a name"              '{"Bob":{"password":"Bob-pw.0","access":"read"}}'
refuse_agents   "an access level that is not read or write"     '{"bob":{"password":"Bob-pw.0","access":"admin"}}'
refuse_agents   "a password with a quote"                       "{\"bob\":{\"password\":\"it's\",\"access\":\"read\"}}"
refuse_agents   "agents that are not JSON"                      'not json'
refuse_agents   "a login over MySQL's 32 characters"            '{"abcdefghijklmnopqrstu":{"password":"Bob-pw.0","access":"read"}}'
setup; running postgres; rm "$FAKE_ROOT/secrets/$PEOPLE_ID"
run platform; rc=$?
check "a missing people secret fails, naming core"       bash -c "[[ $rc -ne 0 ]] && grep -q 'has core been applied' '$WORK/out.txt'"

echo "== nobody listed"
setup; running postgres; agents '{}'
prepare 1 $'orders.bob'
run service "$WORK/request.json"; rc=$?
check "a service with no agents: its logins go"          all "[[ $rc -eq 0 ]]" "has 2 'DROP ROLE \"orders.bob\";'"
setup; running postgres
jq -n '{db_name: "orders", db_user: "orders", db_password: "Svc-pw.x"}' > "$FAKE_ROOT/secrets/$SERVICE_ARN"
prepare 1 ""
run service "$WORK/request.json"; rc=$?
check "a secret without an agents entry means none"      test $rc -eq 0

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
