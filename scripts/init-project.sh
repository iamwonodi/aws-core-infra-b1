#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# INITIALISE A CLONE OF THIS BLUEPRINT FOR A REAL PROJECT
#
# This repository is a blueprint. Values that differ per project ship as the
# marker CHANGE_ME, and CI refuses to plan while any remain. This script sets
# them, and prepares GitHub to guard each environment. It is safe to re-run: it
# only rewrites the values it owns and PUTs GitHub Environments idempotently.
#
# What it does, per environment (development, staging, production):
#
#   Files   infrastructure/<env>/terraform.tfvars   project_name, aws_region,
#                                                   domain_name, private_domain,
#                                                   database_engines (staging and
#                                                   production, when given)
#           infrastructure/<env>/backend.tf         state bucket and region
#
#   GitHub  Environment <env>        guards the job that changes the live
#                                    environment. Deployments only from main.
#           Environment <env>-plan   guards plan jobs on pull requests.
#           Reviewers (if given) are required on staging and production, both
#           environments. Development has none.
#           Each gets the AWS_REGION variable. TF_AWS_ROLE_ARN is set later, by
#           scripts/bootstrap-environment.sh, once the role exists.
#
# Each environment is a separate AWS account. The state bucket is named
# <project>-<env>-tfstate; the account it lives in is whichever your AWS
# credentials point at when you run bootstrap-environment.sh.
#
# Usage:
#   scripts/init-project.sh --project NAME --region REGION --domain BASE \
#       [--private-domain BASE] [--reviewers login1,login2] [--repo OWNER/REPO] \
#       [--staging-engines LIST] [--production-engines LIST] \
#       [--skip-github] [--dry-run]
#
#   --domain BASE   production serves BASE, staging serves staging.BASE and
#                   development serves dev.BASE (e.g. example.org).
#   --private-domain BASE   same shape, for the VPC-only zone. Defaults to --domain.
#   --staging-engines LIST, --production-engines LIST
#                   the database engines that environment runs, each on its own
#                   instance: comma-separated from postgres and mysql, or "none".
#                   Omitted, the environment's current list is left as it is.
#                   Each engine is billed while it runs, so list only what a
#                   service there uses. (mongodb is refused until its DocumentDB
#                   module exists.) Development's engines come from the database
#                   engines repository instead.
#   --dry-run       show what would change; write and call nothing.
#   --skip-github   only rewrite files.
#
# Needs: bash, sed, jq; gh (authenticated) unless --skip-github or --dry-run.
# GitHub Environment protection rules (required reviewers, branch policies) are
# available on public repositories and on private ones with a GitHub Team or
# Enterprise plan.
# ==============================================================================

REPO_ROOT="${INIT_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENVIRONMENTS=(development staging production)

PROJECT="" REGION="" DOMAIN="" PRIVATE_DOMAIN="" REVIEWERS="" REPO=""
STAGING_ENGINES="" PRODUCTION_ENGINES=""
SKIP_GITHUB=false
DRY_RUN=false

usage() { sed -n '/^# Usage:/,/^# Needs:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | head -n -1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)        PROJECT="${2:-}"; shift 2 ;;
    --region)         REGION="${2:-}"; shift 2 ;;
    --domain)         DOMAIN="${2:-}"; shift 2 ;;
    --private-domain) PRIVATE_DOMAIN="${2:-}"; shift 2 ;;
    --reviewers)      REVIEWERS="${2:-}"; shift 2 ;;
    --repo)           REPO="${2:-}"; shift 2 ;;
    --staging-engines)    STAGING_ENGINES="${2:-}"; [[ -n "${STAGING_ENGINES}" ]] || STAGING_ENGINES="(empty)"; shift 2 ;;
    --production-engines) PRODUCTION_ENGINES="${2:-}"; [[ -n "${PRODUCTION_ENGINES}" ]] || PRODUCTION_ENGINES="(empty)"; shift 2 ;;
    --skip-github)    SKIP_GITHUB=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "ERROR: unknown argument '$1'." >&2; usage >&2; exit 1 ;;
  esac
done

PRIVATE_DOMAIN="${PRIVATE_DOMAIN:-${DOMAIN}}"

# ------------------------------------------------------------------------------
# Validation -- everything is checked before anything is written or called.
# ------------------------------------------------------------------------------
errors=()

[[ "${PROJECT}" =~ ^[a-z][a-z0-9-]{1,14}[a-z0-9]$ ]] \
  || errors+=("--project must be 3-16 lowercase letters, digits or hyphens, starting with a letter.")
