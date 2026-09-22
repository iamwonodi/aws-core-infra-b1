#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# PUBLISH AN ENVIRONMENT'S ROLE ARNs TO THE platform-outputs BRANCH
#
# After an apply, the role ARNs (which service repositories need to know) are
# written to role-arns/<environment>.json on a dedicated, unprotected branch
# rather than on main. main stays pull-request-only -- a workflow pushing to it
# would need a branch-protection bypass, and would fill its history with bot
# commits -- while the branch holds nothing but these generated files.
#
# Service repository bootstrap scripts read the file with:
#   gh api "repos/OWNER/REPO/contents/role-arns/<environment>.json?ref=platform-outputs"
#
# The branch is created on first use as an orphan (no shared history with main).
# Publishing is skipped when the file is unchanged. Concurrent applies for
# different environments retry after rebasing onto each other's commits.
#
# Runs in a temporary worktree, so the caller's working tree and checked-out
# commit are never disturbed.
#
# Usage: publish-role-arns.sh <environment> <role-arns-json-file>
#
# Environment (all optional):
#   PUBLISH_BRANCH        branch to publish to           (default platform-outputs)
#   PUBLISH_REMOTE        remote to push to              (default origin)
#   PUBLISH_MAX_ATTEMPTS  push attempts before giving up (default 5)
# ==============================================================================

if [[ $# -ne 2 ]]; then
  echo "ERROR: Usage: ${0} <environment> <role-arns-json-file>" >&2
  exit 1
fi

ENVIRONMENT="$1"
SOURCE_FILE="$2"

BRANCH="${PUBLISH_BRANCH:-platform-outputs}"
REMOTE="${PUBLISH_REMOTE:-origin}"
MAX_ATTEMPTS="${PUBLISH_MAX_ATTEMPTS:-5}"

case "${ENVIRONMENT}" in
  development|staging|production) ;;
  *)
    echo "ERROR: unknown environment '${ENVIRONMENT}'." >&2
    exit 1
    ;;
esac

if [[ ! -s "${SOURCE_FILE}" ]] || ! jq -e . "${SOURCE_FILE}" >/dev/null 2>&1; then
  echo "ERROR: ${SOURCE_FILE} is missing, empty or not valid JSON." >&2
  exit 1
fi

TARGET="role-arns/${ENVIRONMENT}.json"

# A named tracking ref, not FETCH_HEAD: FETCH_HEAD is shared by every fetch in
# the clone and is overwritten by the next one.
TRACKING_REF="refs/remotes/${REMOTE}/${BRANCH}"
WORKTREE="$(mktemp -d)"
SOURCE_ABS="$(cd "$(dirname "${SOURCE_FILE}")" && pwd)/$(basename "${SOURCE_FILE}")"

cleanup() {
  git worktree remove --force "${WORKTREE}" >/dev/null 2>&1 || rm -rf "${WORKTREE}"
}
trap cleanup EXIT

git config --get user.name >/dev/null 2>&1 || git config user.name "github-actions[bot]"
git config --get user.email >/dev/null 2>&1 || git config user.email "github-actions[bot]@users.noreply.github.com"

remote_has_branch() {
  git ls-remote --exit-code --heads "${REMOTE}" "${BRANCH}" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Check the branch out into the temporary worktree
# ------------------------------------------------------------------------------
if remote_has_branch; then
  git fetch --quiet "${REMOTE}" "+refs/heads/${BRANCH}:${TRACKING_REF}"
  git worktree add --quiet --detach "${WORKTREE}" "${TRACKING_REF}"
else
  echo "Branch ${BRANCH} does not exist yet; creating it as an orphan."
  git worktree add --quiet --detach "${WORKTREE}" HEAD
  git -C "${WORKTREE}" checkout --quiet --orphan "${BRANCH}"
  git -C "${WORKTREE}" rm -rfq . 2>/dev/null || true
fi

publish_attempt() {
  mkdir -p "${WORKTREE}/role-arns"

  if [[ -f "${WORKTREE}/${TARGET}" ]] \
    && diff <(jq -S . "${SOURCE_ABS}") <(jq -S . "${WORKTREE}/${TARGET}") >/dev/null 2>&1; then
    echo "No change to ${TARGET}."
    return 2
  fi

  cp "${SOURCE_ABS}" "${WORKTREE}/${TARGET}"

  git -C "${WORKTREE}" add "${TARGET}"
  git -C "${WORKTREE}" commit --quiet -m "chore: update role ARNs for ${ENVIRONMENT} [skip ci]"

  git -C "${WORKTREE}" push --quiet "${REMOTE}" "HEAD:refs/heads/${BRANCH}"
}

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do

  status=0
  publish_attempt || status=$?

  if [[ ${status} -eq 2 ]]; then
    exit 0
  fi

  if [[ ${status} -eq 0 ]]; then
    echo "Published ${TARGET} to ${BRANCH} (attempt ${attempt})."
    exit 0
  fi

  if [[ ${attempt} -eq ${MAX_ATTEMPTS} ]]; then
    echo "ERROR: could not publish ${TARGET} after ${MAX_ATTEMPTS} attempts." >&2
    exit 1
  fi

  echo "Push rejected (attempt ${attempt}); rebasing onto the latest ${BRANCH} and retrying."

  # Someone else published in the meantime. Drop our commit, take theirs, and
  # apply our change again on top.
  git fetch --quiet "${REMOTE}" "+refs/heads/${BRANCH}:${TRACKING_REF}"
  git -C "${WORKTREE}" reset --quiet --hard "${TRACKING_REF}"

  sleep "$(( (RANDOM % 3) + 1 ))"

done
