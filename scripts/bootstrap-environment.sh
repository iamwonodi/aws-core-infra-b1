#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# BOOTSTRAP ENVIRONMENT
#
# Complete one-time setup for a brand new environment/AWS account, run
# locally by the platform team:
#
#   1. Initialize and push THIS repository (core-infra) to GitHub, if that
#      hasn't already happened.
#   2. Create and configure the state bucket -- fully decoupled from
#      Terraform; see ensure_state_bucket.
#   3. Run terraform init against that now-ready backend.
#   4. Run the FIRST real "terraform apply" for this environment, targeting
#      ONLY module.github_oidc -- this is what unblocks CI's own
#      authentication. Everything else this configuration manages is left
#      for the first real PR to create through the normal reviewed
#      pipeline, not swept into this one unreviewed local apply.
#   5. Read the resulting core role ARN back out via "terraform output".
#   6. Optionally (only with --set-secrets): sync local-config/ values as
#      this repo's own GitHub Environment variables/secrets, and set the
#      core role ARN as this repo's own TF_AWS_ROLE_ARN secret.
#
# WHAT THIS SCRIPT DOES NOT DO, ON PURPOSE: it does not reach into other
# (service) repositories to set their secrets. An earlier version did --
# that assumed the person running this script has admin access to every
# service repo that will ever exist, which is not a safe assumption in a
# real multi-team org, and not a privilege the platform team should need.
# Each service repo sets its OWN secret using its OWN permissions, via
# scripts/bootstrap-service-repo.sh (copied into that repo). This script's
# only job for OTHER repos is making sure terraform-apply.yml keeps
# role-arns/<environment>.json up to date -- the file each service repo's
# own script reads from.
#
# THIS IS A MANUAL, LOCAL-ONLY UTILITY. It is intentionally NOT part of
# any GitHub Actions workflow, and the apply step intentionally does NOT
# use -auto-approve -- this is the one apply in the whole pipeline nobody
# else reviews, and it grants core_role_policy_arns (AdministratorAccess,
# as currently configured). Read the plan before confirming it.
#
# Usage:
#   scripts/bootstrap-environment.sh <development|staging|production|all> [--set-secrets]
#
#   --set-secrets   After a successful apply: read local-config/<env>.vars.env
#                   and local-config/<env>.secrets.env (see
#                   local-config/vars.env.example / secrets.env.example for
#                   the expected keys) and push each entry as this repo's
#                   own Environment variable/secret; then also set
#                   TF_AWS_ROLE_ARN from the apply's own output. Requires
#                   `gh`, already authenticated. Without this flag, values
#                   are only printed for you to set by hand.
#
# Requires AWS credentials for the TARGET environment's account to
# already be active in your shell -- this script does not assume or
# switch accounts for you. With "all", it pauses between environments so
# you can switch accounts before continuing.
# ==============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The one place the Terraform version is chosen. CI reads the same file.
EXPECTED_TF_VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/.terraform-version")"

VALID_ENVIRONMENTS=("development" "staging" "production")

# Edit before running for the first time -- the name to create this
# repository under on GitHub. A bare name creates it under your
# authenticated account/default org; "owner/name" creates it under a
# specific owner.
CORE_INFRA_REPO_NAME="$(basename "${REPO_ROOT}")"

# ==============================================================================
# ARGUMENT VALIDATION
# ==============================================================================

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "ERROR: Usage: ${0} <development|staging|production|all> [--set-secrets]" >&2
  exit 1
fi

REQUESTED="$1"
SET_SECRETS=false

