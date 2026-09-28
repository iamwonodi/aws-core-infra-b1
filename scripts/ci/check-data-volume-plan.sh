#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# CHECK THE DATA VOLUME'S PLAN
#
# Runs modules/database/host's terraform test with -verbose and reads the plan
# of its second run, which changes the deploy bucket under an existing host.
# The data volume must come through untouched: its subnet lookup read at plan
# time, not put off until the apply.
#
# Why this reads the plan instead of asserting in the test: the volume sits two
# modules down, where a test's assertions cannot reach, and a mocked provider
# never reports "forces replacement". What it does show is the cause, the
# lookup deferred ("will be read during apply") and the volume's zone becoming
# "(known after apply)"; against the real provider that zone change replaces
# the volume.
#
# Usage (from the repository root, after terraform init in the module):
#   check-data-volume-plan.sh
#
#   TERRAFORM  the binary to run (default: terraform)
# ==============================================================================

TERRAFORM="${TERRAFORM:-terraform}"
MODULE="modules/database/host"
RUN="a_change_to_the_deploy_bucket_leaves_the_data_volume_in_place"

OUTPUT="$(cd "${MODULE}" && "${TERRAFORM}" test -no-color -verbose 2>&1)" || {
  echo "${OUTPUT}"
  echo "ERROR: ${MODULE}'s tests failed." >&2
  exit 1
}

# The second run's plan: everything printed from its name on.
PLAN="$(awk -v run="${RUN}" 'index($0, run) { found = 1 } found' <<< "${OUTPUT}")"
if [[ -z "${PLAN}" ]]; then
  echo "ERROR: the test output has no run named ${RUN}." >&2
  exit 1
fi

failed=0
if grep -q 'data\.aws_subnet\.host will be read during apply' <<< "${PLAN}"; then
  echo "FAIL the host's subnet lookup is put off until the apply" >&2
  failed=1
fi
if grep -q 'aws_ebs_volume\.this will be' <<< "${PLAN}"; then
  echo "FAIL the data volume changes when the deploy bucket does:" >&2
  grep -A3 'aws_ebs_volume\.this will be' <<< "${PLAN}" >&2
  failed=1
fi

if [[ ${failed} -ne 0 ]]; then
  echo "ERROR: a change around the database host would replace its data volume. See scripts/ci/check-host-dependencies.py." >&2
  exit 1
fi

echo "ok   the data volume is untouched when the deploy bucket changes"
