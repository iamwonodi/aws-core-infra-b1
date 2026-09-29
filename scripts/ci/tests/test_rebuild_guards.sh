#!/usr/bin/env bash
# check-dns-delegation.sh, the bootstrap's delegation set, and the pinned runner.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT="$(cd "${SCRIPTS}/.." && pwd)"
G="${SCRIPTS}/ci/check-dns-delegation.sh"

# ---- stubs ------------------------------------------------------------------
mkdir -p "${WORK}/bin"
# terraform -chdir=<dir> show -json <plan>: prints the plan document.
cat > "${WORK}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == *"show -json"* ]] || { echo "unexpected: $*" >&2; exit 2; }
cat "${FAKE_PLAN}"
EOF
# dig +short NS <domain> @<resolver>: prints that resolver's answer, if any.
cat > "${WORK}/bin/dig" <<'EOF'
#!/usr/bin/env bash
last="${*: -1}"; resolver="${last#@}"
f="${FAKE_DNS_DIR}/${resolver}"
[[ -f "$f" ]] && cat "$f"
exit 0
EOF
chmod +x "${WORK}/bin/terraform" "${WORK}/bin/dig"
export TERRAFORM="${WORK}/bin/terraform" DIG="${WORK}/bin/dig" DNS_RESOLVERS="8.8.8.8 1.1.1.1"
export FAKE_PLAN="${WORK}/plan.json" FAKE_DNS_DIR="${WORK}/dns"

plan_with() {  # plan_with <name servers...>: a plan whose prior state holds a delegation set
  local ns
  ns="$(printf '"%s",' "$@")"; ns="[${ns%,}]"
  cat > "${FAKE_PLAN}" <<EOF
{"variables":{"domain_name":{"value":"dev.example.org"}},
 "prior_state":{"values":{"root_module":{"child_modules":[
   {"address":"module.github_oidc","resources":[]},
   {"address":"module.dns_delegation","resources":[
     {"address":"module.dns_delegation.aws_route53_delegation_set.this","type":"aws_route53_delegation_set",
      "values":{"id":"N0123","name_servers":${ns}}}]}]}}}}
EOF
}
dns() {  # dns <resolver> <answer lines...>
  mkdir -p "${FAKE_DNS_DIR}"; local r="$1"; shift
  printf '%s\n' "$@" > "${FAKE_DNS_DIR}/${r}"
}
reset_dns(){ rm -rf "${FAKE_DNS_DIR}"; mkdir -p "${FAKE_DNS_DIR}"; }
SET=(ns-1.awsdns-01.com ns-2.awsdns-02.net ns-3.awsdns-03.org ns-4.awsdns-04.co.uk)
guard(){ bash "$G" infrastructure/development tfplan > "${WORK}/out" 2>&1; }

# ---- the guard ---------------------------------------------------------------
plan_with "${SET[@]}"; reset_dns
dns 8.8.8.8 ns-4.awsdns-04.co.uk. ns-1.awsdns-01.com. NS-2.AWSDNS-02.NET. "ns-3.awsdns-03.org.$(printf '\r')"
dns 1.1.1.1 "${SET[@]/%/.}"
check "passes when public DNS returns the delegation set's four"  guard
check "  in any order, case, trailing dot or line ending"         grep -q "ok " "${WORK}/out"

reset_dns
dns 8.8.8.8 ns-9.awsdns-09.com. ns-8.awsdns-08.net. ns-7.awsdns-07.org. ns-6.awsdns-06.co.uk.
dns 1.1.1.1 ns-9.awsdns-09.com. ns-8.awsdns-08.net. ns-7.awsdns-07.org. ns-6.awsdns-06.co.uk.
check "fails when the registrar points elsewhere"                 bash -c "! bash '$G' infrastructure/development tfplan >'${WORK}/out' 2>&1"
check "  naming the four it should point at"                      grep -q "ns-4.awsdns-04.co.uk" "${WORK}/out"
check "  and what public DNS returned"                            grep -q "ns-9.awsdns-09.com" "${WORK}/out"

reset_dns
dns 8.8.8.8 ns-9.awsdns-09.com. ns-8.awsdns-08.net. ns-7.awsdns-07.org. ns-6.awsdns-06.co.uk.
dns 1.1.1.1 "${SET[@]}"
check "passes when one resolver already has the new answer"       guard

reset_dns
check "fails when the domain is not delegated at all"             bash -c "! bash '$G' infrastructure/development tfplan >'${WORK}/out' 2>&1"
check "  saying so"                                               grep -qi "no NS records" "${WORK}/out"

plan_with ns-1.awsdns-01.com ns-2.awsdns-02.net ns-3.awsdns-03.org ns-4.awsdns-04.co.uk
reset_dns; dns 8.8.8.8 ns-1.awsdns-01.com ns-2.awsdns-02.net ns-3.awsdns-03.org
check "fails when public DNS returns only some of them"          bash -c "! bash '$G' infrastructure/development tfplan >/dev/null 2>&1"

cat > "${FAKE_PLAN}" <<'EOF'
{"variables":{"domain_name":{"value":"dev.example.org"}},
 "prior_state":{"values":{"root_module":{"child_modules":[{"address":"module.github_oidc","resources":[]}]}}}}
EOF
reset_dns
check "skips when the state has no delegation set yet"            guard
check "  saying why"                                              grep -qi "skip" "${WORK}/out"

echo '{"variables":{"domain_name":{"value":"dev.example.org"}}}' > "${FAKE_PLAN}"
check "skips on an empty state (the very first apply)"            guard

check "refuses to run without its arguments"                      bash -c "! bash '$G' >/dev/null 2>&1"

# ---- the bootstrap creates the delegation set with the role ------------------
check "bootstrap applies module.dns_delegation with the core role" \
  grep -qE 'terraform apply .*-target=module\.github_oidc .*-target=module\.dns_delegation' "${SCRIPTS}/bootstrap-environment.sh"
check "  and prints the name servers for the registrar"          grep -q 'aws_route53_delegation_set' "${SCRIPTS}/bootstrap-environment.sh"

# ---- the apply workflow runs the guard, with a way to skip it -----------------
W="${ROOT}/.github/workflows/terraform-apply.yml"
check "the apply runs the guard before terraform apply" \
  python3 -c "
import sys,yaml
w=yaml.safe_load(open('$W'))
names=[s.get('name') for j in w['jobs'].values() for s in j.get('steps',[])]
sys.exit(0 if 'DNS Delegation Guard' in names and names.index('DNS Delegation Guard') < names.index('Terraform Apply') else 1)"
check "  and a manual run can skip it (off by default)" \
  python3 -c "
import sys,yaml
w=yaml.safe_load(open('$W'))
i=w[True]['workflow_dispatch']['inputs']['skip_dns_check']
sys.exit(0 if i['type']=='boolean' and i['default'] is False else 1)"

# ---- no workflow floats with ubuntu-latest -----------------------------------
check "every workflow pins its runner image" \
  bash -c "! grep -rn 'ubuntu-latest' '${ROOT}/.github/workflows'"

finish
