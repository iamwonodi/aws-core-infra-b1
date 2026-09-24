#!/usr/bin/env bash
# ==============================================================================
# PROVISION PEOPLE
#
# Brings the team's database logins (agent_<name>, from data/people.json) in
# line with the people secret core has just applied. Run by the apply workflow
# after every apply, and by the "Provision people" workflow on demand.
#
# What it calls comes from the environment's people_provisioning output:
#
#   {"kind": "host", ...}     development: the database host. Its platform
#                             scripts are refreshed first (they may have changed
#                             in this apply), then the people document runs.
#   {"kind": "managed", ...}  staging, production: each engine's provisioning
#                             function, with {"action": "people"}. A database
#                             that is not running (staging outside its working
#                             hours) is skipped with a warning, not a failure:
#                             run the "Provision people" workflow once it is up.
#
# Usage: provision-people.sh <people_provisioning.json> <aws-region>
#   terraform -chdir=infrastructure/<env> output -json people_provisioning > p.json
#
# Tunable for tests: PROVISION_INTERVAL (5s), PROVISION_TIMEOUT (600s).
# ==============================================================================
set -euo pipefail

SPEC_FILE="${1:?Usage: provision-people.sh <people_provisioning.json> <aws-region>}"
REGION="${2:?aws-region is required}"
INTERVAL="${PROVISION_INTERVAL:-5}"
TIMEOUT="${PROVISION_TIMEOUT:-600}"

if ! jq -e 'type == "object" and (.kind == "host" or .kind == "managed")' "${SPEC_FILE}" >/dev/null 2>&1; then
  echo "ERROR: ${SPEC_FILE} is not a people_provisioning output (kind host or managed)." >&2
  exit 1
fi

warn() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::warning::$*"; else echo "WARNING: $*"; fi
}

# ------------------------------------------------------------------------------
# Development: the database host
# ------------------------------------------------------------------------------

# run_document <document> <instance-id> <what>: send, wait, show the output tail.
run_document() {
  local document="$1" instance="$2" what="$3" command_id status output start elapsed

  [[ "${document}" =~ ^[A-Za-z0-9_.-]{3,128}$ ]] || { echo "ERROR: '${document}' is not a document name." >&2; return 1; }
  [[ "${instance}" =~ ^i-[0-9a-f]{8,17}$ ]] || { echo "ERROR: '${instance}' is not an instance ID." >&2; return 1; }

  echo "${what} (document ${document} on ${instance})."

  if ! command_id="$(aws ssm send-command \
      --document-name "${document}" \
      --instance-ids "${instance}" \
      --comment "${what}" \
      --query "Command.CommandId" --output text \
      --region "${REGION}" 2>&1)"; then
    echo "ERROR: could not send ${document}: ${command_id}" >&2
    return 1
  fi

  start="${SECONDS}"
  while true; do
    status="$(aws ssm get-command-invocation \
      --command-id "${command_id}" --instance-id "${instance}" \
      --query "Status" --output text --region "${REGION}" 2>/dev/null || echo Pending)"
    case "${status}" in
      Pending|InProgress|Delayed) ;;
      *) break ;;
    esac
    elapsed=$(( SECONDS - start ))
    if [[ ${elapsed} -ge ${TIMEOUT} ]]; then
      echo "ERROR: ${document} had not finished after ${TIMEOUT}s; giving up waiting." >&2
      return 1
    fi
    echo "  still running (${elapsed}s)."
    sleep "${INTERVAL}"
  done

  output="$(aws ssm get-command-invocation \
    --command-id "${command_id}" --instance-id "${instance}" \
    --query "[StandardOutputContent, StandardErrorContent]" --output json --region "${REGION}" 2>/dev/null || echo '["",""]')"
  jq -r '.[0] // "", .[1] // "" | split("\n") | .[-25:] | .[] | select(length > 0)' <<< "${output}" | sed 's/^/    /'

  if [[ "${status}" != "Success" ]]; then
    echo "ERROR: ${document} ended ${status}." >&2
    return 1
  fi
}

