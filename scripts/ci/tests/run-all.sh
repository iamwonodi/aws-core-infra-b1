#!/usr/bin/env bash
# Offline tests for the scripts under scripts/ (needs bash, git, jq; gh is faked).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
failed=0
for suite in test_placeholders.sh test_lock_files.sh test_metadata.sh test_publish.sh test_identity.sh test_init.sh; do
  echo "################ ${suite}"
  bash "./${suite}" || failed=1
done
[[ ${failed} -eq 0 ]] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
