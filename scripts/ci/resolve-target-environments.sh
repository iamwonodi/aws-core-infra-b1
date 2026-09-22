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

if [[ "${EVENT_NAME}" == "workflow_dispatch" ]]; then
  if [[ -z "${MANUAL_ENVIRONMENT}" ]]; then
    echo "ERROR: workflow_dispatch run but no environment input was supplied." >&2
    exit 1
  fi
  echo "[\"${MANUAL_ENVIRONMENT}\"]"
else
  if [[ -z "${CHANGES_JSON}" ]]; then
    echo "[]"
  else
    echo "${CHANGES_JSON}"
  fi
fi
