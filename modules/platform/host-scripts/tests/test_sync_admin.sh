#!/usr/bin/env bash
# sync-admin-password.sh, offline: which engine gets which statement, when the
# secret's previous version is read, and everything it refuses. AWS and Docker
# are the stubs in tests/bin; test_sync_admin_real.sh runs it against real
# PostgreSQL and MySQL.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
TESTS="$(pwd)"; A="$(cd ../../../database/host/assets && pwd)"
export PATH="$TESTS/bin:$PATH"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export FAKE_ROOT="$WORK/fake"; WS="$WORK/ws"

pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }; bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

setup(){
  rm -rf "$FAKE_ROOT" "$WS"; mkdir -p "$FAKE_ROOT"/{secrets,compose-state} "$WS"
  : > "$FAKE_ROOT/calls.log"
  cp "$A/sync-admin-password.sh" "$WS/"
  printf 'AWS_REGION=af-south-1\nCORE_ROOT_SECRET_ARN=arn_core\n' > "$WS/.env"
  secret current 'N3w-pw.2'
  secret previous 'Old-pw.1'
  unset FAKE_EXEC_FAIL_ON
}
secret(){ # current|previous <password>
  local file="$FAKE_ROOT/secrets/arn_core"; [[ $1 == previous ]] && file+=".AWSPREVIOUS"
  printf '{"username":"admin","root_password":"%s"}' "$2" > "$file"
}
running(){ for e in "$@"; do echo running > "$FAKE_ROOT/compose-state/db-$e"; done; }
run(){ bash "$WS/sync-admin-password.sh" "$@" > "$WORK/out.txt" 2>&1 < /dev/null; }
execs(){ ls "$FAKE_ROOT/exec"/*.json 2>/dev/null | wc -l | tr -d ' '; }
execn(){ cat "$FAKE_ROOT/exec/$(printf '%03d' "$1").json"; }
args(){ execn "$1" | jq -r '.args | join(" ")'; }
stdin(){ execn "$1" | jq -r .stdin; }
read_previous(){ grep -q 'AWSPREVIOUS' "$FAKE_ROOT/calls.log"; }
printed(){ grep -qE 'N3w-pw.2|Old-pw.1' "$WORK/out.txt"; }

echo "== postgres"
setup; running postgres; run postgres; rc=$?
check "succeeds"                                            test $rc -eq 0
check "one statement, over the local socket as postgres"    bash -c "[[ \$(ls $FAKE_ROOT/exec | wc -l) == 1 ]] && grep -q 'psql -U postgres -d postgres' <<< \"\$(jq -r '.args|join(\" \")' $FAKE_ROOT/exec/001.json)\""
check "sets the current password"                           bash -c "jq -r .stdin $FAKE_ROOT/exec/001.json | grep -qx \"ALTER ROLE postgres WITH PASSWORD 'N3w-pw.2';\""
check "the password goes in on stdin, not the command line" bash -c "! jq -r '.args|join(\" \")' $FAKE_ROOT/exec/001.json | grep -q N3w-pw.2"
check "stops on the first error"                            bash -c "jq -r '.args|join(\" \")' $FAKE_ROOT/exec/001.json | grep -q ON_ERROR_STOP=1"
check "the previous version is never read"                  bash -c "! grep -q AWSPREVIOUS $FAKE_ROOT/calls.log"
check "no password is printed"                              bash -c "! grep -qE 'N3w-pw.2|Old-pw.1' $WORK/out.txt"

echo "== mysql"
setup; running mysql; run mysql; rc=$?
check "current works: succeeds"                             test $rc -eq 0
check "  after one check, as root with the current password" bash -c "[[ \$(ls $FAKE_ROOT/exec | wc -l) == 1 ]] && jq -r '.args|join(\" \")' $FAKE_ROOT/exec/001.json | grep -q 'MYSQL_PWD=N3w-pw.2 container-db-mysql mysql -uroot'"
check "  and nothing changed, previous never read"          bash -c "! grep -q AWSPREVIOUS $FAKE_ROOT/calls.log"
setup; running mysql; export FAKE_EXEC_FAIL_ON=1; run mysql; rc=$?
check "current refused, previous works: succeeds"           test $rc -eq 0
check "  the previous version was read"                     bash -c "grep -q AWSPREVIOUS $FAKE_ROOT/calls.log"
check "  signed in with the previous password"              bash -c "jq -r '.args|join(\" \")' $FAKE_ROOT/exec/002.json | grep -q MYSQL_PWD=Old-pw.1"
check "  and set the current one on that account"           bash -c "jq -r .stdin $FAKE_ROOT/exec/003.json | grep -qx \"ALTER USER CURRENT_USER() IDENTIFIED BY 'N3w-pw.2';\" && jq -r '.args|join(\" \")' $FAKE_ROOT/exec/003.json | grep -q MYSQL_PWD=Old-pw.1"
check "  no password is printed"                            bash -c "! grep -qE 'N3w-pw.2|Old-pw.1' $WORK/out.txt"
setup; running mysql; export FAKE_EXEC_FAIL_ON=1,2; run mysql; rc=$?
check "neither works: refused"                              test $rc -ne 0
check "  with the runbook named"                            grep -q 'Changing an administrator password' "$WORK/out.txt"
check "  and nothing was changed"                           test "$(execs)" = 2
setup; running mysql; rm "$FAKE_ROOT/secrets/arn_core.AWSPREVIOUS"; export FAKE_EXEC_FAIL_ON=1; run mysql; rc=$?
check "current refused and no previous version: refused"    bash -c "[[ $rc -ne 0 ]] && grep -q 'no previous version' $WORK/out.txt && [[ \$(ls $FAKE_ROOT/exec | wc -l) == 1 ]]"

echo "== mongodb"
setup; running mongodb; run mongodb; rc=$?
check "current works: succeeds after one check"             bash -c "[[ $rc -eq 0 && \$(ls $FAKE_ROOT/exec | wc -l) == 1 ]]"
check "  as the secret's username, passwords in the environment" bash -c "jq -r '.args|join(\" \")' $FAKE_ROOT/exec/001.json | grep -q 'ADMIN_USER=admin -e ADMIN_PWD=N3w-pw.2' && ! jq -r .stdin $FAKE_ROOT/exec/001.json | grep -q N3w-pw.2"
setup; running mongodb; export FAKE_EXEC_FAIL_ON=1; run mongodb; rc=$?
check "current refused, previous works: changes it"         bash -c "[[ $rc -eq 0 ]] && jq -r .stdin $FAKE_ROOT/exec/003.json | grep -q 'changeUserPassword(process.env.ADMIN_USER, process.env.NEW_PWD)' && jq -r '.args|join(\" \")' $FAKE_ROOT/exec/003.json | grep -q 'ADMIN_PWD=Old-pw.1 -e NEW_PWD=N3w-pw.2'"
setup; running mongodb; export FAKE_EXEC_FAIL_ON=1,2; run mongodb; rc=$?
check "neither works: refused, nothing changed"             bash -c "[[ $rc -ne 0 && \$(ls $FAKE_ROOT/exec | wc -l) == 2 ]]"

echo "== which engines"
setup; running postgres mysql; run; rc=$?
check "no engine named: every running one"                  bash -c "[[ $rc -eq 0 ]] && jq -r '.args|join(\" \")' $FAKE_ROOT/exec/001.json | grep -q container-db-postgres && jq -r '.args|join(\" \")' $FAKE_ROOT/exec/002.json | grep -q container-db-mysql"
setup; run; rc=$?
check "none running: nothing to do"                         bash -c "[[ $rc -eq 0 && ! -d $FAKE_ROOT/exec ]]"
setup; run mysql; rc=$?
check "a named engine not running: refused"                 bash -c "[[ $rc -ne 0 ]] && grep -q 'no running container for mysql' $WORK/out.txt"
setup; running postgres mysql; export FAKE_EXEC_FAIL_ON=1; run; rc=$?
check "one engine failing fails the run, the others still synced" bash -c "[[ $rc -ne 0 && \$(ls $FAKE_ROOT/exec | wc -l) == 2 ]]"

setup; running mysql; export FAKE_EXEC_FAIL_ON=1,3; run mysql; rc=$?
check "the change itself failing fails the run"            bash -c "[[ $rc -ne 0 ]] && ! grep -q 'it is now' $WORK/out.txt"

echo "== refusals"
setup; running postgres; run redis; rc=$?
check "an unknown engine"                                   bash -c "[[ $rc -ne 0 && ! -d $FAKE_ROOT/exec ]]"
setup; running postgres; secret current "x'; DROP ROLE y; --"; run postgres; rc=$?
check "a password outside core's alphabet reaches no engine" bash -c "[[ $rc -ne 0 && ! -d $FAKE_ROOT/exec ]]"
setup; running mongodb; printf '{"username":"a'"'"'b","root_password":"N3w-pw.2"}' > "$FAKE_ROOT/secrets/arn_core"; run mongodb; rc=$?
check "a username that is not a plain name"                 bash -c "[[ $rc -ne 0 && ! -d $FAKE_ROOT/exec ]]"
setup; running postgres; rm "$FAKE_ROOT/secrets/arn_core"; run postgres; rc=$?
check "an unreadable secret"                                bash -c "[[ $rc -ne 0 && ! -d $FAKE_ROOT/exec ]]"
setup; running mysql; secret previous "bad'pw"; export FAKE_EXEC_FAIL_ON=1; run mysql; rc=$?
check "a previous version outside the alphabet is not used" bash -c "[[ $rc -ne 0 && \$(ls $FAKE_ROOT/exec | wc -l) == 1 ]]"

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
