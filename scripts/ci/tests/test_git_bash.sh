#!/usr/bin/env bash
# scripts/common/git-bash.sh: what Git Bash on Windows needs, and nothing elsewhere.
# Windows is simulated: OSTYPE is set to msys before sourcing, and fake jq/aws
# end every line with CRLF, as the native Windows builds do.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SHIM="${SCRIPTS}/common/git-bash.sh"

# Fakes that behave like jq.exe and aws.exe: real jq output, CRLF line endings.
REAL_JQ="$(command -v jq)"
mkdir -p "${WORK}/crlf-bin"
cat > "${WORK}/crlf-bin/jq" <<FAKE
#!/usr/bin/env bash
"${REAL_JQ}" "\$@" | sed 's/\$/\r/'
exit "\${PIPESTATUS[0]}"
FAKE
cat > "${WORK}/crlf-bin/aws" <<'FAKE'
#!/usr/bin/env bash
printf 'af-south-1\r\n'
[[ "${1:-}" == fail ]] && exit 255
exit 0
FAKE
chmod +x "${WORK}/crlf-bin/jq" "${WORK}/crlf-bin/aws"
CRLF_PATH="${WORK}/crlf-bin:${PATH}"

# Runs a snippet in a fresh bash: $1 is the OSTYPE to pretend, the rest the snippet.
as(){ local ostype="$1"; shift; PATH="${CRLF_PATH}" bash -c "set -euo pipefail; OSTYPE='${ostype}'; source '${SHIM}'; $*"; }
has_cr(){ [[ "$1" == *$'\r'* ]]; }

echo "== Git Bash (msys)"
out="$(as msys "jq -r '.[]' <<< '[\"development\",\"staging\"]'")"
check "jq output has no CR"                              bash -c "! [[ \"\$1\" == *\$'\\r'* ]]" _ "${out}"
check "jq output is otherwise unchanged"                 test "${out}" = $'development\nstaging'
check "a captured jq value compares cleanly"             as msys "v=\"\$(jq -r .a <<< '{\"a\":\"development\"}')\"; [[ \"\$v\" == development ]]"
check "aws output has no CR"                             as msys "[[ \"\$(aws configure get region)\" == af-south-1 ]]"
as msys "jq -e .missing <<< '{}' >/dev/null || exit \$?"; rc=$?
check "jq keeps its own exit status (jq -e on null: 1)"  test "${rc}" -eq 1
as msys "aws fail >/dev/null || exit \$?"; rc=$?
check "aws keeps its own exit status"                    test "${rc}" -eq 255
check "jq failure still stops a set -e script"           bash -c "! ( PATH='${CRLF_PATH}' bash -c \"set -euo pipefail; OSTYPE=msys; source '${SHIM}'; jq -e .missing <<< '{}' >/dev/null; echo reached\" | grep -q reached )"
check "child bash scripts inherit the wrappers"          as msys "[[ \"\$(bash -c \"jq -r .a <<< '{\\\"a\\\":\\\"x\\\"}'\")\" == x ]]"
check "cygwin is treated the same"                       as cygwin "[[ \"\$(aws configure get region)\" == af-south-1 ]]"

echo "== anywhere else (linux-gnu)"
check "jq is left alone"                                 as linux-gnu "[[ \"\$(type -t jq)\" == file ]]"
check "aws is left alone"                                as linux-gnu "[[ \"\$(type -t aws)\" == file ]]"
out="$(as linux-gnu "aws configure get region")"
check "  (so CRLF output passes through untouched)"      has_cr "${out}"

echo "== repository path with an apostrophe"
QUOTED="${WORK}/Alex's Workspace/repo"
mkdir -p "${QUOTED}/scripts/common"; cp "${SHIM}" "${QUOTED}/scripts/common/"
QUOTED_SHIM="${QUOTED}/scripts/common/git-bash.sh"
err="$(bash -c "OSTYPE=msys; source \"\$1\"; echo reached" _ "${QUOTED_SHIM}" 2>&1)"; rc=$?
check "Git Bash: stops before doing anything"            test "${rc}" -eq 1
check "Git Bash: says why"                               grep -q "path contains an apostrophe" <<< "${err}"
check "Git Bash: says what to do"                        grep -q 'C:\\dev' <<< "${err}"
check "Git Bash: nothing after it ran"                   bash -c "! grep -q reached <<< \"\$1\"" _ "${err}"
check "elsewhere: the same path is fine"                 bash -c "OSTYPE=linux-gnu; source \"\$1\"; true" _ "${QUOTED_SHIM}"
check "Git Bash: a path without one is fine"             bash -c "OSTYPE=msys; source \"\$1\"; true" _ "${SHIM}"

echo "== every workstation script sources it"
for s in init-project bootstrap-environment github-identity destroy-terraform-backend; do
  check "${s}.sh"                                        grep -q 'source "$(dirname "${BASH_SOURCE\[0\]}")/common/git-bash.sh"' "${SCRIPTS}/${s}.sh"
done

finish
