#!/usr/bin/env bash
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$(cd "$TESTS_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export PATH="${TESTS_DIR}/bin:${PATH}"
export FAKE_ROOT="$WORK/root"
A=$MODULES
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }
bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
setup(){
  rm -rf "$FAKE_ROOT" $WORK/app; mkdir -p "$FAKE_ROOT"/{secrets,s3/b,ssm} $WORK/app
  : > "$FAKE_ROOT/calls.log"
  cp $A/compute/assets/update.sh $A/platform/host-scripts/assets/deploy-lib.sh $WORK/app/
  cat > $WORK/app/.env <<'E'
PROJECT_NAME=core
DEPLOY_BUCKET_NAME=b
FLEET_TIER=private
AWS_REGION=af-south-1
ECR_REGISTRY_URL=123.dkr.ecr.af-south-1.amazonaws.com
E
  printf '%s' '{"django_secret_key":"s3cr3t$#(x)","password":"dbpw"}' > "$FAKE_ROOT/secrets/arn_app"
}
svc(){ # name compose-json env-content
  mkdir -p "$FAKE_ROOT/s3/b/private/$1"; printf '%s' "$2" > "$FAKE_ROOT/s3/b/private/$1/docker-compose.yml"; printf '%b' "$3" > "$FAKE_ROOT/s3/b/private/$1/.env"
}
GOOD='{"services":{"app":{"image":"x","env_file":[".resolved/.env"],"volumes":["./data:/app/data:ro"]}}}'
EVIL='{"services":{"app":{"image":"x","env_file":[".resolved/.env"],"privileged":true}}}'
ESC='{"services":{"app":{"image":"x","env_file":[".resolved/.env"],"volumes":["../web:/steal"]}}}'
U(){ ( cd $WORK/app && FLEET_LOCK_FILE=$WORK/app/lock "$@" bash ./update.sh ) ; }

echo "== happy path + failure isolation"
setup
svc web  "$GOOD" 'APP_SECRET_ARN=arn_app\nDJANGO_SECRET_KEY=__FROM_SECRET__:APP_SECRET_ARN\nDATABASE_PASSWORD=__FROM_SECRET__:APP_SECRET_ARN:password\n'
svc evil "$EVIL" 'A=1\n'
svc esc  "$ESC"  'A=1\n'
mkdir -p "$FAKE_ROOT/s3/b/private/incomplete"; printf 'A=1' > "$FAKE_ROOT/s3/b/private/incomplete/.env"
out=$(U 2>&1); rc=$?
check "run fails overall when a service is rejected"      test $rc -eq 1
check "good service deployed"                             test "$(cat $FAKE_ROOT/compose-state/web 2>/dev/null)" = running
check "privileged service not started"                    test ! -e $FAKE_ROOT/compose-state/evil
check "path-escape service not started"                   test ! -e $FAKE_ROOT/compose-state/esc
check "rejection reason is reported"                      bash -c "echo '$out' | grep -q 'privileged mode is not allowed'"
check "escape reason is reported"                         bash -c "echo '$out' | grep -q 'outside the allowed paths'"
check "summary counts 1 deployed, 1 skipped, 2 failed"    bash -c "echo '$out' | grep -q 'Deployment complete: 1 deployed, 1 skipped, 2 failed'"
check "secret resolved into the up-time env file"         grep -qx 'DJANGO_SECRET_KEY=s3cr3t$#(x)' $FAKE_ROOT/up-env/web
check "explicit field resolved"                           grep -qx 'DATABASE_PASSWORD=dbpw' $FAKE_ROOT/up-env/web
check "scratch .resolved removed (good service)"          test ! -e $WORK/app/services/web/.resolved
check "scratch .resolved removed (rejected service)"      test ! -e $WORK/app/services/evil/.resolved
check "no secret value in captured output"                bash -c "! echo '$out' | grep -q 's3cr3t'"
check "ECR login performed"                               grep -q '^docker login --username AWS' $FAKE_ROOT/calls.log
check "sync scoped to this tier prefix"                   grep -q 's3 sync s3://b/private/ ' $FAKE_ROOT/calls.log

echo "== removal stops the service"
rm -rf "$FAKE_ROOT/s3/b/private/evil" "$FAKE_ROOT/s3/b/private/esc" "$FAKE_ROOT/s3/b/private/incomplete"; rm -rf "$FAKE_ROOT/s3/b/private/web"
: > $FAKE_ROOT/calls.log
out=$(U 2>&1); rc=$?
check "run succeeds with nothing to deploy"               test $rc -eq 0
check "removed service is brought down"                   grep -q 'docker compose --project-name web down --remove-orphans' $FAKE_ROOT/calls.log
check "removed service's files gone locally"              test ! -d $WORK/app/services/web

echo "== one failing 'up' does not stop the others"
setup
svc a "$GOOD" 'A=1\n'; svc b "$GOOD" 'A=1\n'
out=$(FAKE_UP_FAIL=a U 2>&1); rc=$?
check "overall failure"                                   test $rc -eq 1
check "the other service still deployed"                  test "$(cat $FAKE_ROOT/compose-state/b 2>/dev/null)" = running
check "failed service is named"                           bash -c "echo '$out' | grep -q 'Failed services: a'"

echo "== jitter, lock and config errors"
setup; svc a "$GOOD" 'A=1\n'
t0=$(date +%s); out=$(U env JITTER_SECONDS=2 2>&1); rc=$?; t1=$(date +%s)
check "jitter run succeeds within bound"                  bash -c "[ $rc -eq 0 ] && [ $((t1-t0)) -le 4 ]"
setup; svc a "$GOOD" 'A=1\n'
out=$(U env JITTER_SECONDS=abc 2>&1); rc=$?
check "invalid jitter rejected before any deploy"         bash -c "[ $rc -ne 0 ] && [ ! -e $FAKE_ROOT/compose-state/a ]"
setup; svc a "$GOOD" 'A=1\n'; sed -i '/^FLEET_TIER/d' $WORK/app/.env
out=$(U 2>&1); rc=$?
check "missing FLEET_TIER fails with a clear message"     bash -c "[ $rc -ne 0 ] && echo '$out' | grep -q 'FLEET_TIER must be set'"
setup; svc a "$GOOD" 'A=1\n'
out=$(FAKE_ECR_FAIL=1 U 2>&1); rc=$?
check "ECR login failure aborts before deploying"         bash -c "[ $rc -ne 0 ] && [ ! -e $FAKE_ROOT/compose-state/a ]"
setup; mkdir -p $FAKE_ROOT/s3/b/private/y; printf '%s' "$GOOD" > $FAKE_ROOT/s3/b/private/y/docker-compose.yaml; printf 'A=1' > $FAKE_ROOT/s3/b/private/y/.env
out=$(U 2>&1); rc=$?
check "docker-compose.yaml deployed"                      bash -c "[ $rc -eq 0 ] && [ \"\$(cat $FAKE_ROOT/compose-state/y)\" = running ]"

echo; echo "passed=$pass failed=$fail"; [ $fail -eq 0 ]
