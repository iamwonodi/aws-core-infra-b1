#!/usr/bin/env bash
# test_init.sh in a project made from the blueprint: init-project.sh has already
# run there (no CHANGE_ME left, fewer environments), so its tests cannot pass
# and must skip, saying why, instead of turning every project's Script Tests red.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "${SCRIPTS}/.." && pwd)"

# A copy of the repository, as init-project.sh leaves it: placeholders filled,
# one environment enabled.
mkdir -p "${WORK}/project"
( cd "${ROOT}" && tar --exclude=.git --exclude='.terraform' -cf - scripts infrastructure environments.json ) \
  | tar -xf - -C "${WORK}/project"
sed -i 's/CHANGE_ME/initialised/g' "${WORK}/project/infrastructure/"*/terraform.tfvars
printf '{\n  "environments": [\n    "development"\n  ]\n}\n' > "${WORK}/project/environments.json"

bash "${WORK}/project/scripts/ci/tests/test_init.sh" > "${WORK}/out" 2>&1; rc=$?
check "test_init.sh passes in an initialised project"   test "${rc}" -eq 0
check "  by skipping, saying why"                        grep -q "skipped: this project has been initialised" "${WORK}/out"
check "  and runs none of its checks"                    bash -c "! grep -q '  FAIL\|  ok ' '${WORK}/out'"

# In the blueprint itself it still runs every check.
if grep -q CHANGE_ME "${ROOT}/infrastructure/development/terraform.tfvars"; then
  bash "${ROOT}/scripts/ci/tests/test_init.sh" > "${WORK}/blueprint" 2>&1
  check "in the blueprint it still runs its checks"      grep -q "  ok   run succeeds" "${WORK}/blueprint"
fi

finish
