#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# RESOLVE TARGET ENVIRONMENTS
#
# Decides which environment(s) terraform-plan.yml should run against.
#
#   - Triggered by "pull_request" (the automatic path): the caller has
#     already run dorny/paths-filter against this PR's diff; its "changes"
#     output is a ready-made JSON array of the environment names that
#     actually changed (e.g. ["staging"]). That array is used as-is.
#
#   Either way, only environments listed in environments.json: a pull request
#   drops the others, and a manual plan of one is refused.
#
#   - Triggered by "workflow_dispatch" (the manual path — used to plan a
#     specific environment on demand, e.g. to pick up a new assets release
#     with no Terraform file changes at all): there is no diff to filter,
#     so the single environment supplied via the workflow's "environment"
#     input is used directly instead.
#
# Usage:
#   resolve-target-environments.sh <event-name> <manual-environment> <changes-json>
#
#   <manual-environment> and <changes-json> may be empty strings when not
#   applicable to the current event type.
# ==============================================================================

if [[ $# -ne 3 ]]; then
  echo "ERROR: Usage: ${0} <event-name> <manual-environment> <changes-json>" >&2
  exit 1
fi

EVENT_NAME="$1"
MANUAL_ENVIRONMENT="$2"
CHANGES_JSON="$3"

ENABLED="$(dirname "${BASH_SOURCE[0]}")/enabled-environments.sh"

if [[ "${EVENT_NAME}" == "workflow_dispatch" ]]; then
  if [[ -z "${MANUAL_ENVIRONMENT}" ]]; then
    echo "ERROR: workflow_dispatch run but no environment input was supplied." >&2
    exit 1
  fi
  # A plan asked for by name must be one this project runs.
  bash "${ENABLED}" --check "${MANUAL_ENVIRONMENT}"
  echo "[\"${MANUAL_ENVIRONMENT}\"]"
else
  # The folders a pull request changed, less any environment this project does
  # not run: those folders stay in the repository, ignored. "shared" (modules/,
  # .terraform-version) is used by every environment, so it plans them all.
  if jq -e 'index("shared") != null' <<< "${CHANGES_JSON:-[]}" >/dev/null; then
    bash "${ENABLED}"
  else
    bash "${ENABLED}" --filter "${CHANGES_JSON:-[]}"
  fi
fi
