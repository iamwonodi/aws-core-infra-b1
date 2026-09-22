#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
S="${SCRIPTS}/ci/check-placeholders.sh"

mkenv(){ rm -rf "${WORK}/env"; mkdir -p "${WORK}/env/infrastructure/development/data" "${WORK}/env/local-config"; cd "${WORK}/env/infrastructure/development" || exit 1; }

echo "== check-placeholders.sh"
mkenv
printf 'project_name = "core"\ndomain_name = "example.org"\n' > terraform.tfvars
printf 'terraform {}\n' > backend.tf; printf '{}\n' > data/service-roles.json
check "clean environment passes"                    bash "$S" .
mkenv; printf 'domain_name = "CHANGE_ME"\n' > terraform.tfvars
out="$(bash "$S" . 2>&1)"; rc=$?
check "marker in tfvars fails"                      test $rc -eq 1
check "report names the file and line"              bash -c "grep -q 'terraform.tfvars:1:' <<< \"$out\""
mkenv; printf '# set CHANGE_ME below\ndomain_name = "x.org"\n' > terraform.tfvars
check "marker in a comment is ignored"              bash "$S" .
mkenv; printf 'bucket = "CHANGE_ME-tfstate"\n' > backend.tf
check "marker in backend.tf fails"                  bash -c "! bash '$S' . >/dev/null 2>&1"
mkenv; printf '{"a/b":{"service_name":"CHANGE_ME"}}\n' > data/service-roles.json
check "marker in service-roles.json fails"          bash -c "! bash '$S' . >/dev/null 2>&1"
mkenv; printf '{"a/b":{"service_name":"CHANGE_ME"}}\n' > data/service-roles.example.json
check "marker in *.example.json is ignored"         bash "$S" .
mkenv; printf 'AWS_REGION=CHANGE_ME\n' > ../../local-config/development.vars.env
check "marker in local-config fails"                bash -c "! bash '$S' . >/dev/null 2>&1"
check "missing directory is an error"               bash -c "! bash '$S' /nonexistent >/dev/null 2>&1"
check "no arguments is an error"                    bash -c "! bash '$S' >/dev/null 2>&1"
mkenv; mkdir -p ../staging; printf 'domain_name = "CHANGE_ME"\n' > ../staging/terraform.tfvars
check "every directory given is checked"            bash -c "! bash '$S' . ../staging >/dev/null 2>&1"
finish
