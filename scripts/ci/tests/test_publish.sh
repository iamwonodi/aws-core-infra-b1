#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P="${SCRIPTS}/ci/publish-role-arns.sh"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

setup(){
  rm -rf "${WORK}/remote.git" "${WORK}/a" "${WORK}/b"
  git init -q --bare -b main "${WORK}/remote.git"
  git clone -q "${WORK}/remote.git" "${WORK}/a" 2>/dev/null
  ( cd "${WORK}/a" && git checkout -q -b main && echo hi > README.md && git add . && git commit -q -m init && git push -q origin main )
  git clone -q "${WORK}/remote.git" "${WORK}/b" 2>/dev/null
}
arns(){ printf '{"environment":"%s","core_deploy_role_arn":"arn:aws:iam::1:role/%s","service_role_arns":{}}' "$1" "$2" > "${WORK}/arns-$1.json"; }
show(){ git -C "${WORK}/remote.git" show "platform-outputs:role-arns/$1.json" 2>/dev/null; }

echo "== publish-role-arns.sh"
setup; arns development one
( cd "${WORK}/a" && bash "$P" development "${WORK}/arns-development.json" ) >/dev/null 2>&1
check "first publish creates the branch"            git -C "${WORK}/remote.git" rev-parse --verify -q platform-outputs
check "file content published"                      bash -c "$(declare -f show); WORK='${WORK}'; show development | jq -e '.core_deploy_role_arn == \"arn:aws:iam::1:role/one\"' >/dev/null"
check "branch is an orphan (no shared history)"     bash -c "[ \"\$(git -C '${WORK}/remote.git' rev-list --count platform-outputs)\" = 1 ] && ! git -C '${WORK}/remote.git' merge-base main platform-outputs >/dev/null 2>&1"
check "branch holds only role-arns/"                bash -c "[ \"\$(git -C '${WORK}/remote.git' ls-tree -r --name-only platform-outputs)\" = 'role-arns/development.json' ]"
check "main is untouched"                           bash -c "[ \"\$(git -C '${WORK}/remote.git' ls-tree -r --name-only main)\" = 'README.md' ]"
check "caller's working tree untouched"             bash -c "cd '${WORK}/a' && [ -z \"\$(git status --porcelain)\" ] && [ \"\$(git rev-parse --abbrev-ref HEAD)\" = main ]"
before="$(git -C "${WORK}/remote.git" rev-parse platform-outputs)"
( cd "${WORK}/a" && bash "$P" development "${WORK}/arns-development.json" ) >/dev/null 2>&1
check "unchanged file is not republished"           test "$(git -C "${WORK}/remote.git" rev-parse platform-outputs)" = "$before"
arns development two
( cd "${WORK}/a" && bash "$P" development "${WORK}/arns-development.json" ) >/dev/null 2>&1
check "changed file is published"                   bash -c "$(declare -f show); WORK='${WORK}'; show development | jq -e '.core_deploy_role_arn | endswith(\"two\")' >/dev/null"
arns staging stg
( cd "${WORK}/b" && bash "$P" staging "${WORK}/arns-staging.json" ) >/dev/null 2>&1
check "a second environment from another clone"     bash -c "$(declare -f show); WORK='${WORK}'; show staging | jq -e . >/dev/null && show development | jq -e . >/dev/null"
check "history is linear (rebased, no merges)"      bash -c "[ \"\$(git -C '${WORK}/remote.git' rev-list --merges --count platform-outputs)\" = 0 ]"

echo "== concurrent publishers"
# Separate clones, as in CI where every matrix job runs on its own runner.
setup; arns development d; arns staging s; arns production p
for e in development staging production; do
  git clone -q "${WORK}/remote.git" "${WORK}/c-$e" 2>/dev/null
done
for e in development staging production; do
  ( cd "${WORK}/c-$e" && bash "$P" "$e" "${WORK}/arns-$e.json" ) >/dev/null 2>&1 &
done
wait
check "all three environments published"            bash -c "[ \"\$(git -C '${WORK}/remote.git' ls-tree -r --name-only platform-outputs | wc -l)\" = 3 ]"

echo "== validation"
setup
check "unknown environment rejected"                bash -c "cd '${WORK}/a' && ! bash '$P' prod '${WORK}/arns-development.json' >/dev/null 2>&1"
printf 'not json' > "${WORK}/bad.json"
check "invalid JSON rejected"                       bash -c "cd '${WORK}/a' && ! bash '$P' development '${WORK}/bad.json' >/dev/null 2>&1"
check "missing file rejected"                       bash -c "cd '${WORK}/a' && ! bash '$P' development '${WORK}/none.json' >/dev/null 2>&1"
check "unreachable remote fails after retries"      bash -c "cd '${WORK}/a' && ! PUBLISH_REMOTE=nowhere PUBLISH_MAX_ATTEMPTS=2 bash '$P' development '${WORK}/arns-development.json' >/dev/null 2>&1"
finish
