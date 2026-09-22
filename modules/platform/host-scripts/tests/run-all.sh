#!/usr/bin/env bash
# Runs every offline test for the platform scripts. Needs bash, jq, python3,
# flock and sha256sum (all present on ubuntu-latest and on the fleet AMI).
# AWS and Docker are replaced by the stubs in tests/bin.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

failed=0

for suite in test_lib.sh test_fetch.sh test_fleet.sh test_db.sh test_provision.sh test_device.sh; do
  echo "################ ${suite}"
  bash "./${suite}" || failed=1
done

if [[ ${failed} -ne 0 ]]; then
  echo "SOME TESTS FAILED"
  exit 1
fi

echo "ALL TESTS PASSED"
