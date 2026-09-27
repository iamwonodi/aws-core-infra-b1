# shellcheck shell=bash
# ==============================================================================
# MAKE THE WORKSTATION SCRIPTS WORK FROM GIT BASH ON WINDOWS
#
# Sourced, right after "set -euo pipefail", by every script a person runs on
# their own machine (init-project, bootstrap-environment, github-identity,
# destroy-terraform-backend). Anywhere but Git Bash (or Cygwin) it does nothing,
# so CI on Linux is unaffected.
#
# Two Windows behaviours break these scripts, and neither shows up on Linux:
#
#   1. Line endings. The native Windows builds of jq and the AWS CLI end every
#      output line with CRLF. Bash strips only the LF, so a captured value such
#      as an environment name comes back as "development\r" and every path or
#      comparison built from it fails. jq and aws are wrapped here to drop the
#      CR. terraform and gh are Go programs that print plain LF, and wrapping
#      terraform would put a pipe between it and the person answering its
#      apply prompt, so they are left alone.
#
#   2. Apostrophes in the repository's path. Git Bash translates a path such as
#      /c/Users/... into C:\Users\... before handing it to a Windows program,
#      but skips any argument containing an apostrophe. The scripts pass
#      absolute paths to git, terraform and jq, so a clone under a folder like
#      "Alex's Workspace" fails with a misleading "no such file" error. This
#      stops early with the real reason instead.
# ==============================================================================

case "${OSTYPE:-}" in
  msys* | cygwin*)
    # The exit status is jq's (or aws's), not tr's, whether or not the caller
    # runs with pipefail.
    jq()  { command jq  "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
    aws() { command aws "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
    # Exported, so helper scripts run with "bash <script>" get them too.
    export -f jq aws

    _git_bash_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [[ "${_git_bash_repo_root}" == *"'"* ]]; then
      echo "ERROR: this repository's path contains an apostrophe:" >&2
      echo "         ${_git_bash_repo_root}" >&2
      echo "       Git Bash cannot hand such a path to Windows programs (git, terraform, jq)." >&2
      echo "       Move the clone to a path without one, e.g. C:\\dev\\<repository>, and re-run." >&2
      exit 1
    fi
    unset _git_bash_repo_root
    ;;
esac
