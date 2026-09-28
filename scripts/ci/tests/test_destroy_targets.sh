#!/usr/bin/env bash
# resolve-destroy-targets.sh: what the destroy workflow destroys, and what it keeps.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="${SCRIPTS}/ci/resolve-destroy-targets.sh"

# A state list shaped like a real environment's.
cat > "${WORK}/state.txt" <<'EOF'
data.aws_caller_identity.current
module.github_identity.terraform_data.identity_invariants
module.github_oidc.data.aws_iam_policy_document.core_policy_document[0]
module.github_oidc.aws_iam_openid_connect_provider.github[0]
module.github_oidc.aws_iam_role.core_deploy_role[0]
module.github_oidc.aws_iam_role_policy_attachment.core["arn:aws:iam::aws:policy/AdministratorAccess"]
module.github_service_roles.aws_iam_role.github_service_roles["modart-development-web-infra"]
module.network.module.vpc_base.aws_vpc.this
module.network.module.vpc_base.aws_subnet.private["10.10.17.0/24"]
module.compute.module.deploy.module.bucket.aws_s3_bucket.this
module.monthly_budget[0].aws_budgets_budget.this
module.front_door.aws_cognito_user_pool.this
terraform_data.environment_invariants
aws_ssm_parameter.example[0]
EOF

targets="$(bash "$T" < "${WORK}/state.txt" 2>/dev/null)"
has(){ grep -qxF "$1" <<< "${targets}"; }

check "keeps the core role and OIDC provider"              bash -c "! grep -q '^module.github_oidc' <<< '${targets}'"
check "keeps github_identity, which github_oidc reads"     bash -c "! grep -q '^module.github_identity' <<< '${targets}'"
check "destroys the service roles"                         has "module.github_service_roles"
check "destroys each other module, once"                   test "$(grep -c '^module.network$' <<< "${targets}")" = 1
check "a nested module is its top-level module"            has "module.compute"
check "an indexed module is the whole module"              has "module.monthly_budget"
check "destroys root resources"                            has "terraform_data.environment_invariants"
check "a root resource's index is dropped"                 has "aws_ssm_parameter.example"
check "skips data sources"                                 bash -c "! grep -q '^data\.' <<< '${targets}'"
check "the full list"                                      test "$(wc -l <<< "${targets}")" = 7

only_kept="$(printf '%s\n' 'module.github_oidc.aws_iam_role.core_deploy_role[0]' 'module.github_identity.terraform_data.identity_invariants' 'data.aws_region.current' | bash "$T")"
check "nothing but the kept modules: nothing to destroy"   test -z "${only_kept}"
check "an empty state: nothing to destroy"                 test -z "$(bash "$T" < /dev/null)"
check "Windows line endings are tolerated"                 test "$(printf 'module.edge.aws_lb.this\r\n' | bash "$T")" = "module.edge"
check "an address it does not understand fails"            bash -c "! printf '%s\n' '???' | bash '$T' 2>/dev/null"
check "arguments are refused"                              bash -c "! bash '$T' extra </dev/null 2>/dev/null"

finish
