#!/usr/bin/env bash
# ==============================================================================
# Tests the network ACL rules (locals.tf) without AWS.
#
# The module as a whole needs AWS credentials to plan, because it creates
# resources. The rules only depend on its input variables, so this script
# copies variables.tf and locals.tf -- and nothing else -- into a temporary
# directory and runs the tests there.
#
# Uses "terraform" if installed, otherwise "tofu".
# ==============================================================================
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
module="$(cd "${here}/.." && pwd)"

tool="terraform"
command -v terraform >/dev/null 2>&1 || tool="tofu"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

mkdir -p "${work}/tests"
cp "${module}/variables.tf" "${module}/locals.tf" "${work}/"
cp "${here}/rules.tftest.hcl" "${work}/tests/"

cd "${work}"
"${tool}" init -backend=false >/dev/null
"${tool}" test
