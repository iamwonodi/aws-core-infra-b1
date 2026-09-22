#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# RENDER DESTROY PLAN SUMMARY
#
# Prints Markdown summarizing a destroy plan for a given environment. The
# caller redirects this into $GITHUB_STEP_SUMMARY. If a plan text file is
# given and exists, its content is included (truncated defensively so an
# enormous plan can't blow past GitHub's step summary size limit);
# otherwise this reports that there was nothing to destroy.
#
# Usage:
#   render-destroy-plan-summary.sh <environment> <has-changes:true|false> [plan-text-file]
# ==============================================================================

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "ERROR: Usage: ${0} <environment> <has-changes:true|false> [plan-text-file]" >&2
  exit 1
fi

ENVIRONMENT="$1"
HAS_CHANGES="$2"
PLAN_TEXT_FILE="${3:-}"

MAX_BYTES=200000

echo "### Terraform Destroy Plan — ${ENVIRONMENT}"

if [[ "${HAS_CHANGES}" != "true" ]]; then
  echo ""
  echo "Nothing to destroy: this environment's state holds no resources."
  exit 0
fi

if [[ -z "${PLAN_TEXT_FILE}" || ! -f "${PLAN_TEXT_FILE}" ]]; then
  echo ""
  echo "ERROR: has-changes was true but no plan text file was found." >&2
  exit 1
fi

echo '```'
head -c "${MAX_BYTES}" "${PLAN_TEXT_FILE}"
if [[ $(wc -c < "${PLAN_TEXT_FILE}") -gt ${MAX_BYTES} ]]; then
  echo ""
  echo "... (truncated in this summary — see the uploaded plan artifact for the full output)"
fi
echo '```'
