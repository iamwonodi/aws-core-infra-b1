#!/usr/bin/env bash
# The workstation scripts on Git Bash, where jq is jq.exe and ends every output
# line with CRLF: no value they read from jq may carry a "\r".
#
# Windows is simulated twice over. tests/bin/jq-crlf is installed as "jq" and
# emulates jq.exe's line endings. Each script is then run with OSTYPE=msys,
# which is what Git Bash sets and what scripts/common/git-bash.sh keys on. The
# last section runs the same scripts with OSTYPE=linux-gnu (no wrapper) to show
# the stand-in does leak a "\r" when nothing strips it, so the assertions above
# cannot pass vacuously.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SOURCE_ROOT="$(cd "${SCRIPTS}/.." && pwd)"
CR=$'\r'

# jq-crlf first on PATH under the name jq, then the stubs the scripts' other
# tools need. Nothing here reaches AWS or GitHub.
mkdir -p "${WORK}/crlf" "${WORK}/stubs"
cp "${TESTS_DIR}/bin/jq-crlf" "${WORK}/crlf/jq"
cat > "${WORK}/stubs/aws" <<'STUB'
#!/usr/bin/env bash
printf 'aws %s\n' "$*" >> "${STUB_LOG}"
case "$1 $2" in
  "s3api head-bucket") exit 0 ;;
  "s3api get-object")  printf '{"resources": []}' > "${@: -1}"; printf '{}\r\n'; exit 0 ;;
  "s3api list-object-versions") printf '{"Objects": []}\r\n'; exit 0 ;;
esac
exit 0
STUB
cat > "${WORK}/stubs/terraform" <<'STUB'
#!/usr/bin/env bash
printf 'terraform %s\n' "$*" >> "${STUB_LOG}"
case "$*" in
  "version -json") echo '{"terraform_version": "1.16.3"}' ;;
  "output -json")  echo '{"core_deploy_role_arn": {"value": "arn:aws:iam::111111111111:role/core"}}' ;;
  "show -json")    echo '{"values": {"root_module": {"child_modules": [{"address": "module.dns_delegation", "resources": [{"type": "aws_route53_delegation_set", "values": {"name_servers": ["ns-1.example.net", "ns-2.example.org"]}}]}]}}}' ;;
esac
exit 0
STUB
chmod +x "${WORK}/stubs/aws" "${WORK}/stubs/terraform"
export STUB_LOG="${WORK}/stub.log"; : > "${STUB_LOG}"
export PATH="${WORK}/stubs:${WORK}/crlf:${PATH}"

# A copy of this repository's scripts and templates, so nothing is written to the real one.
fresh(){
  rm -rf "${WORK}/repo"; mkdir -p "${WORK}/repo"
  cp -r "${SOURCE_ROOT}/scripts" "${SOURCE_ROOT}/infrastructure" "${WORK}/repo/"
  cp "${SOURCE_ROOT}/environments.json" "${SOURCE_ROOT}/.terraform-version" "${WORK}/repo/"
  find "${WORK}/repo" -name '.terraform*' -not -name '.terraform-version' -prune -exec rm -rf {} + 2>/dev/null
  git -C "${WORK}/repo" init -q; git -C "${WORK}/repo" remote add origin https://github.com/acme/widgets.git
  export INIT_REPO_ROOT="${WORK}/repo" FAKE_GH_LOG="${WORK}/gh.log"; : > "${FAKE_GH_LOG}"
}
# Runs a script of the copy as Git Bash would: OSTYPE=msys, sourced so the
# variable is honoured (bash resets OSTYPE on start-up, so it cannot be exported).
as(){ local ostype="$1" script="$2"; shift 2; bash -c 'OSTYPE="$1"; script="$2"; shift 2; source "${script}" "$@"' _ "${ostype}" "${WORK}/repo/scripts/${script}" "$@"; }
no_cr(){ ! grep -q "${CR}" "$1"; }

if ! grep -q CHANGE_ME "${SOURCE_ROOT}/infrastructure/development/terraform.tfvars"; then
  echo "  skipped: this project has been initialised; these scripts are tested in the blueprint"
  finish
  exit $?
fi

