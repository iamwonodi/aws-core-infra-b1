#!/usr/bin/env bash
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$(cd "$TESTS_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export PATH="${TESTS_DIR}/bin:${PATH}"
export FAKE_ROOT="$WORK/root" FETCH_RETRY_SECONDS=0
F=$MODULES/platform/host-scripts/assets/fetch-scripts.sh
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }; bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n"; fi; }
setup(){ rm -rf $FAKE_ROOT $WORK/dest; mkdir -p $FAKE_ROOT/{s3/b/_platform/lib,s3/b/_platform/fleet,ssm} $WORK/dest; : > $FAKE_ROOT/calls.log
  echo 'echo LIB' > $FAKE_ROOT/s3/b/_platform/lib/deploy-lib.sh; echo 'echo UPDATE' > $FAKE_ROOT/s3/b/_platform/fleet/update.sh
  LS=$(sha256sum $FAKE_ROOT/s3/b/_platform/lib/deploy-lib.sh | cut -d' ' -f1); US=$(sha256sum $FAKE_ROOT/s3/b/_platform/fleet/update.sh | cut -d' ' -f1)
  printf '{"_platform/lib/deploy-lib.sh":"%s","_platform/fleet/update.sh":"%s"}' "$LS" "$US" > $FAKE_ROOT/ssm/core__platform__scripts-manifest; }
run(){ bash -c "set -euo pipefail; source $F; fetch_platform_scripts /core/platform/scripts-manifest b af-south-1 $WORK/dest"; }
echo "== fetch_platform_scripts"
setup; run 2>/dev/null
check "both scripts installed"                    bash -c "[ -f $WORK/dest/deploy-lib.sh ] && [ -f $WORK/dest/update.sh ]"
check "installed executable"                      test "$(stat -c %a $WORK/dest/update.sh)" = 755
check "no .new leftovers"                         bash -c "! ls $WORK/dest/*.new 2>/dev/null"
setup; echo 'echo OLD' > $WORK/dest/update.sh; echo 'echo TAMPERED' > $FAKE_ROOT/s3/b/_platform/fleet/update.sh
run 2>/dev/null; rc=$?
check "tampered object refused"                   test $rc -ne 0
check "existing script left untouched"            grep -q OLD $WORK/dest/update.sh
check "the good file was NOT installed either"    test ! -e $WORK/dest/deploy-lib.sh
setup; rm $FAKE_ROOT/ssm/core__platform__scripts-manifest
check "missing manifest fails"                    bash -c "! run 2>/dev/null"
setup; rm $FAKE_ROOT/s3/b/_platform/lib/deploy-lib.sh
check "missing object fails, nothing installed"   bash -c "! run 2>/dev/null && [ ! -e $WORK/dest/update.sh ]"
setup; echo '{}' > $FAKE_ROOT/ssm/core__platform__scripts-manifest
check "empty manifest fails"                      bash -c "! run 2>/dev/null"
echo; echo "passed=$pass failed=$fail"; [ $fail -eq 0 ]
