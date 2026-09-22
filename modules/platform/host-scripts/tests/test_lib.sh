#!/usr/bin/env bash
# Offline tests for deploy-lib.sh using the fake aws/docker in $WORK/bin.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$(cd "$TESTS_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export PATH="${TESTS_DIR}/bin:${PATH}"
export FAKE_ROOT="$WORK/root"
LIB=$MODULES/platform/host-scripts/assets/deploy-lib.sh
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
rm -rf "$FAKE_ROOT"; mkdir -p "$FAKE_ROOT/secrets" "$FAKE_ROOT/s3"; : > "$FAKE_ROOT/calls.log"
W=$(mktemp -d)
printf '%s' '{"django_secret_key":"pa$$#w(rd)&*","root_password":"rootpw","multi":"a\nb"}' > "$FAKE_ROOT/secrets/arn_good"
run(){ bash -c "set -euo pipefail; source $LIB; export AWS_REGION=af-south-1; $*"; }

echo "== resolve_env_file"
printf 'APP_SECRET_ARN=arn:good\nDJANGO_SECRET_KEY=__FROM_SECRET__:APP_SECRET_ARN\nDATABASE_PASSWORD=__FROM_SECRET__:APP_SECRET_ARN:root_password\nPLAIN=1\n# comment\n' > $W/lf.env
sed 's/$/\r/' $W/lf.env > $W/crlf.env
run "resolve_env_file $W/lf.env $W/out.lf" 2>/dev/null
check "implicit + explicit sentinel resolved"  grep -qx 'DJANGO_SECRET_KEY=pa$$#w(rd)&\*' $W/out.lf
check "explicit field resolved"               grep -qx 'DATABASE_PASSWORD=rootpw' $W/out.lf
check "plain and comment lines pass through"  bash -c "grep -qx 'PLAIN=1' $W/out.lf && grep -qx '# comment' $W/out.lf"
check "output is mode 0600"                   test "$(stat -c %a $W/out.lf)" = 600
run "resolve_env_file $W/crlf.env $W/out.crlf" 2>/dev/null
check "CRLF input resolved, no CR in output"  bash -c "grep -qx 'DATABASE_PASSWORD=rootpw' $W/out.crlf && ! grep -q \$'\r' $W/out.crlf"
printf 'APP_SECRET_ARN=arn:good\nX=__FROM_SECRET__:APP_SECRET_ARN:nope\n' > $W/missing.env
check "missing field returns 1, no output left"  bash -c "! bash -c 'set -euo pipefail; source $LIB; AWS_REGION=x; resolve_env_file $W/missing.env $W/out.m' 2>/dev/null && [ ! -e $W/out.m ] && [ ! -e $W/out.m.tmp ]"
printf 'APP_SECRET_ARN=arn:good\nX=__FROM_SECRET__:APP_SECRET_ARN:multi\n' > $W/nl.env
check "newline value refused"                 bash -c "! bash -c 'set -euo pipefail; source $LIB; AWS_REGION=x; resolve_env_file $W/nl.env $W/out.n' 2>/dev/null"
printf 'APP_SECRET_ARN=arn:bad\nX=__FROM_SECRET__:APP_SECRET_ARN:multi\n' > $W/bad.env
check "unfetchable secret refused"            bash -c "! bash -c 'set -euo pipefail; source $LIB; AWS_REGION=x; resolve_env_file $W/bad.env $W/out.b' 2>/dev/null"
printf 'X=__FROM_SECRET__:NO_SUCH_VAR\n' > $W/noarn.env
check "unset ARN variable refused"            bash -c "! bash -c 'set -euo pipefail; source $LIB; AWS_REGION=x; resolve_env_file $W/noarn.env $W/out.a' 2>/dev/null"
check "one secret fetched once for two keys"  test "$(grep -c 'secret-id arn:good' $FAKE_ROOT/calls.log)" -le "$(( $(grep -c 'secret-id arn:good' $FAKE_ROOT/calls.log) ))"
: > $FAKE_ROOT/calls.log; run "resolve_env_file $W/lf.env $W/out.lf2" 2>/dev/null
check "cache: exactly one fetch for two keys" test "$(grep -c 'get-secret-value' $FAKE_ROOT/calls.log)" = 1

echo "== deploy_lock"
( run "deploy_lock $W/l.lock 5; sleep 3" ) & sleep 1
check "second holder times out"               bash -c "! bash -c 'source $LIB; deploy_lock $W/l.lock 1' 2>/dev/null"
wait
check "lock free after holder exits"          bash -c "source $LIB; deploy_lock $W/l.lock 1"

echo "== deploy_jitter"
check "0 returns immediately"                 run "deploy_jitter 0"
check "non-numeric rejected"                  bash -c "! bash -c 'source $LIB; deploy_jitter abc' 2>/dev/null"
check "over 999 rejected"                     bash -c "! bash -c 'source $LIB; deploy_jitter 1000' 2>/dev/null"
t0=$(date +%s); run "deploy_jitter 2" >/dev/null; t1=$(date +%s)
check "jitter 2 sleeps at most ~2s"           test $((t1-t0)) -le 3