echo "== jq-crlf"
check "the stand-in ends every line with CRLF"          test "$(jq -r '.[]' <<< '["a","b"]' | od -An -c | tr -d ' ')" = 'a\r\nb\r\n'
check "  and keeps jq's exit status"                    bash -c "! jq -e .x <<< '{}' >/dev/null"

echo "== init-project.sh (environment list, reviewer ids)"
fresh
as msys init-project.sh --project acme --region eu-west-1 --domain example.org --reviewers alice,bob --environments development,staging > "${WORK}/init.txt" 2>&1; rc=$?
check "succeeds"                                         test $rc -eq 0
check "environments are read without CR"                grep -qx 'Environments: development staging' "${WORK}/init.txt"
check "output has no CR"                                 no_cr "${WORK}/init.txt"
check "the GitHub calls have no CR"                      no_cr "${WORK}/gh.log"
check "environments.json has no CR"                      no_cr "${WORK}/repo/environments.json"
check "per-environment files were written"               test -f "${WORK}/repo/infrastructure/staging/terraform.tfvars"
check "reviewer ids reached the request body"            grep -q '"id":4242' "${WORK}/gh.log"

echo "== github-identity.sh (repository, owner and repository ids)"
export FAKE_GH_REPO_JSON='{"id": 222, "full_name": "acme/widgets", "created_at": "2026-09-01T10:00:00Z", "owner": {"id": 111}}'
( cd "${WORK}/repo" && as msys github-identity.sh ) > "${WORK}/identity.txt" 2>&1; rc=$?
check "succeeds"                                         test $rc -eq 0
check "prints the ids"                                   grep -qx 'export TF_VAR_github_repository_id=222' "${WORK}/identity.txt"
check "output has no CR"                                 no_cr "${WORK}/identity.txt"

echo "== destroy-terraform-backend.sh (environment list, resource and object counts)"
fresh; : > "${STUB_LOG}"
as msys destroy-terraform-backend.sh all DESTROY-ALL-STATE-BUCKETS > "${WORK}/destroy.txt" 2>&1; rc=$?
check "succeeds for every environment"                   test $rc -eq 0
check "each environment is named without CR"             grep -qx 'Destroying state bucket for: DEVELOPMENT' "${WORK}/destroy.txt"
check "the state's resource count is read (0)"           grep -q 'tracks zero resources' "${WORK}/destroy.txt"
check "the bucket's object count is read (0)"            grep -q 'is already empty' "${WORK}/destroy.txt"
check "output has no CR"                                 no_cr "${WORK}/destroy.txt"
check "the stubbed aws saw no CR in a bucket name"       no_cr "${STUB_LOG}"

echo "== bootstrap-environment.sh (environment list, terraform version, role ARN, name servers)"
fresh; : > "${STUB_LOG}"
export TF_VAR_github_repository=acme/widgets AWS_REGION=eu-west-1
printf '\n\n\n' | as msys bootstrap-environment.sh all > "${WORK}/bootstrap.txt" 2>&1; rc=$?
check "succeeds"                                         test $rc -eq 0
check "every environment is bootstrapped by name"        grep -qx 'Bootstrapping environment: DEVELOPMENT' "${WORK}/bootstrap.txt"
check "the terraform version compares equal (no warning)" bash -c "! grep -q WARNING '${WORK}/bootstrap.txt'"
check "the role ARN is read"                             grep -qx '  arn:aws:iam::111111111111:role/core' "${WORK}/bootstrap.txt"
check "the name servers are read"                        grep -qx '  ns-2.example.org' "${WORK}/bootstrap.txt"
check "output has no CR"                                 no_cr "${WORK}/bootstrap.txt"
check "the stubbed aws saw no CR in a bucket name"       no_cr "${STUB_LOG}"

echo "== control: without the wrapper the stand-in does leak a CR"
fresh; : > "${STUB_LOG}"
as linux-gnu destroy-terraform-backend.sh all DESTROY-ALL-STATE-BUCKETS > "${WORK}/control.txt" 2>&1
check "destroy-terraform-backend.sh: CR reaches the environment name" grep -q "${CR}" "${WORK}/control.txt"
fresh
as linux-gnu init-project.sh --project acme --region eu-west-1 --domain example.org --environments development,staging > "${WORK}/control.txt" 2>&1
check "init-project.sh: CR reaches the environment list"    grep -q "${CR}" "${WORK}/control.txt"

finish
