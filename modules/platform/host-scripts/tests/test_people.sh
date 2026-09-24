#!/usr/bin/env bash
# provision-people.sh against stubbed aws and docker: what it refuses, which
# engines it touches, and what reaches the engine. What a person can actually do
# on a real server is test_people_real.sh.
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
  people '{"agent_ada":{"password":"Ada-pw.0123","access":"write"},"agent_tunde":{"password":"Tunde-pw.0123","access":"read"}}'
}
people(){ printf '%s' "$1" > "$FAKE_ROOT/secrets/$PEOPLE_ID"; }
running(){ for e in "$@"; do echo running > "$FAKE_ROOT/compose-state/db-$e"; done; }
prepare(){ printf '%s\n' "$2" > "$FAKE_ROOT/exec-out/$(printf '%03d' "$1")"; }
run(){ bash "$WS/provision-people.sh" "$@" < /dev/null > "$WORK/out.txt" 2>&1; }
execs(){ ls "$FAKE_ROOT/exec"/*.json 2>/dev/null | wc -l | tr -d ' '; }
execn(){ cat "$FAKE_ROOT/exec/$(printf '%03d' "$1").json"; }
stdin_of(){ execn "$1" | jq -r .stdin; }
args_of(){ execn "$1" | jq -r '.args | join(" ")'; }

# stdin_has <exec#> <fixed text>, args_have <exec#> <fixed text>: no regex, no nested quoting.
stdin_has(){ stdin_of "$1" | grep -qF -- "$2"; }
args_have(){ args_of "$1" | grep -qF -- "$2"; }
out_has(){ grep -qF -- "$1" "$WORK/out.txt"; }
not(){ ! "$@"; }

echo "== PostgreSQL"
setup; running postgres
prepare 1 "orders"
run; rc=$?
check "succeeds"                                            test $rc -eq 0
check "one query for the service databases, one script"     test "$(execs)" = 2
check "the script runs as postgres, stopping on errors"     args_have 2 "psql -U postgres -d postgres -q -v ON_ERROR_STOP=1"
check "write gets the write group"                          stdin_has 2 'GRANT agent_group_write TO "agent_ada";'
check "read gets the read group"                            stdin_has 2 'GRANT agent_group_read TO "agent_tunde";'
check "and each loses the other"                            stdin_has 2 'REVOKE agent_group_read FROM "agent_ada";'
check "logins not listed are dropped, listed ones kept"     stdin_has 2 "rolname <> ALL (ARRAY['agent_ada','agent_tunde']::text[])"
check "the service's database is granted"                   stdin_has 2 'GRANT CONNECT ON DATABASE "orders" TO agent_group_read, agent_group_write;'
check "and covered for tables created later"                stdin_has 2 'ALTER DEFAULT PRIVILEGES FOR ROLE "orders" IN SCHEMA public GRANT SELECT ON TABLES TO agent_group_read;'
check "psql reaches the database with \\connect"            stdin_has 2 '\connect orders'
check "passwords go by stdin"                               stdin_has 2 "PASSWORD 'Ada-pw.0123'"
check "never on a command line"                             not grep -qF "Ada-pw" "$FAKE_ROOT/calls.log"

echo "== MySQL"
setup; running mysql
prepare 1 "orders"
prepare 2 $'agent_ada\nagent_gone'
run; rc=$?
check "succeeds"                                            test $rc -eq 0
check "as root, its password in the environment"            args_have 3 "-e MYSQL_PWD=R00t-pw.1 container-db-mysql mysql -uroot"
check "a person no longer listed is dropped"                stdin_has 3 "DROP USER 'agent_gone'@'%';"
check "a listed person is not"                              not stdin_has 3 "DROP USER 'agent_ada'"
check "write gets write privileges"                         stdin_has 3 "GRANT SELECT, INSERT, UPDATE, DELETE ON \`orders\`.* TO 'agent_ada'@'%';"
check "read gets read"                                      stdin_has 3 "GRANT SELECT ON \`orders\`.* TO 'agent_tunde'@'%';"
check "grants start from nothing each time"                 stdin_has 3 "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'agent_tunde'@'%';"
check "reports who was removed"                             out_has "Removed agent_gone."

setup; running mysql
prepare 1 "order_items"
prepare 2 ""
run; rc=$?
check "an underscore in a database name is escaped"         stdin_has 3 'ON `order\_items`.*'

echo "== MongoDB"
setup; running mongodb
run; rc=$?
check "succeeds"                                            test $rc -eq 0
check "a single script"                                     test "$(execs)" = 1
check "as the administrator"                                args_have 1 "-e MONGO_ROOT_PWD=R00t-pw.1 container-db-mongodb mongosh --quiet"
check "the people it applies are the checked list"          stdin_has 1 'const people = {"agent_ada":{"password":"Ada-pw.0123","access":"write"},"agent_tunde":{"password":"Tunde-pw.0123","access":"read"}};'
check "roles on every database"                             stdin_has 1 'entry.access === "write" ? "readWriteAnyDatabase" : "readAnyDatabase"'

echo "== which engines"
setup; running postgres mysql
run; rc=$?
check "every running engine when none is named"             test $rc -eq 0
check "  postgres"                                          out_has "people on postgres"
check "  mysql"                                             out_has "people on mysql"
setup; running postgres mysql
run postgres; rc=$?
check "only the engine named"                               test $rc -eq 0
check "  and not the other"                                 not out_has "people on mysql"
setup
run mysql; rc=$?
check "an engine named but not running fails"               test $rc -ne 0
setup
run; rc=$?
check "no engine running is not an error"                   test $rc -eq 0
check "  and says so"                                       out_has "nothing to do"
setup
run oracle; rc=$?
check "an unknown engine is refused"                        test $rc -ne 0

echo "== refusals: nothing reaches an engine"
refuse(){ setup; running postgres; people "$2"; run; local rc=$?; check "$1" test $rc -ne 0; check "  before any exec" test "$(execs)" = 0; }
refuse "a name that is not agent_<name>"                    '{"ada":{"password":"Ada-pw.0","access":"read"}}'
refuse "a name carrying a quote"                            "{\"agent_a'da\":{\"password\":\"Ada-pw.0\",\"access\":\"read\"}}"
refuse "an access level that is not read or write"          '{"agent_ada":{"password":"Ada-pw.0","access":"admin"}}'
refuse "a password with a quote"                            "{\"agent_ada\":{\"password\":\"it's\",\"access\":\"read\"}}"
refuse "a secret that is not an object"                     '["agent_ada"]'
setup; running postgres; rm "$FAKE_ROOT/secrets/$PEOPLE_ID"
run; rc=$?
check "a missing people secret fails"                       test $rc -ne 0
check "  and says core creates it"                          out_has "has core been applied"

echo "== nobody listed"
setup; running postgres; people '{}'
prepare 1 "orders"
run; rc=$?
check "succeeds"                                            test $rc -eq 0
check "  dropping every agent_ login"                       stdin_has 2 "rolname <> ALL (ARRAY[]::text[])"

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