[[ "${REGION}" =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] \
  || errors+=("--region must look like af-south-1.")
DOMAIN_PATTERN='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'
[[ "${DOMAIN}" =~ ${DOMAIN_PATTERN} ]] \
  || errors+=("--domain must be a lowercase domain name such as example.org.")
[[ "${PRIVATE_DOMAIN}" =~ ${DOMAIN_PATTERN} ]] \
  || errors+=("--private-domain must be a lowercase domain name such as example.org.")
if [[ -n "${REPO}" && ! "${REPO}" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
  errors+=("--repo must be OWNER/REPOSITORY.")
fi
if [[ -n "${REVIEWERS}" && ! "${REVIEWERS}" =~ ^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)*$ ]]; then
  errors+=("--reviewers must be comma-separated GitHub logins.")
fi

# An engine list: "none", or comma-separated engines this platform can run.
check_engines() {
  local flag="$1" list="$2" engine seen=","
  [[ -z "${list}" || "${list}" == "none" ]] && return 0
  if ! [[ "${list}" =~ ^[a-z]+(,[a-z]+)*$ ]]; then
    errors+=("${flag} must be comma-separated engine names, or none.")
    return 0
  fi
  IFS=',' read -ra engines <<< "${list}"
  for engine in "${engines[@]}"; do
    case "${engine}" in
      postgres|mysql) ;;
      mongodb) errors+=("${flag}: mongodb runs on Amazon DocumentDB, and its module does not exist yet.") ;;
      *) errors+=("${flag}: '${engine}' is not an engine; use postgres and mysql.") ;;
    esac
    [[ "${seen}" == *",${engine},"* ]] && errors+=("${flag} lists ${engine} more than once.")
    seen+="${engine},"
  done
}
check_engines --staging-engines "${STAGING_ENGINES}"
check_engines --production-engines "${PRODUCTION_ENGINES}"

if [[ ${#errors[@]} -gt 0 ]]; then
  printf 'ERROR: %s\n' "${errors[@]}" >&2
  exit 1
fi

for command in sed jq; do
  command -v "${command}" >/dev/null 2>&1 || { echo "ERROR: required command not found: ${command}" >&2; exit 1; }
done

if [[ "${SKIP_GITHUB}" != "true" && "${DRY_RUN}" != "true" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required (or pass --skip-github)." >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not authenticated. Run: gh auth login" >&2; exit 1; }
fi

if [[ -z "${REPO}" && "${SKIP_GITHUB}" != "true" ]]; then
  REMOTE_URL="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
  [[ -n "${REMOTE_URL}" ]] || { echo "ERROR: no origin remote; pass --repo OWNER/REPOSITORY." >&2; exit 1; }
  REPO="$(sed -E 's#^(https?://[^/]+/|git@[^:]+:|ssh://[^/]+/)##; s#\.git$##; s#/$##' <<< "${REMOTE_URL}")"
fi

domain_for() {
  case "$1" in
    development) echo "dev.$2" ;;
    staging)     echo "staging.$2" ;;
    production)  echo "$2" ;;
  esac
}

# ------------------------------------------------------------------------------
# Files
# ------------------------------------------------------------------------------

# Replaces the quoted value on the line that sets KEY, keeping alignment and any
# trailing comment. Writes through a temporary file (sed -i differs between GNU
# and BSD).
set_value() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"

  if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=" "${file}"; then
    rm -f "${tmp}"
    echo "ERROR: ${file} has no '${key} =' line to set." >&2
    exit 1
  fi

  sed -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1\"${value}\"|" "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

# "postgres,mysql" -> ["postgres", "mysql"]; "none" -> []
engines_hcl() {
  local list="$1"
  [[ "${list}" == "none" ]] && { echo "[]"; return; }
  echo "[\"${list//,/\", \"}\"]"
}

# Replaces the whole value on the line that sets the list, keeping any trailing
# comment.
set_list() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp)"

  if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\[" "${file}"; then
    rm -f "${tmp}"
    echo "ERROR: ${file} has no '${key} = [...]' line to set." >&2
    exit 1
  fi

  sed -E "s|^([[:space:]]*${key}[[:space:]]*=[[:space:]]*)\[[^]]*\]|\1${value}|" "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
}

engines_for() {
  case "$1" in
    staging)    echo "${STAGING_ENGINES}" ;;
    production) echo "${PRODUCTION_ENGINES}" ;;
  esac
}

