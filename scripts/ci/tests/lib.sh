# Tiny assertion helpers shared by the script tests.
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ok   $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local name="$1"; shift; if "$@"; then ok "${name}"; else bad "${name}"; fi; }
finish(){ echo; echo "passed=${pass} failed=${fail}"; [[ ${fail} -eq 0 ]]; }
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "${TESTS_DIR}/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
export PATH="${TESTS_DIR}/bin:${PATH}"
