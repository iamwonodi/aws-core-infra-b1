#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
C="${SCRIPTS}/ci/create-deployment-metadata.sh"
R="${SCRIPTS}/ci/read-deployment-metadata.sh"
SHA="0123456789abcdef0123456789abcdef01234567"
mkdir -p "${WORK}/d"

echo "== deployment metadata"
bash "$C" "${WORK}/d" development "$SHA" assets >/dev/null 2>&1
check "in-repo assets: file is valid JSON"          jq -e . "${WORK}/d/deployment-metadata.json"
check "in-repo assets: read succeeds"               bash -c "bash '$R' '${WORK}/d/deployment-metadata.json' > '${WORK}/read.out'"
check "read emits the SHA and empty repository"     bash -c "grep -qx 'INFRASTRUCTURE_SHA=$SHA' '${WORK}/read.out' && grep -qx 'ASSETS_REPOSITORY=' '${WORK}/read.out' && grep -qx 'ASSETS_PATH=assets' '${WORK}/read.out'"
bash "$C" "${WORK}/d" staging "$SHA" external-assets acme/assets v1.4.0 >/dev/null 2>&1
bash "$R" "${WORK}/d/deployment-metadata.json" > "${WORK}/read2.out"
check "external assets round-trip"                  bash -c "grep -qx 'ASSETS_REPOSITORY=acme/assets' '${WORK}/read2.out' && grep -qx 'ASSETS_REF=v1.4.0' '${WORK}/read2.out' && grep -qx 'ENVIRONMENT=staging' '${WORK}/read2.out'"
check "output is safe to append to GITHUB_ENV"      bash -c "! grep -vE '^[A-Z_]+=' '${WORK}/read2.out'"
check "odd values cannot break the JSON"            bash -c "bash '$C' '${WORK}/d' production '$SHA' 'a\"b\$(x)' 'o/r' 'ref\"q' >/dev/null && jq -e '.assets_path == \"a\\\"b\$(x)\"' '${WORK}/d/deployment-metadata.json' >/dev/null"
check "bad SHA rejected"                            bash -c "! bash '$C' '${WORK}/d' development notasha assets >/dev/null 2>&1"
check "unknown environment rejected"                bash -c "! bash '$C' '${WORK}/d' prod '$SHA' assets >/dev/null 2>&1"
check "repository without a ref rejected"           bash -c "! bash '$C' '${WORK}/d' development '$SHA' assets o/r >/dev/null 2>&1"
check "too few arguments rejected"                  bash -c "! bash '$C' '${WORK}/d' development >/dev/null 2>&1"
printf '{"infrastructure_sha":"%s","environment":"development"}' "$SHA" > "${WORK}/nopath.json"
check "read rejects metadata without assets_path"   bash -c "! bash '$R' '${WORK}/nopath.json' >/dev/null 2>&1"
check "read rejects a missing file"                 bash -c "! bash '$R' '${WORK}/none.json' >/dev/null 2>&1"
finish
