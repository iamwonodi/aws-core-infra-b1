#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CHECK THE RDS CERTIFICATE BUNDLE THE PROVISIONING FUNCTION VERIFIES AGAINST
#
# The function refuses to connect to a database without it. This fails CI when
# the file is missing, empty, holds anything but PEM certificates, or holds a
# certificate openssl cannot read -- a truncated download, say.
#
# Usage: check-ca-bundle.sh [path]
# ==============================================================================

BUNDLE="${1:-modules/database/provisioning/lambda/certificates/rds-global-bundle.pem}"

command -v openssl >/dev/null 2>&1 || { echo "ERROR: required command not found: openssl" >&2; exit 1; }

if [[ ! -s "${BUNDLE}" ]]; then
  echo "ERROR: ${BUNDLE} is missing or empty." >&2
  echo "       Download it from AWS (see certificates/README.md next to it) and commit it." >&2
  exit 1
fi

if grep -q $'\r' "${BUNDLE}"; then
  echo "ERROR: ${BUNDLE} has Windows line endings; save it with LF." >&2
  exit 1
fi

begins="$(grep -c -- '-----BEGIN CERTIFICATE-----' "${BUNDLE}" || true)"
ends="$(grep -c -- '-----END CERTIFICATE-----' "${BUNDLE}" || true)"

if [[ "${begins}" -eq 0 || "${begins}" -ne "${ends}" ]]; then
  echo "ERROR: ${BUNDLE} must contain whole PEM certificates (found ${begins} beginnings and ${ends} ends)." >&2
  exit 1
fi

# Anything outside the certificate blocks is not expected.
stray="$(awk '/-----BEGIN CERTIFICATE-----/{inside=1} !inside && NF {print} /-----END CERTIFICATE-----/{inside=0}' "${BUNDLE}")"
if [[ -n "${stray}" ]]; then
  echo "ERROR: ${BUNDLE} contains text outside its certificates." >&2
  exit 1
fi

# Every certificate must parse.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
awk -v dir="${SCRATCH}" '/-----BEGIN CERTIFICATE-----/{n++} {print > (dir "/" n ".pem")}' "${BUNDLE}"

for certificate in "${SCRATCH}"/*.pem; do
  if ! openssl x509 -in "${certificate}" -noout 2>/dev/null; then
    echo "ERROR: ${BUNDLE} contains a certificate openssl cannot read (certificate $(basename "${certificate}" .pem))." >&2
    exit 1
  fi
done

echo "${BUNDLE}: ${begins} certificates, all readable."
