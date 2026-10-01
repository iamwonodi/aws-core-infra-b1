#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# CHECK S3 SYNC DOWNLOADS
#
# "aws s3 sync" from S3 to a local directory skips a file whose size matches
# and whose local copy is not older than the S3 object. A deploy file that
# changes only an image tag of the same length (8.0-amd64-4968f22d0c6c ->
# 7.0-amd64-9854f7139445) is then never downloaded while the deploy reports
# success. --exact-timestamps makes any timestamp difference a download.
#
# Fails on every "aws s3 sync" in a *.sh under modules/ and scripts/ whose
# source is an s3:// URL and whose destination is local, without
# --exact-timestamps. Uploads (local -> s3://) and copies between buckets are
# exempt. Backslash-continued commands are read as one command.
#
# Usage: check-s3-sync-downloads.sh [repository-root]   (default: the current directory)
# ==============================================================================

ROOT="${1:-.}"
failed=0

for dir in modules scripts; do
  [[ -d "${ROOT}/${dir}" ]] || continue

  while IFS= read -r file; do
    # Options that take a value, so the value is not mistaken for the source or
    # the destination.
    if ! awk -v name="${file#"${ROOT}"/}" '
      function check(cmd,    n, t, i, pos, skip, tok, exact) {
        n = split(cmd, t, /[ \t]+/)
        pos = 0; skip = 0; exact = 0
        for (i = 1; i <= n; i++) {
          tok = t[i]; gsub(/["\047]/, "", tok)
          if (tok == "") continue
          if (skip) { skip = 0; continue }
          if (tok == "--exact-timestamps") { exact = 1; continue }
          if (tok ~ /^--(exclude|include|region|profile|endpoint-url|acl|sse|sse-kms-key-id|storage-class|cache-control|content-type|content-disposition|content-encoding|content-language|expires|metadata|metadata-directive|source-region|grants|website-redirect|request-payer|checksum-algorithm|ca-bundle|cli-read-timeout|cli-connect-timeout|color|output|query)$/) { skip = 1; continue }
          if (tok ~ /^--/) continue
          if (tok ~ /^(;|&&|\|\||\||>|>>|<|2>|2>&1|&>)$/ || tok ~ /^[0-9]?[<>]/) break
          pos++
          if (pos == 1) src = tok
          if (pos == 2) dst = tok
        }
        if (pos == 2 && src ~ /^s3:\/\// && dst !~ /^s3:\/\// && !exact) {
          printf "FAIL %s:%d: aws s3 sync %s %s downloads without --exact-timestamps\n", name, start, src, dst
          bad = 1
        }
      }
      {
        line = $0
        if (joined == "" && line ~ /^[ \t]*#/) next
        if (joined == "") start = NR
        if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, " ", line); joined = joined line; next }
        joined = joined line
        if (match(joined, /aws[ \t]+s3[ \t]+sync[ \t]/)) check(substr(joined, RSTART + RLENGTH))
        joined = ""
      }
      END { exit bad }
    ' "${file}"; then
      failed=1
    fi
  done < <(find "${ROOT}/${dir}" -name '*.sh' -not -path '*/.terraform/*' | sort)
done

if [[ "${failed}" -eq 0 ]]; then
  echo "ok   every download by aws s3 sync uses --exact-timestamps"
else
  echo "       Add --exact-timestamps: without it a changed file of equal size is skipped."
fi

exit "${failed}"
