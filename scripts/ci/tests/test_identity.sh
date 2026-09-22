#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
I="${SCRIPTS}/github-identity.sh"
export FAKE_GH_REPO_JSON='{"id": 222, "full_name": "iamwonodi/audit", "created_at": "2026-09-01T10:00:00Z", "owner": {"id": 111}}'

echo "== github-identity.sh"
git init -q "${WORK}/r"; cd "${WORK}/r" || exit 1
git remote add origin https://github.com/iamwonodi/audit.git
out="$(bash "$I" 2>/dev/null)"; rc=$?
check "https remote resolved"                        test $rc -eq 0
check "prints the three variables (bash)"            bash -c "grep -qx 'export TF_VAR_github_repository=iamwonodi/audit' <<< \"$out\" && grep -qx 'export TF_VAR_github_owner_id=111' <<< \"$out\" && grep -qx 'export TF_VAR_github_repository_id=222' <<< \"$out\""
check "output can be eval'd"                         bash -c "eval \"\$(bash '$I' 2>/dev/null)\" && [ \"\$TF_VAR_github_repository_id\" = 222 ]"
check "powershell format"                            bash -c "bash '$I' --shell powershell 2>/dev/null | grep -qx '\$env:TF_VAR_github_owner_id = \"111\"'"
git remote set-url origin git@github.com:iamwonodi/audit.git
check "ssh remote resolved"                          bash -c "bash '$I' 2>/dev/null | grep -q 'iamwonodi/audit'"
check "--repo overrides the remote"                  bash -c "bash '$I' --repo other/thing 2>/dev/null | grep -q 'TF_VAR_github_repository_id=222'"
export FAKE_GH_REPO_JSON='{"id": 9, "full_name": "iamwonodi/audit", "created_at": "2025-01-01T00:00:00Z", "owner": {"id": 1}}'
note="$(bash "$I" 2>&1 >/dev/null)"
check "older repository gets a classic-format note"  bash -c "grep -q 'oidc_subject_format=classic' <<< \"$note\""
export FAKE_GH_REPO_JSON='{"id": 222, "full_name": "iamwonodi/audit", "created_at": "2026-09-01T10:00:00Z", "owner": {"id": 111}}'
check "newer repository gets no note"                bash -c "[ -z \"\$(bash '$I' 2>&1 >/dev/null)\" ]"
check "gh failure is reported"                       bash -c "! FAKE_GH_FAIL=1 bash '$I' >/dev/null 2>&1"
git remote remove origin
check "no remote and no --repo is an error"          bash -c "! bash '$I' >/dev/null 2>&1"
check "malformed --repo rejected"                    bash -c "! bash '$I' --repo nonsense >/dev/null 2>&1"
check "unknown option rejected"                      bash -c "! bash '$I' --bogus >/dev/null 2>&1"
check "unknown shell rejected"                       bash -c "! bash '$I' --repo a/b --shell fish >/dev/null 2>&1"
finish
