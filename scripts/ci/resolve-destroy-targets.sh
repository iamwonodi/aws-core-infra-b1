#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# RESOLVE DESTROY TARGETS
#
# Reads an environment's "terraform state list" on stdin and prints what the
# destroy workflow destroys, one Terraform address per line: every top-level
# module and root resource in the state EXCEPT the ones CI signs in with.
#
# Why they are kept: the destroy runs as the core role. Nothing else depends on
# that role or its AdministratorAccess attachment, so a full destroy may delete
# them in its first parallel wave, and every call after that (the rest of the
# destroy, the state write, the lock release) fails. Keeping them also means the
# next apply needs no bootstrap and no new TF_AWS_ROLE_ARN: the role still works.
#
# The kept set is module.github_oidc (the OIDC provider and the core role) and
# module.github_identity, the one module it reads. Destroying a module destroys
# whatever depends on it, so github_identity must stay too.
# scripts/ci/check-bootstrap-closure.py already fails CI if github_oidc ever
# depends on anything else, which is what keeps this list complete.
#
# Data sources are skipped: a destroy has nothing to do to them. An empty
# output means there is nothing left to destroy.
#
# Usage:
#   terraform state list | resolve-destroy-targets.sh
# ==============================================================================

if [[ $# -ne 0 ]]; then
  echo "ERROR: Usage: terraform state list | ${0}" >&2
  exit 1
fi

KEPT_MODULES=("github_oidc" "github_identity")

kept() {
  local name="$1" module
  for module in "${KEPT_MODULES[@]}"; do
    [[ "${name}" == "${module}" ]] && return 0
  done
  return 1
}

declare -A seen=()

while IFS= read -r address || [[ -n "${address}" ]]; do
  address="${address%$'\r'}"
  [[ -z "${address//[[:space:]]/}" ]] && continue

  if [[ "${address}" =~ ^module\.([A-Za-z0-9_-]+) ]]; then
    kept "${BASH_REMATCH[1]}" && continue
    # The whole module, every instance of it: module.x[0] and module.x["k"]
    # both become module.x.
    target="module.${BASH_REMATCH[1]}"
  elif [[ "${address}" =~ ^data\. ]]; then
    continue
  elif [[ "${address}" =~ ^([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+) ]]; then
    target="${BASH_REMATCH[1]}"
  else
    echo "ERROR: unrecognised state address: ${address}" >&2
    exit 1
  fi

  if [[ -z "${seen[${target}]:-}" ]]; then
    seen["${target}"]=1
    echo "${target}"
  fi
done