update_files() {
  local env dir engines
  for env in "${ENVIRONMENTS[@]}"; do
    dir="${REPO_ROOT}/infrastructure/${env}"
    [[ -f "${dir}/terraform.tfvars" && -f "${dir}/backend.tf" ]] \
      || { echo "ERROR: ${dir} is missing terraform.tfvars or backend.tf." >&2; exit 1; }

    engines="$(engines_for "${env}")"
    echo "  ${env}: project=${PROJECT} region=${REGION} domain=$(domain_for "${env}" "${DOMAIN}") state=${PROJECT}-${env}-tfstate${engines:+ database_engines=${engines}}"

    [[ "${DRY_RUN}" == "true" ]] && continue

    set_value "${dir}/terraform.tfvars" project_name "${PROJECT}"
    set_value "${dir}/terraform.tfvars" aws_region "${REGION}"
    set_value "${dir}/terraform.tfvars" domain_name "$(domain_for "${env}" "${DOMAIN}")"
    set_value "${dir}/terraform.tfvars" private_domain "$(domain_for "${env}" "${PRIVATE_DOMAIN}")"
    set_value "${dir}/backend.tf" bucket "${PROJECT}-${env}-tfstate"
    set_value "${dir}/backend.tf" region "${REGION}"

    if [[ -n "${engines}" ]]; then
      set_list "${dir}/terraform.tfvars" database_engines "$(engines_hcl "${engines}")"
    fi
  done
}

# ------------------------------------------------------------------------------
# GitHub Environments
# ------------------------------------------------------------------------------

gh_call() {
  # gh_call <description> <gh args...>   (stdin is passed through)
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "  [dry run] gh $2 ${*:3}"
    # Drain a piped body so the writer does not get SIGPIPE; never read a terminal.
    if [[ "$*" == *"--input -"* ]]; then cat > /dev/null; fi
    return 0
  fi
  gh "${@:2}"
}

reviewer_json() {
  # Prints the reviewers array for the given logins, resolving each to its ID.
  local login id out="[]"
  IFS=',' read -ra logins <<< "${REVIEWERS}"
  for login in "${logins[@]}"; do
    if [[ "${DRY_RUN}" == "true" ]]; then
      id=0
    else
      id="$(gh api "users/${login}" --jq '.id')" \
        || { echo "ERROR: could not find GitHub user '${login}'." >&2; exit 1; }
    fi
    out="$(jq -c --argjson id "${id}" '. + [{type: "User", id: $id}]' <<< "${out}")"
  done
  echo "${out}"
}

configure_environment() {
  local name="$1" restrict_to_main="$2" reviewers="$3" body

  body="$(jq -cn \
    --argjson reviewers "${reviewers}" \
    --argjson restrict "${restrict_to_main}" \
    '{reviewers: $reviewers}
     + (if $restrict then {deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}
        else {deployment_branch_policy: null} end)')"

  echo "  environment ${name}: reviewers=$(jq 'length' <<< "${reviewers}") main-only=${restrict_to_main}"

  printf '%s' "${body}" | gh_call "environment ${name}" api -X PUT "repos/${REPO}/environments/${name}" --input -

  if [[ "${restrict_to_main}" == "true" ]]; then
    # 422 means the policy already exists, which is the state we want.
    printf '%s' '{"name":"main","type":"branch"}' \
      | gh_call "branch policy ${name}" api -X POST "repos/${REPO}/environments/${name}/deployment-branch-policies" --input - 2>/dev/null || true
  fi

  gh_call "AWS_REGION ${name}" variable set AWS_REGION --env "${name}" --body "${REGION}" >/dev/null
}

configure_github() {
  local env reviewers
  local no_reviewers="[]"
  local with_reviewers="[]"

  [[ -n "${REVIEWERS}" ]] && with_reviewers="$(reviewer_json)"

  for env in "${ENVIRONMENTS[@]}"; do
    reviewers="${no_reviewers}"
    if [[ "${env}" != "development" ]]; then
      reviewers="${with_reviewers}"
      if [[ -z "${REVIEWERS}" ]]; then
        echo "  WARNING: no --reviewers given, so ${env} will have no required reviewer."
      fi
    fi

    configure_environment "${env}" true "${reviewers}"
    configure_environment "${env}-plan" false "${reviewers}"
  done
}

# ------------------------------------------------------------------------------
echo "Project files"
update_files

if [[ "${SKIP_GITHUB}" == "true" ]]; then
  echo "GitHub Environments: skipped (--skip-github)."
else
  echo "GitHub Environments in ${REPO}"
  configure_github
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo
  echo "Dry run: nothing was written and GitHub was not called."
  exit 0
fi

echo
echo "Checking that no placeholder remains."
bash "${REPO_ROOT}/scripts/ci/check-placeholders.sh" \
  "${REPO_ROOT}/infrastructure/development" \
  "${REPO_ROOT}/infrastructure/staging" \
  "${REPO_ROOT}/infrastructure/production"

cat <<NEXT

Done. Next steps, per environment (each is its own AWS account):

  1. Point your AWS credentials at that environment's account
     (for example: export AWS_PROFILE=<profile-for-development>).
  2. scripts/bootstrap-environment.sh <environment> --set-secrets
     creates the state bucket, applies the OIDC role, and sets TF_AWS_ROLE_ARN
     on both GitHub Environments.
  3. Commit these changes and open a pull request. CI plans it.

See docs/first-apply.md for the full walkthrough.
NEXT
