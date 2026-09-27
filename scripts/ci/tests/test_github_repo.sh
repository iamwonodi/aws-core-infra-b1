#!/usr/bin/env bash
# scripts/common/github-repo.sh, and every gh write naming its repository.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../../common/github-repo.sh
source "${SCRIPTS}/common/github-repo.sh"

git init -q "${WORK}/r"
repo_for(){ git -C "${WORK}/r" remote remove origin 2>/dev/null; git -C "${WORK}/r" remote add origin "$1"; origin_repository "${WORK}/r"; }

echo "== origin_repository"
check "https with .git"                  test "$(repo_for https://github.com/acme/widgets.git)" = acme/widgets
check "https without .git"               test "$(repo_for https://github.com/acme/widgets)" = acme/widgets
check "https with a trailing slash"      test "$(repo_for https://github.com/acme/widgets/)" = acme/widgets
check "scp-style ssh"                    test "$(repo_for git@github.com:acme/widgets.git)" = acme/widgets
check "ssh:// url"                       test "$(repo_for ssh://git@github.com/acme/widgets.git)" = acme/widgets
check "dots in the name survive"         test "$(repo_for https://github.com/acme/my.repo.git)" = acme/my.repo
git -C "${WORK}/r" remote add upstream https://github.com/acme/blueprint.git
check "origin wins over upstream"        test "$(origin_repository "${WORK}/r")" = acme/my.repo
git -C "${WORK}/r" remote remove origin
check "no origin: returns 1"             bash -c "source '${SCRIPTS}/common/github-repo.sh'; ! origin_repository '${WORK}/r'"
check "no origin: prints nothing"        test -z "$(origin_repository "${WORK}/r")"
check "not a repository: returns 1"      bash -c "source '${SCRIPTS}/common/github-repo.sh'; ! origin_repository '${WORK}'"

echo "== every gh write names its repository"
# gh secret/variable set without --repo picks the repository from the remotes,
# preferring \"upstream\" (the blueprint in a product's clone).
writes="$(grep -nE 'gh[^|]*(secret|variable|"\$\{GH_SUBCOMMAND\}") set ' "${SCRIPTS}"/*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')"
check "there are writes to check"        test -n "${writes}"
check "each has --repo"                  bash -c "! grep -v -- '--repo' <<< \"\$1\"" _ "${writes}"

echo "== the scripts that write to GitHub source it"
for s in init-project bootstrap-environment github-identity; do
  check "${s}.sh"                        grep -q 'source "$(dirname "${BASH_SOURCE\[0\]}")/common/github-repo.sh"' "${SCRIPTS}/${s}.sh"
done

finish
