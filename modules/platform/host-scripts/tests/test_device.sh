set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES="$(cd "$TESTS_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export PATH="${TESTS_DIR}/bin:${PATH}"
export PATH="$TESTS_DIR/fake-lsblk:$PATH"
MODULES="$MODULES" WORK="$WORK" python3 - <<'PY'
import os
s=open(os.environ['MODULES']+'/database/host/assets/bootstrap.sh').read()
a=s.index('resolve_data_device() {'); b=s.index('if [[ "$${ENABLE_DATA_VOLUME_MOUNT}"')
open(os.environ['WORK']+'/devfn.sh','w').write(s[a:b].replace('$${','${').replace('$$','$'))
PY
pass=0; fail=0
t(){ local name="$1" scen="$2" expect="$3" out rc; out=$(FAKE_LSBLK_SCENARIO=$scen bash -c "source $WORK/devfn.sh; resolve_data_device /dev/sdb-nonexistent"); rc=$?
     if [[ "$expect" == FAIL ]]; then [[ $rc -ne 0 ]] && { pass=$((pass+1)); echo "  ok   $name"; } || { fail=$((fail+1)); echo "  FAIL $name (got '$out')"; }
     else [[ "$out" == "$expect" && $rc -eq 0 ]] && { pass=$((pass+1)); echo "  ok   $name"; } || { fail=$((fail+1)); echo "  FAIL $name (got '$out' rc=$rc)"; }; fi; }
echo "== resolve_data_device"
t "single unmounted EBS disk is chosen, root skipped" one_extra /dev/nvme1n1
t "ambiguous (two extra disks) refuses to guess"      two_extra FAIL
t "no extra disk fails"                               none FAIL
t "instance-store disks are not EBS"                  instance_store FAIL
echo "passed=$pass failed=$fail"; [ $fail -eq 0 ]