if [[ "$(jq -r '.kind' "${SPEC_FILE}")" == "host" ]]; then
  INSTANCE="$(jq -r '.instance_id // empty' "${SPEC_FILE}")"
  run_document "$(jq -r '.refresh_document' "${SPEC_FILE}")" "${INSTANCE}" "Refreshing the database host's platform scripts"
  run_document "$(jq -r '.people_document' "${SPEC_FILE}")" "${INSTANCE}" "Provisioning people on the database host"
  echo "People are provisioned on the database host."
  exit 0
fi

# ------------------------------------------------------------------------------
# Staging and production: the managed databases
# ------------------------------------------------------------------------------

database_status() { # <rds|docdb> <id>
  if [[ "$1" == "docdb" ]]; then
    aws docdb describe-db-clusters --db-cluster-identifier "$2" \
      --query "DBClusters[0].Status" --output text --region "${REGION}"
  else
    aws rds describe-db-instances --db-instance-identifier "$2" \
      --query "DBInstances[0].DBInstanceStatus" --output text --region "${REGION}"
  fi
}

ENGINES="$(jq -r '.engines // {} | keys[]' "${SPEC_FILE}")"

if [[ -z "${ENGINES}" ]]; then
  echo "No managed database in this environment; nothing to do."
  exit 0
fi

FAILED=()
SKIPPED=()
RESPONSE_FILE="$(mktemp)"
trap 'rm -f "${RESPONSE_FILE}"' EXIT

for engine in ${ENGINES}; do
  function_name="$(jq -r --arg e "${engine}" '.engines[$e].function' "${SPEC_FILE}")"
  kind="$(jq -r --arg e "${engine}" '.engines[$e].database_kind' "${SPEC_FILE}")"
  database="$(jq -r --arg e "${engine}" '.engines[$e].database_id' "${SPEC_FILE}")"

  echo
  echo "== ${engine} (${database})"

  if ! status="$(database_status "${kind}" "${database}" 2>&1)"; then
    echo "ERROR: could not read ${database}'s state: ${status}" >&2
    FAILED+=("${engine}")
    continue
  fi

  if [[ "${status}" != "available" ]]; then
    warn "${engine}: ${database} is ${status}, so its people were not provisioned. Run the \"Provision people\" workflow once it is available."
    SKIPPED+=("${engine}")
    continue
  fi

  if ! metadata="$(aws lambda invoke \
      --function-name "${function_name}" \
      --payload '{"action":"people"}' \
      --cli-binary-format raw-in-base64-out \
      --log-type Tail \
      --region "${REGION}" \
      --output json \
      "${RESPONSE_FILE}" 2>&1)"; then
    echo "ERROR: could not invoke ${function_name}: ${metadata}" >&2
    FAILED+=("${engine}")
    continue
  fi

  log="$(jq -r '.LogResult // empty' <<< "${metadata}" | base64 -d 2>/dev/null || true)"
  [[ -n "${log}" ]] && sed 's/^/    /' <<< "${log}"

  if [[ -n "$(jq -r '.FunctionError // empty' <<< "${metadata}")" ]]; then
    echo "ERROR: ${engine}: $(jq -r '.errorMessage // .' "${RESPONSE_FILE}" 2>/dev/null)" >&2
    FAILED+=("${engine}")
    continue
  fi

  echo "  people: $(jq -r '.people | join(", ") | if . == "" then "(none)" else . end' "${RESPONSE_FILE}")"
  echo "  removed: $(jq -r '.removed | join(", ") | if . == "" then "(none)" else . end' "${RESPONSE_FILE}")"
done

echo
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "Skipped (not running): ${SKIPPED[*]}."
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "ERROR: provisioning people failed on: ${FAILED[*]}." >&2
  exit 1
fi
echo "People are provisioned."
