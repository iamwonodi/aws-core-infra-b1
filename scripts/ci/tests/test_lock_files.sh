#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
C="${SCRIPTS}/ci/check-lock-files.sh"

echo "== check-lock-files.sh"
R="${WORK}/lockrepo"; rm -rf "$R"; mkdir -p "$R/env"; cd "$R" && git init -q . && git config user.email t@t && git config user.name t
cat > env/versions.tf <<'TF'
terraform {
  required_providers {
    aws    = { source = "hashicorp/aws" }
    random = { source = "hashicorp/random" }
  }
}
TF
lock(){ printf '%s\n' "$@" > env/.terraform.lock.hcl; }

check "no lock file fails"                   bash -c "! bash '$C' env >/dev/null 2>&1"
lock 'provider "registry.terraform.io/hashicorp/aws" {' '}' 'provider "registry.terraform.io/hashicorp/random" {' '}'
check "an untracked lock file fails"         bash -c "! bash '$C' env >/dev/null 2>&1"
git add env/.terraform.lock.hcl
check "a tracked, complete lock file passes" bash "$C" env
lock 'provider "registry.terraform.io/hashicorp/aws" {' '}'; git add env/.terraform.lock.hcl
out="$(bash "$C" env 2>&1)"; rc=$?
check "a lock file missing a declared provider fails" test $rc -ne 0
check "and names the missing provider"       bash -c "grep -q 'hashicorp/random' <<< \"$out\""
mkdir -p env2; cp env/versions.tf env2/
check "every directory is checked, not just the first" bash -c "! bash '$C' env env2 >/dev/null 2>&1"
check "no directory given fails"             bash -c "! bash '$C' >/dev/null 2>&1"
cd - >/dev/null
finish
