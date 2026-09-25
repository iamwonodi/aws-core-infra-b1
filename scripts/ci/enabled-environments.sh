#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# THE ENVIRONMENTS THIS PROJECT RUNS
#
# environments.json, at the repository's root, lists them:
#
#   { "environments": ["development", "production"] }
#
# Any one, two or all three of development, staging and production. Folders of
# the others stay in the repository, ignored, so turning one on later is one
# line here (and scripts/init-project.sh). Every workflow asks this script, so
# nothing is planned, applied, destroyed or provisioned for an environment the
# project does not run.
#
# Usage:
#   enabled-environments.sh                   the list, as a JSON array, in order
#   enabled-environments.sh --check ENV       exit 0 if ENV is enabled, else explain and exit 1
#   enabled-environments.sh --filter JSON     the JSON array, keeping only enabled environments
#
#   ENVIRONMENTS_FILE  another file than <repository>/environments.json (tests)
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="${ENVIRONMENTS_FILE:-${REPO_ROOT}/environments.json}"
KNOWN='["development","staging","production"]'

[[ -f "${FILE}" ]] || { echo "ERROR: ${FILE} is missing: it lists the environments this project runs." >&2; exit 1; }

# The list, checked, in the platform's order (development, staging, production)
# whatever order the file uses.
if ! ENABLED="$(jq -ce --argjson known "${KNOWN}" '
    .environments as $e
    | if ($e | type) != "array" or ($e | length) == 0 then error("environments must be a non-empty list")
      elif ($e - $known | length) > 0 then error("unknown environment(s): \($e - $known | join(", "))")
      elif ($e | unique | length) != ($e | length) then error("an environment is listed twice")
      else [$known[] | select(. as $k | $e | index($k))] end' "${FILE}" 2>&1)"; then
  echo "ERROR: ${FILE}: ${ENABLED#jq: error (at *): }" >&2
  exit 1
fi

case "${1:-}" in
  "")
    echo "${ENABLED}"
    ;;
  --check)
    ENVIRONMENT="${2:?--check needs an environment}"
    if ! jq -e --arg e "${ENVIRONMENT}" 'index($e) != null' <<< "${ENABLED}" >/dev/null; then
      echo "ERROR: '${ENVIRONMENT}' is not one of the environments this project runs: $(jq -r 'join(", ")' <<< "${ENABLED}")." >&2
      echo "       To run it, add it to environments.json (scripts/init-project.sh --environments)." >&2
      exit 1
    fi
    ;;
  --filter)
    # In the platform's order, whatever order the input has: safest first.
    jq -nce --argjson enabled "${ENABLED}" --argjson given "${2:?--filter needs a JSON array}" \
      '[$enabled[] | select(. as $e | $given | index($e))]'
    ;;
  *)
    echo "ERROR: Usage: ${0} [--check ENV | --filter JSON]" >&2
    exit 1
    ;;
esac
