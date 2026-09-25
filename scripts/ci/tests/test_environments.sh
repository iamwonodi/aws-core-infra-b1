#!/usr/bin/env bash
# enabled-environments.sh and the resolvers that use it: the plan's, the
# destroy's, and the apply's discovery from plan artifacts.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
H="${SCRIPTS}/ci/enabled-environments.sh"
export ENVIRONMENTS_FILE="${WORK}/environments.json"
runs(){ printf '{"environments":%s}' "$1" > "${ENVIRONMENTS_FILE}"; }
out(){ "$@" 2>/dev/null; }

echo "== enabled-environments.sh"
runs '["production","development"]'
check "the list, in the platform's order"                  test "$(out bash "$H")" = '["development","production"]'
check "an enabled environment passes --check"              bash "$H" --check production
check "another is refused"                                 bash -c "! bash '$H' --check staging 2>/dev/null"
check "and the refusal says how to enable it"              bash -c "bash '$H' --check staging 2>&1 | grep -q 'environments.json'"
check "--filter keeps only enabled, in order"              test "$(out bash "$H" --filter '["staging","production","development"]')" = '["development","production"]'
check "--filter of nothing is nothing"                     test "$(out bash "$H" --filter '[]')" = '[]'
runs '["prod"]';            check "an unknown name is refused"    bash -c "! bash '$H' 2>/dev/null"
runs '[]';                  check "an empty list is refused"      bash -c "! bash '$H' 2>/dev/null"
runs '["staging","staging"]'; check "a name twice is refused"     bash -c "! bash '$H' 2>/dev/null"
rm -f "${ENVIRONMENTS_FILE}"; check "a missing file is refused"   bash -c "! bash '$H' 2>/dev/null"

echo "== resolve-target-environments.sh (plan)"
R="${SCRIPTS}/ci/resolve-target-environments.sh"
runs '["development","production"]'
check "a pull request drops environments not run"          test "$(out bash "$R" pull_request '' '["staging","production"]')" = '["production"]'
check "a pull request touching none of them plans none"    test "$(out bash "$R" pull_request '' '["staging"]')" = '[]'
check "no changes, no plans"                               test "$(out bash "$R" pull_request '' '')" = '[]'
check "a shared change plans every environment run"        test "$(out bash "$R" pull_request '' '["shared"]')" = '["development","production"]'
check "and with an environment too, still each once"       test "$(out bash "$R" pull_request '' '["production","shared"]')" = '["development","production"]'
check "a manual plan of an enabled one"                    test "$(out bash "$R" workflow_dispatch production '')" = '["production"]'
check "a manual plan of another is refused"                bash -c "! bash '$R' workflow_dispatch staging '' >/dev/null 2>&1"

echo "== resolve-destroy-environments.sh"
D="${SCRIPTS}/ci/resolve-destroy-environments.sh"
check "\"all\" is this project's environments, in order"  test "$(out bash "$D" all)" = '["development","production"]'
check "one named and enabled"                              test "$(out bash "$D" development)" = '["development"]'
check "one not run is refused"                             bash -c "! bash '$D' staging >/dev/null 2>&1"

echo "== discover-environments-from-artifacts.sh (apply)"
A="${SCRIPTS}/ci/discover-environments-from-artifacts.sh"
mkdir -p "${WORK}/art/a" "${WORK}/art/b"
echo '{"environment":"production"}' > "${WORK}/art/a/deployment-metadata.json"
check "a plan for an enabled environment is applied"       test "$(out bash "$A" "${WORK}/art")" = '["production"]'
echo '{"environment":"staging"}' > "${WORK}/art/b/deployment-metadata.json"
check "a plan for one not run is refused"                  bash -c "! bash '$A' '${WORK}/art' >/dev/null 2>&1"
finish
