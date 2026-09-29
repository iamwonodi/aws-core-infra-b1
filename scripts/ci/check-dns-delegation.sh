#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# CHECK DNS DELEGATION
#
# Run by terraform-apply.yml just before "terraform apply". Fails when public
# DNS does not send the environment's domain to the name servers of its
# delegation set (module.dns_delegation), so the apply stops at once instead
# of waiting up to 75 minutes on certificates that can never validate, and
# then losing its one-hour credentials part-way.
#
# The expected four come from the plan being applied: its prior state holds
# the delegation set. The domain comes from the plan's variables. Public DNS is
# asked through each resolver in DNS_RESOLVERS; the check passes when any one
# of them already returns exactly the four (a resolver still caching the old
# answer is not a reason to stop).
#
# Skipped, with a note, when the state has no delegation set yet: the very
# first apply, or an environment on a blueprint from before it existed.
# A manual apply can also skip it (terraform-apply.yml, skip_dns_check), for a
# DNS provider outage that says nothing about the delegation itself.
#
# Usage:
#   check-dns-delegation.sh <environment-dir> <plan-file>
#   (the plan file's path is relative to the environment directory)
#
# Environment (for tests): TERRAFORM, DIG, DNS_RESOLVERS.
# ==============================================================================

if [[ $# -ne 2 ]]; then
  echo "ERROR: Usage: ${0} <environment-dir> <plan-file>" >&2
  exit 1
fi

ENV_DIR="$1"
PLAN_FILE="$2"
TERRAFORM="${TERRAFORM:-terraform}"
DIG="${DIG:-dig}"
DNS_RESOLVERS="${DNS_RESOLVERS:-8.8.8.8 1.1.1.1}"

for command in jq "${DIG}" "${TERRAFORM}"; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: Required command is not installed: ${command}" >&2
    exit 1
  fi
done

# Lower case, no trailing dot, no carriage return, one per line, sorted.
normalise() {
  tr -d '\r' | tr '[:upper:]' '[:lower:]' | sed 's/\.$//' | grep -v '^[[:space:]]*$' | sort -u || true
}

PLAN_JSON="$("${TERRAFORM}" -chdir="${ENV_DIR}" show -json "${PLAN_FILE}")"

DOMAIN="$(jq -r '.variables.domain_name.value // empty' <<< "${PLAN_JSON}")"
EXPECTED="$(jq -r '
  [ .prior_state.values.root_module.child_modules[]?
    | select(.address == "module.dns_delegation")
    | .resources[]?
    | select(.type == "aws_route53_delegation_set")
    | .values.name_servers[]? ]
  | .[]' <<< "${PLAN_JSON}" | normalise)"

if [[ -z "${EXPECTED}" ]]; then
  echo "Skipping the DNS delegation check: the state has no delegation set yet"
  echo "(the first apply, or an environment on a blueprint from before it existed)."
  exit 0
fi

if [[ -z "${DOMAIN}" ]]; then
  echo "ERROR: the plan has no domain_name variable to check." >&2
  exit 1
fi

REPORT=""
for resolver in ${DNS_RESOLVERS}; do
  ACTUAL="$("${DIG}" +short NS "${DOMAIN}" "@${resolver}" 2>/dev/null | normalise)"
  if [[ "${ACTUAL}" == "${EXPECTED}" ]]; then
    echo "ok   ${DOMAIN} is delegated to its delegation set (as ${resolver} sees it):"
    sed 's/^/       /' <<< "${EXPECTED}"
    exit 0
  fi
  REPORT+="  ${resolver} returns:"$'\n'
  if [[ -z "${ACTUAL}" ]]; then
    REPORT+="    no NS records"$'\n'
  else
    REPORT+="$(sed 's/^/    /' <<< "${ACTUAL}")"$'\n'
  fi
done

{
  echo "ERROR: ${DOMAIN} is not delegated to this environment's name servers."
  echo "The certificates could never validate, so the apply stops here."
  echo ""
  echo "Where the base domain's DNS is managed, its NS records for this name must be exactly:"
  sed 's/^/    /' <<< "${EXPECTED}"
  echo ""
  echo "Public DNS instead:"
  printf '%s' "${REPORT}"
  echo ""
  echo "Update the records, wait for the old ones' TTL, and run the apply again."
  echo "(A DNS provider outage: re-run it manually with skip_dns_check.)"
} >&2
exit 1