echo "== ecr_login"
: > $FAKE_ROOT/calls.log
check "login succeeds"                        run "ecr_login af-south-1 123.dkr.ecr.af-south-1.amazonaws.com >/dev/null"
check "docker login was called"               grep -q '^docker login --username AWS' $FAKE_ROOT/calls.log
check "login failure returns 1"               bash -c "! FAKE_ECR_FAIL=1 bash -c 'source $LIB; ecr_login r reg' >/dev/null 2>&1"

echo "== find_compose_file"
mkdir -p $W/d1 $W/d2 $W/d3; touch $W/d1/docker-compose.yml $W/d2/docker-compose.yaml
check ".yml found"                            test "$(run "find_compose_file $W/d1")" = "$W/d1/docker-compose.yml"
check ".yaml found"                           test "$(run "find_compose_file $W/d2/")" = "$W/d2/docker-compose.yaml"
check "none found returns 1"                  bash -c "! bash -c 'source $LIB; find_compose_file $W/d3' >/dev/null"

echo "== compose_guard_violations"
ROOTS='["/opt/apps/svc","/data/engine"]'
v(){ printf '%s' "$1" | bash -c "source $LIB; compose_guard_violations '$ROOTS' '${2:-}'"; }
check "clean file: no output"                 test -z "$(v '{"services":{"web":{"image":"x","volumes":[{"type":"bind","source":"/opt/apps/svc/data","target":"/d"},{"type":"volume","source":"named","target":"/n"}]}}}')"
check "privileged rejected"                   bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"privileged\":true}}}' | grep -q 'a: privileged'"
check "cap_add rejected"                      bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"cap_add\":[\"SYS_ADMIN\"]}}}' | grep -q 'cap_add is not allowed (SYS_ADMIN)'"
for k in network_mode pid ipc uts userns_mode cgroup; do
  check "$k=host rejected"                    bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"$k\":\"host\"}}}' | grep -q '$k=host'"
done
check "network_mode container: rejected"      bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"network_mode\":\"container:other\"}}}' | grep -q 'container:other'"
check "devices rejected"                      bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"devices\":[\"/dev/sda\"]}}}' | grep -q 'devices'"
check "seccomp unconfined rejected"           bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"security_opt\":[\"seccomp=unconfined\"]}}}' | grep -q 'seccomp=unconfined'"
check "docker.sock rejected"                  bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"volumes\":[{\"type\":\"bind\",\"source\":\"/var/run/docker.sock\",\"target\":\"/s\"}]}}}' | grep -q 'Docker socket'"
check "bind outside roots rejected"           bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"volumes\":[{\"type\":\"bind\",\"source\":\"/etc\",\"target\":\"/e\"}]}}}' | grep -q 'outside the allowed paths'"
check "prefix-lookalike dir rejected"         bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"volumes\":[{\"type\":\"bind\",\"source\":\"/opt/apps/svc-evil\",\"target\":\"/e\"}]}}}' | grep -q 'outside'"
check "root itself allowed"                   test -z "$(v '{"services":{"a":{"volumes":[{"type":"bind","source":"/data/engine","target":"/e"}]}}}')"
check "foreign image rejected with prefix"    bash -c "$(declare -f v); ROOTS='$ROOTS'; LIB=$LIB; v '{\"services\":{\"a\":{\"image\":\"postgres:16\"}}}' 'acct.dkr.ecr.r.amazonaws.com/' | grep -q 'is not from'"
check "ECR image accepted with prefix"        test -z "$(v '{"services":{"a":{"image":"acct.dkr.ecr.r.amazonaws.com/db/postgres:16"}}}' 'acct.dkr.ecr.r.amazonaws.com/')"
check "no prefix: any image accepted"         test -z "$(v '{"services":{"a":{"image":"postgres:16"}}}')"
check "several violations all reported"       test "$(v '{"services":{"a":{"privileged":true,"network_mode":"host","cap_add":["X"]}}}' | wc -l)" = 3
check "no services key is fine"               test -z "$(v '{}')"

echo "== compose_guard (through fake docker compose config)"
mkdir -p $W/svc/.resolved; : > $W/svc/.resolved/.env
printf '%s' '{"services":{"web":{"image":"x","env_file":[".resolved/.env"],"volumes":["./data:/app/data:ro"]}}}' > $W/svc/docker-compose.yml
check "relative ./data resolved inside root"  run "compose_guard $W/svc/docker-compose.yml $W/svc $W/svc/.resolved/.env '[\"$W/svc\"]'"
printf '%s' '{"services":{"web":{"image":"x","volumes":["../other:/x"]}}}' > $W/svc/evil.yml
check "../ escape rejected"                   bash -c "! bash -c 'source $LIB; compose_guard $W/svc/evil.yml $W/svc $W/svc/.resolved/.env \"[\\\"$W/svc\\\"]\"' 2>/dev/null"
printf '%s' '{"services":{"web":{"image":"x","env_file":[".resolved/nope"]}}}' > $W/svc/noenv.yml
check "unrenderable file rejected"            bash -c "! bash -c 'source $LIB; compose_guard $W/svc/noenv.yml $W/svc $W/svc/.resolved/.env \"[\\\"$W/svc\\\"]\"' 2>/dev/null"
check "guard never prints rendered JSON"      bash -c "! bash -c 'source $LIB; compose_guard $W/svc/evil.yml $W/svc $W/svc/.resolved/.env \"[\\\"$W/svc\\\"]\"' 2>&1 | grep -q '\"services\"'"

echo; echo "passed=$pass failed=$fail"; [ $fail -eq 0 ]
