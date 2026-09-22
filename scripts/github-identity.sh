#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PRINT THE TERRAFORM VARIABLES THAT IDENTIFY THIS GITHUB REPOSITORY
#
# The core role's trust policy needs this repository's name and numeric IDs.
# They are never committed -- this repository is a blueprint that many projects
# clone -- so whoever runs Terraform supplies them. CI gets them from the GitHub
# context; on a workstation, run this script.
#
# Usage:
#   scripts/github-identity.sh [--repo OWNER/REPO] [--shell bash|powershell]
#
# Load them into your shell:
#   bash / Git Bash:   eval "$(scripts/github-identity.sh)"
#   PowerShell:        scripts/github-identity.sh --shell powershell | Invoke-Expression
#
# The repository defaults to the one named by the "origin" remote. Needs gh,
# authenticated (gh auth login).
#
# GitHub uses the immutable OIDC subject format (which embeds these IDs) for
# repositories created, renamed or transferred on or after 15 July 2026. For an
# older repository, also set TF_VAR_oidc_subject_format=classic; this script
# says so when the repository predates that date.
# ==============================================================================

REPO=""
SHELL_KIND="bash"
IMMUTABLE_CUTOFF="2026-07-15"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)  REPO="${2:-}"; shift 2 ;;
    --shell) SHELL_KIND="${2:-}"; shift 2 ;;
    *)
      echo "ERROR: unknown argument '$1'. Usage: ${0} [--repo OWNER/REPO] [--shell bash|powershell]" >&2
      exit 1
      ;;
  esac
done

case "${SHELL_KIND}" in
  bash|powershell) ;;
  *)
    echo "ERROR: --shell must be bash or powershell." >&2
    exit 1
    ;;
esac

for command in gh jq; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: required command not found: ${command}" >&2
    exit 1
  fi
done

if [[ -z "${REPO}" ]]; then
  REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"

  if [[ -z "${REMOTE_URL}" ]]; then
    echo "ERROR: no origin remote to read the repository from. Pass --repo OWNER/REPO." >&2
    exit 1
  fi

  # https://github.com/OWNER/REPO(.git)  or  git@github.com:OWNER/REPO(.git)
  REPO="$(sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#\.git$##; s#/$##' <<< "${REMOTE_URL}")"
fi

if ! [[ "${REPO}" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: '${REPO}' is not in OWNER/REPOSITORY form." >&2
  exit 1
fi

if ! DETAILS="$(gh api "repos/${REPO}" 2>/dev/null)"; then
  echo "ERROR: could not read ${REPO} from GitHub. Run 'gh auth login' and check the name." >&2
  exit 1
fi

OWNER_ID="$(jq -r '.owner.id // empty' <<< "${DETAILS}")"
REPOSITORY_ID="$(jq -r '.id // empty' <<< "${DETAILS}")"
CREATED_AT="$(jq -r '.created_at // empty' <<< "${DETAILS}")"
FULL_NAME="$(jq -r '.full_name // empty' <<< "${DETAILS}")"

if [[ -z "${OWNER_ID}" || -z "${REPOSITORY_ID}" ]]; then
  echo "ERROR: GitHub returned no owner or repository ID for ${REPO}." >&2
  exit 1
fi

# GitHub reports the canonical name, which is what appears in the token subject.
REPO="${FULL_NAME:-${REPO}}"

if [[ "${SHELL_KIND}" == "powershell" ]]; then
  printf '$env:TF_VAR_github_repository = "%s"\n' "${REPO}"
  printf '$env:TF_VAR_github_owner_id = "%s"\n' "${OWNER_ID}"
  printf '$env:TF_VAR_github_repository_id = "%s"\n' "${REPOSITORY_ID}"
else
  printf 'export TF_VAR_github_repository=%q\n' "${REPO}"
  printf 'export TF_VAR_github_owner_id=%q\n' "${OWNER_ID}"
  printf 'export TF_VAR_github_repository_id=%q\n' "${REPOSITORY_ID}"
fi

if [[ -n "${CREATED_AT}" && "${CREATED_AT%%T*}" < "${IMMUTABLE_CUTOFF}" ]]; then
  echo "# NOTE: ${REPO} was created on ${CREATED_AT%%T*}, before ${IMMUTABLE_CUTOFF}. If GitHub still emits name-only" >&2
  echo "#       OIDC subjects for it, also set TF_VAR_oidc_subject_format=classic." >&2
fi