if [[ $# -eq 2 ]]; then
  if [[ "$2" != "--set-secrets" ]]; then
    echo "ERROR: Unknown flag '$2'. Only --set-secrets is supported." >&2
    exit 1
  fi
  SET_SECRETS=true
fi

ENABLED_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/ci/enabled-environments.sh"

if [[ "${REQUESTED}" == "all" ]]; then
  # Every environment this project runs (environments.json).
  mapfile -t TARGET_ENVIRONMENTS < <(bash "${ENABLED_SCRIPT}" | jq -r '.[]')
  [[ ${#TARGET_ENVIRONMENTS[@]} -gt 0 ]] || exit 1
else
  MATCHED=false
  for ENV in "${VALID_ENVIRONMENTS[@]}"; do
    if [[ "${ENV}" == "${REQUESTED}" ]]; then
      MATCHED=true
      break
    fi
  done
  if [[ "${MATCHED}" != "true" ]]; then
    echo "ERROR: Unknown environment '${REQUESTED}'." >&2
    echo "       Must be one of: development, staging, production, all" >&2
    exit 1
  fi
  # Only an environment this project runs is set up.
  bash "${ENABLED_SCRIPT}" --check "${REQUESTED}" || exit 1
  TARGET_ENVIRONMENTS=("${REQUESTED}")
fi

REQUIRED_COMMANDS=(aws terraform jq git)
if [[ "${SET_SECRETS}" == "true" || -z "${TF_VAR_github_repository:-}" ]]; then
  # gh sets the environment secrets, and reads this repository's IDs when
  # TF_VAR_github_repository / _owner_id / _repository_id are not already set.
  REQUIRED_COMMANDS+=(gh)
fi

for command in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "${command}" >/dev/null 2>&1; then
    echo "ERROR: Required command is not installed: ${command}" >&2
    exit 1
  fi
done

if [[ "${SET_SECRETS}" == "true" ]] && ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: --set-secrets was given, but 'gh' is not authenticated." >&2
  echo "       Run 'gh auth login' first, then try again." >&2
  exit 1
fi

# ==============================================================================
# INITIALIZE AND PUSH THIS REPOSITORY, IF NOT ALREADY DONE
#
# Idempotent -- if this is already a git repo with a remote, this is
# skipped entirely. Only attempted when --set-secrets is given, since
# creating the GitHub repo needs `gh` regardless of whether you also want
# secrets synced -- if you're not using --set-secrets, do this step by
# hand (or run with --set-secrets once just to get the repo created).
# ==============================================================================

ensure_repo_pushed() {
  echo "============================================================"
  echo "Repository setup"
  echo "============================================================"

  if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && git -C "${REPO_ROOT}" remote get-url origin >/dev/null 2>&1; then
    echo "Already a git repository with a remote configured. Skipping init/push."
    return 0
  fi

  if ! git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Initializing local git repository."
    git -C "${REPO_ROOT}" init -b main
  fi

  if [[ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]]; then
    git -C "${REPO_ROOT}" add .
    if ! git -C "${REPO_ROOT}" diff --cached --quiet 2>/dev/null; then
      git -C "${REPO_ROOT}" commit -m "Initial commit"
    fi
  fi

  echo "Creating and pushing GitHub repository: ${CORE_INFRA_REPO_NAME}"
  (cd "${REPO_ROOT}" && gh repo create "${CORE_INFRA_REPO_NAME}" --private --source=. --remote=origin --push)
}

if [[ "${SET_SECRETS}" == "true" ]]; then
  ensure_repo_pushed
  echo ""
fi

# ==============================================================================
# CHECK LOCAL TERRAFORM VERSION AGAINST WHAT CI USES
# ==============================================================================

check_terraform_version() {
  local LOCAL_VERSION
  LOCAL_VERSION="$(terraform version -json | jq -r '.terraform_version')"

  if [[ "${LOCAL_VERSION}" != "${EXPECTED_TF_VERSION}" ]]; then
    echo "WARNING: Local Terraform is v${LOCAL_VERSION}, but CI is pinned to" >&2
    echo "         v${EXPECTED_TF_VERSION}. Consider installing v${EXPECTED_TF_VERSION}" >&2
    echo "         locally (e.g. via tfenv) before continuing." >&2
    echo "" >&2
  fi
}

check_terraform_version

# ==============================================================================
# RESOLVE THE ACTUAL BUCKET NAME FROM backend.tf
# ==============================================================================

resolve_bucket_name() {
  local BACKEND_FILE="$1"
  local BUCKET_NAME

  BUCKET_NAME="$(
    sed -n 's/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${BACKEND_FILE}" \
      | head -n 1
  )"

  if [[ -z "${BUCKET_NAME}" ]]; then
    echo "ERROR: Could not find a 'bucket = \"...\"' line in ${BACKEND_FILE}." >&2
    exit 1
  fi

  echo "${BUCKET_NAME}"
}

# ==============================================================================
# RESOLVE THE AWS REGION
# ==============================================================================

resolve_region() {
  local TFVARS="${1:-}"
  local REGION=""

  # The environment's own terraform.tfvars is the source of truth: the state
  # bucket belongs in the region the environment is deployed to, whatever the
  # shell happens to have set.
  if [[ -n "${TFVARS}" && -f "${TFVARS}" ]]; then
    REGION="$(sed -n 's/^[[:space:]]*aws_region[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TFVARS}" | head -n 1)"
  fi

  if [[ -z "${REGION}" ]]; then
    REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  fi

  if [[ -z "${REGION}" ]]; then
    REGION="$(aws configure get region 2>/dev/null || true)"
  fi

  if [[ -z "${REGION}" ]]; then
    echo "ERROR: Could not determine an AWS region." >&2
    echo "       Set AWS_REGION or AWS_DEFAULT_REGION, or configure a default" >&2
    echo "       region for your active AWS CLI profile, then try again." >&2
    exit 1
  fi

  echo "${REGION}"
}

# ==============================================================================
# ENSURE THE STATE BUCKET EXISTS AND IS CORRECTLY CONFIGURED
#
# Fully decoupled from Terraform, idempotent, hardened with an HTTPS-only
# policy. See this repo's README for the full reasoning.
# ==============================================================================

ensure_state_bucket() {
  local BUCKET_NAME="$1"
  local REGION="$2"

  if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
    echo "State bucket already exists: ${BUCKET_NAME}"
  else
    echo "Creating state bucket: ${BUCKET_NAME} (region: ${REGION})"

    if [[ "${REGION}" == "us-east-1" ]]; then
      aws s3api create-bucket \
        --bucket "${BUCKET_NAME}" \
        --region "${REGION}"
    else
      aws s3api create-bucket \
        --bucket "${BUCKET_NAME}" \
        --region "${REGION}" \
        --create-bucket-configuration "LocationConstraint=${REGION}"
    fi
  fi

  echo "Applying baseline configuration (idempotent; safe to re-run)."

  aws s3api put-bucket-versioning \
    --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  aws s3api put-public-access-block \
    --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  aws s3api put-bucket-ownership-controls \
    --bucket "${BUCKET_NAME}" \
    --ownership-controls '{"Rules":[{"ObjectOwnership":"BucketOwnerEnforced"}]}'

  echo "Enforcing HTTPS-only access via bucket policy."

  local POLICY
  POLICY="$(
    cat <<POLICY_EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${BUCKET_NAME}",
        "arn:aws:s3:::${BUCKET_NAME}/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
POLICY_EOF
  )"

  aws s3api put-bucket-policy --bucket "${BUCKET_NAME}" --policy "${POLICY}"

  echo "State bucket ready: ${BUCKET_NAME}"
}

# ==============================================================================
# SYNC LOCAL CONFIG FILES TO GITHUB
#
# Reads local-config/<environment>.vars.env and .secrets.env (dotenv-style:
# KEY=value per line, '#' comments and blank lines ignored, surrounding
# quotes stripped) and pushes each entry as this repo's own Environment
# variable or secret. Both files are gitignored -- see local-config/
# *.env.example for the committed templates showing expected keys.
#
# Silently does nothing for a file that doesn't exist, rather than
# erroring -- not every environment necessarily needs every optional key
# set immediately.
# ==============================================================================

sync_local_config_file() {
  local FILE="$1"
  local ENV_NAME="$2"
  local GH_SUBCOMMAND="$3" # "secret" or "variable"

  if [[ ! -f "${FILE}" ]]; then
    echo "  (no ${FILE}, skipping)"
    return 0
  fi

  while IFS='=' read -r KEY VALUE; do
    [[ -z "${KEY}" || "${KEY}" == \#* ]] && continue
    VALUE="${VALUE%\"}"
    VALUE="${VALUE#\"}"
    # A blank line means "use the default": nothing to set.
    if [[ -z "${VALUE}" ]]; then
      echo "  ${KEY} is blank, skipping"
      continue
    fi

    echo "  Setting ${GH_SUBCOMMAND} ${KEY} for ${ENV_NAME}"
    gh "${GH_SUBCOMMAND}" set "${KEY}" --body "${VALUE}" --env "${ENV_NAME}"
  done < "${FILE}"
}

sync_local_config() {
  local ENV_NAME="$1"

  echo "Syncing local-config/ values as this repository's own Environment vars/secrets."
  # Both GitHub Environments: <env> (the job that changes the live environment)
  # and <env>-plan (plan jobs). Environment secrets and variables are not shared
  # between them, and each job reads its own environment's.
  local TARGET_ENV
  for TARGET_ENV in "${ENV_NAME}" "${ENV_NAME}-plan"; do
    sync_local_config_file "${REPO_ROOT}/local-config/${ENV_NAME}.vars.env" "${TARGET_ENV}" "variable"
    sync_local_config_file "${REPO_ROOT}/local-config/${ENV_NAME}.secrets.env" "${TARGET_ENV}" "secret"
  done
}

# ==============================================================================
# BOOTSTRAP A SINGLE ENVIRONMENT
# ==============================================================================

bootstrap_environment() {
  local ENV_NAME="$1"
  local ENV_DIR="${REPO_ROOT}/infrastructure/${ENV_NAME}"
  local BACKEND_FILE="${ENV_DIR}/backend.tf"

  if [[ ! -d "${ENV_DIR}" ]]; then
    echo "ERROR: No Terraform directory found for '${ENV_NAME}': ${ENV_DIR}" >&2
    exit 1
  fi

  if [[ ! -f "${BACKEND_FILE}" ]]; then
    echo "ERROR: No backend.tf found for '${ENV_NAME}': ${BACKEND_FILE}" >&2
    exit 1
  fi

  local BUCKET_NAME REGION
  BUCKET_NAME="$(resolve_bucket_name "${BACKEND_FILE}")"
  REGION="$(resolve_region "${ENV_DIR}/terraform.tfvars")"

  echo "============================================================"
  echo "Bootstrapping environment: ${ENV_NAME^^}"
  echo "Working directory: ${ENV_DIR}"
  echo "State bucket:       ${BUCKET_NAME}"
  echo "Region:             ${REGION}"
  echo "============================================================"
  echo "Confirm your local AWS credentials are for the ${ENV_NAME^^} account:"
  aws sts get-caller-identity
  echo "============================================================"

  ensure_state_bucket "${BUCKET_NAME}" "${REGION}"

  (
    cd "${ENV_DIR}"

    echo "Running terraform init against the now-ready backend."
    terraform init -input=false

    echo ""
    echo "Running terraform apply, targeting module.github_oidc only. Review the"
    echo "plan carefully before confirming -- this is the one apply here that no"
    echo "one else will review."
    echo ""

    # The trust policy needs this repository's name and numeric IDs, which are
    # never committed. Read them from GitHub unless already provided.
    if [[ -z "${TF_VAR_github_repository:-}" ]]; then
      echo "Reading this repository's identity from GitHub."
      eval "$("${REPO_ROOT}/scripts/github-identity.sh")"
    fi

    # -target is safe here only because module.github_oidc depends on nothing
    # but variables and the pure github_identity module;
    # scripts/ci/check-bootstrap-closure.py enforces that.
    terraform apply -target=module.github_oidc

    echo ""
    echo "Reading the core role ARN from the apply output."

    local OUTPUTS_JSON CORE_ARN
    OUTPUTS_JSON="$(terraform output -json)"
    CORE_ARN="$(jq -r '.core_deploy_role_arn.value // empty' <<< "${OUTPUTS_JSON}")"

    echo ""
    echo "core_deploy_role_arn:"
    echo "  ${CORE_ARN:-<none -- create_core_role is false for this config>}"

    if [[ "${SET_SECRETS}" == "true" ]]; then
      echo ""
      sync_local_config "${ENV_NAME}"

      if [[ -n "${CORE_ARN}" && "${CORE_ARN}" != "null" ]]; then
        local TARGET_ENV
        for TARGET_ENV in "${ENV_NAME}" "${ENV_NAME}-plan"; do
          echo "  Setting secret TF_AWS_ROLE_ARN for ${TARGET_ENV}"
          if ! gh secret set TF_AWS_ROLE_ARN --body "${CORE_ARN}" --env "${TARGET_ENV}"; then
            echo "ERROR: could not set the secret on GitHub Environment ${TARGET_ENV}." >&2
            echo "       Create the environments first: scripts/init-project.sh" >&2
            exit 1
          fi
        done
      fi
    else
      echo ""
      echo "Not syncing to GitHub (run with --set-secrets to do that automatically,"
      echo "or set local-config/ values and TF_AWS_ROLE_ARN by hand)."
    fi
  )

  echo ""
  echo "Environment ready: ${ENV_NAME}"
  echo ""
}

# ==============================================================================
# RUN
# ==============================================================================

FIRST=true
for ENV_NAME in "${TARGET_ENVIRONMENTS[@]}"; do
  if [[ "${FIRST}" != "true" ]]; then
    echo ""
    echo "Next: ${ENV_NAME^^}. Switch your local AWS credentials to that account now."
    read -r -p "Press Enter once ready (or Ctrl-C to stop here): " _
  fi
  FIRST=false

  bootstrap_environment "${ENV_NAME}"
done

echo "============================================================"
echo "Environment bootstrap complete for: ${TARGET_ENVIRONMENTS[*]}"
if [[ "${SET_SECRETS}" != "true" ]]; then
  echo "Remember to set local-config/ values and TF_AWS_ROLE_ARN by hand if you"
  echo "haven't already (or re-run with --set-secrets)."
fi
echo "From here on, changes to this environment go through the normal"
echo "PR -> terraform-plan.yml -> merge -> terraform-apply.yml pipeline."
echo "New service repos onboard via their own scripts/bootstrap-service-repo.sh."
echo "============================================================"