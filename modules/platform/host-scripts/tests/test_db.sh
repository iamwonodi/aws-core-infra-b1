#!/usr/bin/env bash
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$(cd "$TESTS_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export PATH="${TESTS_DIR}/bin:${PATH}"
export FAKE_ROOT="$WORK/root"
A=$MODULES
WS=$WORK/dbws
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }; bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
ECR=123456789012.dkr.ecr.af-south-1.amazonaws.com
setup(){
  rm -rf "$FAKE_ROOT" "$WS"; mkdir -p "$FAKE_ROOT"/{secrets,s3/b/database/engines,ssm} "$WS" $WORK/data
  : > "$FAKE_ROOT/calls.log"
  cp $A/database/host/assets/update.sh $A/platform/host-scripts/assets/deploy-lib.sh "$WS/"
  cat > "$WS/.env" <<E
PROJECT_NAME=core
ENVIRONMENT=development
DATABASE_WORKSPACE=$WS
DATA_ROOT=$WORK/data/data
AWS_REGION=af-south-1
DEPLOY_BUCKET_NAME=b
ECR_REGISTRY_URL=$ECR
ENABLE_ECR_ACCESS=${ENABLE_ECR:-true}
REQUIRE_ECR_IMAGES=${REQUIRE_ECR:-true}
CORE_ROOT_SECRET_ARN=arn_core
E
  printf '%s' '{"username":"admin","root_password":"R00t$pw#1"}' > "$FAKE_ROOT/secrets/arn_core"
}
engine(){ # name image extra-volume env-extra
  local d="$FAKE_ROOT/s3/b/database/engines/$1"; mkdir -p "$d"
  printf '{"services":{"db":{"image":"%s","env_file":[".resolved/.env"],"ports":["${ENGINE_PORT}:5432"],"volumes":["%s"]}}}' "$2" "${3:-\${DATA_ROOT}/$1:/var/lib/data}" > "$d/docker-compose.yaml"
  printf 'POSTGRES_PASSWORD=__FROM_SECRET__:CORE_ROOT_SECRET_ARN:root_password\n%b' "${4:-}" > "$d/.env"
}
registry(){ printf '%s' "$1" > "$FAKE_ROOT/s3/b/database/registry.json"; }
U(){ ( cd $WS && DATABASE_LOCK_FILE=$WS/lock "$@" bash ./update.sh ); }
IMG=$ECR/docker-hub/postgres:16

echo "== no registry"
setup; out=$(U 2>&1); rc=$?
check "no registry is a successful no-op"            bash -c "[ $rc -eq 0 ] && echo '$out' | grep -q 'nothing to deploy'"
check "nothing started"                              test ! -d $FAKE_ROOT/compose-state

echo "== registry drives deploy/stop"
setup; engine postgres $IMG; engine mysql $IMG
# 15432, not PostgreSQL's usual 5432: the port must visibly come from the
# registry, not from the image's own default.
registry '{"postgres":{"port":15432,"active":true},"mysql":{"port":3306,"active":false}}'
out=$(U 2>&1); rc=$?
check "run succeeds"                                 test $rc -eq 0
check "active engine deployed"                       test "$(cat $FAKE_ROOT/compose-state/db-postgres 2>/dev/null)" = running
check "active:false engine NOT deployed (jq // regression)"  test ! -e $FAKE_ROOT/compose-state/db-mysql
check "inactive engine gets 'stop'"                  grep -q 'docker compose --project-name db-mysql stop' $FAKE_ROOT/calls.log
check "platform vars reach compose (port + data root)" bash -c "grep -qx 'ENGINE_PORT=15432' $FAKE_ROOT/up-env/db-postgres && grep -qx 'DATA_ROOT=$WORK/data/data' $FAKE_ROOT/up-env/db-postgres"
check "root password resolved (special chars intact)" grep -qx 'POSTGRES_PASSWORD=R00t$pw#1' $FAKE_ROOT/up-env/db-postgres
check "no secret in output"                          bash -c "! echo '$out' | grep -q 'R00t'"
check "scratch .resolved removed"                    test ! -e $WS/engines/postgres/.resolved
check "summary"                                      bash -c "echo '$out' | grep -q '1 deployed, 1 stopped, 0 failed'"
check "ECR login done"                               grep -q '^docker login --username AWS' $FAKE_ROOT/calls.log

echo "== removal never stops or removes anything"
rm -rf $FAKE_ROOT/s3/b/database/engines/postgres
: > $FAKE_ROOT/calls.log
out=$(U 2>&1); rc=$?
check "registered engine with missing folder fails"  test $rc -eq 1
check "container still running"                      test "$(cat $FAKE_ROOT/compose-state/db-postgres)" = running
check "no stop/down issued for the missing folder"   bash -c "! grep -q 'db-postgres \(stop\|down\)' $FAKE_ROOT/calls.log"
registry '{"mysql":{"port":3306,"active":false}}'
: > $FAKE_ROOT/calls.log; out=$(U 2>&1); rc=$?
check "engine removed from registry left alone"      bash -c "[ $rc -eq 0 ] && ! grep -q 'db-postgres' $FAKE_ROOT/calls.log && [ \"\$(cat $FAKE_ROOT/compose-state/db-postgres)\" = running ]"
check "'down' is never called anywhere"              bash -c "! grep -q ' down' $FAKE_ROOT/calls.log"

