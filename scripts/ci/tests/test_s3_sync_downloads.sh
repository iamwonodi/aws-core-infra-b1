#!/usr/bin/env bash
# scripts/ci/check-s3-sync-downloads.sh: a download by "aws s3 sync" without
# --exact-timestamps fails; uploads and compliant downloads pass.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CHECK="${SCRIPTS}/ci/check-s3-sync-downloads.sh"

# The command is assembled here so this file holds no literal sync command for
# the check to find when it scans the repository.
SYNC="aws s3 ""sync"
fixture(){ # name, then the file's lines
  local name="$1"; shift
  mkdir -p "${WORK}/$(dirname "${name}")"
  printf '%s\n' '#!/usr/bin/env bash' "$@" > "${WORK}/${name}"
}
runs(){ bash "${CHECK}" "${WORK}" > "${WORK}/out.txt" 2>&1; }

echo "== downloads"
fixture modules/good/a.sh "${SYNC} \\" '  "s3://b/p/" \' '  "/srv/p/" \' '  --delete \' '  --exact-timestamps \' '  --only-show-errors'
check "continued download with the flag passes"       runs
fixture modules/bad/a.sh "${SYNC} \\" '  "s3://b/p/" \' '  "/srv/p/" \' '  --delete \' '  --only-show-errors'
check "continued download without it fails"           bash -c "! bash '${CHECK}' '${WORK}' > '${WORK}/out.txt' 2>&1"
check "  and names the file and the line"             grep -q 'modules/bad/a.sh:2: ' "${WORK}/out.txt"
check "  and only that file"                          bash -c "! grep -q modules/good '${WORK}/out.txt'"
rm -r "${WORK}/modules/bad"

fixture scripts/oneline.sh "${SYNC} s3://b/p ./local --delete"
check "one-line download without it fails"            bash -c "! bash '${CHECK}' '${WORK}' >/dev/null 2>&1"
fixture scripts/oneline.sh "${SYNC} --exclude '*.tmp' s3://b/p ./local --exact-timestamps"
check "flag and an option value before the paths pass" runs
fixture scripts/oneline.sh "${SYNC} --exclude s3://b/p ./local --delete"
check "an option's value is not taken as the source"  runs
rm "${WORK}/scripts/oneline.sh"

echo "== exempt"
fixture modules/up/a.sh "${SYNC} \\" '  "/srv/p/" \' '  "s3://b/p/" \' '  --delete'
fixture modules/up/b.sh "# ${SYNC} s3://b/p ./local" "${SYNC} ./out s3://b/q"
fixture modules/up/c.sh "${SYNC} s3://b/p s3://c/p"
check "uploads, comments and bucket-to-bucket pass"   runs

echo "== real repository"
check "the repository passes"                         bash "${CHECK}" "${SCRIPTS}/.."

finish
