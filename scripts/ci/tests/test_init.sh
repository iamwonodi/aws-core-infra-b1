#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
INIT="${SCRIPTS}/init-project.sh"
SOURCE_ROOT="$(cd "${SCRIPTS}/.." && pwd)"

fresh(){
  rm -rf "${WORK}/repo"; mkdir -p "${WORK}/repo/scripts/ci"
  cp -r "${SOURCE_ROOT}/infrastructure" "${WORK}/repo/infrastructure"
  find "${WORK}/repo" -name '.terraform*' -prune -exec rm -rf {} + 2>/dev/null
  cp "${SCRIPTS}/ci/check-placeholders.sh" "${WORK}/repo/scripts/ci/"
  git -C "${WORK}/repo" init -q; git -C "${WORK}/repo" remote add origin https://github.com/acme/widgets.git
  export INIT_REPO_ROOT="${WORK}/repo" FAKE_GH_LOG="${WORK}/gh.log"; : > "${FAKE_GH_LOG}"
}
ARGS=(--project acme --region eu-west-1 --domain example.org --reviewers alice,bob)
run(){ bash "${INIT}" "${ARGS[@]}" "$@"; }
val(){ sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${WORK}/repo/infrastructure/$1/$3" | head -1; }

echo "== files"
fresh; run >"${WORK}/out.txt" 2>&1; rc=$?
check "run succeeds"                                   test $rc -eq 0
check "development tfvars"                             bash -c "[ \"$(val development project_name terraform.tfvars)\" = acme ] && [ \"$(val development aws_region terraform.tfvars)\" = eu-west-1 ] && [ \"$(val development domain_name terraform.tfvars)\" = dev.example.org ]"
check "staging domain"                                 test "$(val staging domain_name terraform.tfvars)" = staging.example.org
check "production serves the base domain"              test "$(val production domain_name terraform.tfvars)" = example.org
check "private domain follows the domain by default"   test "$(val production private_domain terraform.tfvars)" = example.org
check "state bucket named per environment"             test "$(val staging bucket backend.tf)" = acme-staging-tfstate
check "backend region updated"                         test "$(val production region backend.tf)" = eu-west-1
check "trailing comments in backend.tf survive"        grep -q 'Native S3 locking' "${WORK}/repo/infrastructure/development/backend.tf"
check "no placeholder remains"                         bash "${WORK}/repo/scripts/ci/check-placeholders.sh" "${WORK}/repo/infrastructure/development" "${WORK}/repo/infrastructure/staging" "${WORK}/repo/infrastructure/production"
snapshot="$(cat "${WORK}/repo"/infrastructure/*/terraform.tfvars "${WORK}/repo"/infrastructure/*/backend.tf | sha256sum)"
run >/dev/null 2>&1
check "re-running changes nothing (idempotent)"        test "$(cat "${WORK}/repo"/infrastructure/*/terraform.tfvars "${WORK}/repo"/infrastructure/*/backend.tf | sha256sum)" = "$snapshot"
fresh; run --private-domain internal.example.org >/dev/null 2>&1
check "--private-domain is honoured"                   test "$(val staging private_domain terraform.tfvars)" = staging.internal.example.org

echo "== GitHub environments"
fresh; run >/dev/null 2>&1
for e in development development-plan staging staging-plan production production-plan; do
  check "environment $e configured"                    grep -q "^gh api -X PUT repos/acme/widgets/environments/$e --input -" "${FAKE_GH_LOG}"
  check "AWS_REGION set on $e"                         grep -q "^gh variable set AWS_REGION --env $e --body eu-west-1" "${FAKE_GH_LOG}"
done
body_of(){ grep -A1 "environments/$1 --input" "${FAKE_GH_LOG}" | grep '^BODY' | head -1 | sed 's/^BODY //'; }
check "development has no reviewers"                   bash -c "echo '$(body_of development)' | jq -e '.reviewers == []' >/dev/null"
check "development-plan has no reviewers"              bash -c "echo '$(body_of development-plan)' | jq -e '.reviewers == []' >/dev/null"
check "staging requires the reviewers"                 bash -c "echo '$(body_of staging)' | jq -e '(.reviewers | length) == 2 and .reviewers[0].id == 4242' >/dev/null"
check "production-plan requires them too"              bash -c "echo '$(body_of production-plan)' | jq -e '(.reviewers | length) == 2' >/dev/null"
check "apply environments are limited to custom branches" bash -c "echo '$(body_of production)' | jq -e '.deployment_branch_policy.custom_branch_policies == true' >/dev/null"
check "plan environments are NOT limited to a branch"  bash -c "echo '$(body_of production-plan)' | jq -e '.deployment_branch_policy == null' >/dev/null"
check "a branch policy is added to the three apply environments only" test "$(grep -c '^gh api -X POST repos/acme/widgets/environments/[a-z]* /*deployment-branch-policies\|^gh api -X POST repos/acme/widgets/environments/[a-z]*/deployment-branch-policies' "${FAKE_GH_LOG}")" = 3
check "the branch policy names main"                   grep -q 'BODY {"name":"main","type":"branch"}' "${FAKE_GH_LOG}"
fresh; ARGS2=(--project acme --region eu-west-1 --domain example.org); out="$(bash "${INIT}" "${ARGS2[@]}" 2>&1)"
check "no reviewers: warns for staging and production" bash -c "[ \"\$(grep -c 'WARNING: no --reviewers' <<< \"$out\")\" = 2 ]"
fresh; bash "${INIT}" "${ARGS[@]}" --skip-github >/dev/null 2>&1
check "--skip-github makes no gh call"                 test ! -s "${FAKE_GH_LOG}"
check "--skip-github still rewrites files"             test "$(val development project_name terraform.tfvars)" = acme

echo "== dry run"
fresh; before="$(cat "${WORK}/repo"/infrastructure/*/terraform.tfvars | sha256sum)"; out="$(run --dry-run 2>&1)"
check "dry run changes no file"                        test "$(cat "${WORK}/repo"/infrastructure/*/terraform.tfvars | sha256sum)" = "$before"
check "dry run makes no gh call"                       test ! -s "${FAKE_GH_LOG}"
check "dry run describes the work"                     bash -c "grep -q 'dev.example.org' <<< \"$out\" && grep -q 'dry run' <<< \"$out\""

echo "== validation (nothing is written on error)"
bad(){ fresh; before="$(cat "${WORK}/repo"/infrastructure/*/terraform.tfvars | sha256sum)"; bash "${INIT}" "$@" >/dev/null 2>&1; rc=$?
       [[ $rc -ne 0 && "$(cat "${WORK}/repo"/infrastructure/*/terraform.tfvars | sha256sum)" = "$before" && ! -s "${FAKE_GH_LOG}" ]]; }
check "bad project name"                               bad --project Bad_Name --region eu-west-1 --domain example.org
check "project too short"                              bad --project ab --region eu-west-1 --domain example.org
check "bad region"                                     bad --project acme --region nowhere --domain example.org
check "uppercase domain"                               bad --project acme --region eu-west-1 --domain Example.org
check "missing domain"                                 bad --project acme --region eu-west-1
check "bad reviewers list"                             bad --project acme --region eu-west-1 --domain example.org --reviewers 'a b'
check "bad --repo"                                     bad --project acme --region eu-west-1 --domain example.org --repo nonsense
check "unknown option"                                 bad --project acme --region eu-west-1 --domain example.org --bogus
fresh; FAKE_GH_NO_USER=1 bash "${INIT}" "${ARGS[@]}" >/dev/null 2>&1
check "an unknown reviewer login fails"                test $? -ne 0
echo "== database engines"
fresh; run --staging-engines postgres --production-engines postgres,mysql >/dev/null 2>&1
check "staging gets its own engine list"               grep -qx 'database_engines = \["postgres"\]' "${WORK}/repo/infrastructure/staging/terraform.tfvars"
check "production gets its own engine list"            grep -qx 'database_engines = \["postgres", "mysql"\]' "${WORK}/repo/infrastructure/production/terraform.tfvars"
check "development has no engine list"                 bash -c "! grep -q database_engines '${WORK}/repo/infrastructure/development/terraform.tfvars'"
run >/dev/null 2>&1
check "omitted, the lists are left as they are"        grep -qx 'database_engines = \["postgres", "mysql"\]' "${WORK}/repo/infrastructure/production/terraform.tfvars"
run --production-engines none >/dev/null 2>&1
check "none empties an environment's list"             grep -qx 'database_engines = \[\]' "${WORK}/repo/infrastructure/production/terraform.tfvars"
check "and leaves the other environment alone"         grep -qx 'database_engines = \["postgres"\]' "${WORK}/repo/infrastructure/staging/terraform.tfvars"
fresh; run --staging-engines mysql --dry-run > "${WORK}/dry.txt" 2>&1
check "a dry run shows the list but writes nothing"    bash -c "grep -q 'database_engines=mysql' '${WORK}/dry.txt' && grep -qx 'database_engines = \[\]' '${WORK}/repo/infrastructure/staging/terraform.tfvars'"
fresh; run --production-engines postgres,mongodb >/dev/null 2>&1
check "mongodb (DocumentDB) is accepted"               grep -qx 'database_engines = \["postgres", "mongodb"\]' "${WORK}/repo/infrastructure/production/terraform.tfvars"
check "an unknown engine is refused"                   bad --project acme --region eu-west-1 --domain example.org --staging-engines redis
check "a repeated engine is refused"                   bad --project acme --region eu-west-1 --domain example.org --staging-engines mysql,mysql
check "an empty list is refused (say none)"            bad --project acme --region eu-west-1 --domain example.org --staging-engines ""
check "a malformed list is refused"                    bad --project acme --region eu-west-1 --domain example.org --staging-engines "postgres, mysql"
fresh; run --staging-engines postgres,mysql --production-engines postgres,mysql >/dev/null 2>&1
check "the written lists are valid Terraform"          bash -c "cd '${WORK}/repo/infrastructure/production' && grep '^database_engines' terraform.tfvars | grep -qE '^database_engines = \\[(\"(postgres|mysql|mongodb)\"(, )?)+\\]$'"
finish