echo "== registry validation (nothing changes on a bad registry)"
for case in \
  '{"a":{"port":5432},"b":{"port":5432}}|more than one active engine' \
  '{"a":{"port":80}}|invalid entry' \
  '{"a":{"port":"5432"}}|invalid entry' \
  '{"A_b":{"port":5432}}|invalid entry' \
  '{"a":{"port":5432,"active":"yes"}}|invalid entry' \
  '[1,2]|must be a JSON object' ; do
  reg="${case%%|*}"; want="${case##*|}"
  setup; engine a $IMG; registry '{"a":{"port":20009}}'; U >/dev/null 2>&1; : > $FAKE_ROOT/calls.log; rm -rf $FAKE_ROOT/compose-state
  registry "$reg"; out=$(U 2>&1); rc=$?
  check "rejects $reg"                               bash -c "[ $rc -eq 1 ] && echo '$out' | grep -q '$want' && [ ! -d $FAKE_ROOT/compose-state ] && grep -q 20009 $WS/registry.json"
done
setup; engine a $IMG; engine b $IMG; registry '{"a":{"port":5432,"active":true},"b":{"port":5432,"active":false}}'
out=$(U 2>&1); rc=$?
check "same port allowed when only one is active"    test $rc -eq 0

echo "== engine-level guards"
setup; engine pg $IMG; registry '{"pg":{"port":5432}}'
out=$(U 2>&1); rc=$?
check "active omitted defaults to true"              test "$(cat $FAKE_ROOT/compose-state/db-pg 2>/dev/null)" = running
setup; engine pg $IMG '/var/lib/elsewhere:/var/lib/data'; registry '{"pg":{"port":5432}}'
out=$(U 2>&1); rc=$?
check "data dir off the persistent volume refused"   bash -c "[ $rc -eq 1 ] && echo '$out' | grep -q 'outside the allowed paths' && [ ! -e $FAKE_ROOT/compose-state/db-pg ]"
setup; engine pg postgres:16; registry '{"pg":{"port":5432}}'
out=$(U 2>&1); rc=$?
check "Docker Hub image refused when ECR required"   bash -c "[ $rc -eq 1 ] && echo '$out' | grep -q 'is not from' && [ ! -e $FAKE_ROOT/compose-state/db-pg ]"
ENGINE_REQ=1; REQUIRE_ECR=false; export REQUIRE_ECR; setup; engine pg postgres:16; registry '{"pg":{"port":5432}}'
out=$(U 2>&1); rc=$?
check "Docker Hub image fine when not required"      test $rc -eq 0
unset REQUIRE_ECR
setup; engine pg $IMG 'PLACEHOLDER'; registry '{"pg":{"port":5432}}'
engine pg $IMG; printf 'ENGINE_PORT=1\n' >> $FAKE_ROOT/s3/b/database/engines/pg/.env
out=$(U 2>&1); rc=$?
check "reserved name in engine .env refused"         bash -c "[ $rc -eq 1 ] && echo '$out' | grep -q 'reserved name'"
setup; engine pg $IMG; registry '{"pg":{"port":5432}}'; printf 'POSTGRES_PASSWORD=__FROM_SECRET__:CORE_ROOT_SECRET_ARN:nope\n' > $FAKE_ROOT/s3/b/database/engines/pg/.env
out=$(U 2>&1); rc=$?
printf '%s' "$out" > $WORK/out.txt
check "unknown secret field fails that engine"       bash -c "[ $rc -eq 1 ] && grep -q 'no field named' $WORK/out.txt && grep -q 'Failed engines: pg' $WORK/out.txt"
setup; engine ok $IMG; engine bad $IMG; registry '{"ok":{"port":5432},"bad":{"port":3306}}'
out=$(FAKE_UP_FAIL=db-bad U 2>&1); rc=$?
check "one failing engine does not stop the other"   bash -c "[ $rc -eq 1 ] && [ \"\$(cat $FAKE_ROOT/compose-state/db-ok)\" = running ] && echo '$out' | grep -q 'Failed engines: bad'"
setup; engine pg $IMG; mkdir -p $FAKE_ROOT/s3/b/database/engines/stray; printf '{}' > $FAKE_ROOT/s3/b/database/engines/stray/docker-compose.yaml; registry '{"pg":{"port":5432}}'
out=$(U 2>&1)
check "folder without registry entry warned, not started" bash -c "echo '$out' | grep -q 'stray has a folder but no entry' && [ ! -e $FAKE_ROOT/compose-state/db-stray ]"
ENABLE_ECR=false; export ENABLE_ECR; setup; engine pg $IMG; registry '{"pg":{"port":5432}}'; out=$(U 2>&1)
check "no ECR login when ECR access is disabled"     bash -c "! grep -q '^docker login' $FAKE_ROOT/calls.log"

echo; echo "passed=$pass failed=$fail"; [ $fail -eq 0 ]
