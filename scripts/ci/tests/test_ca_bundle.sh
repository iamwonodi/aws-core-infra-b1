#!/usr/bin/env bash
# Offline tests for check-ca-bundle.sh (needs bash and openssl).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
C="${SCRIPTS}/ci/check-ca-bundle.sh"

authority(){ openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/$1.key" -out "${WORK}/$1.pem" -days 1 -subj "/CN=$1" >/dev/null 2>&1; }
authority one; authority two
cat "${WORK}/one.pem" "${WORK}/two.pem" > "${WORK}/good.pem"
refused(){ local want="$2" out; out="$(bash "$C" "$1" 2>&1)" && return 1; grep -qF -- "$want" <<< "$out"; }

echo "== check-ca-bundle.sh"
out="$(bash "$C" "${WORK}/good.pem" 2>&1)"; rc=$?
check "a bundle of readable certificates passes"       test $rc -eq 0
check "and says how many"                              bash -c "grep -q '2 certificates' <<< \"$out\""
check "a missing bundle fails, pointing at AWS"        refused "${WORK}/absent.pem" "Download it from AWS"
: > "${WORK}/empty.pem"
check "an empty bundle fails"                          refused "${WORK}/empty.pem" "missing or empty"
sed 's/$/\r/' "${WORK}/good.pem" > "${WORK}/crlf.pem"
check "Windows line endings fail"                      refused "${WORK}/crlf.pem" "Windows line endings"
head -n 5 "${WORK}/good.pem" > "${WORK}/truncated.pem"
check "a truncated download fails"                     refused "${WORK}/truncated.pem" "whole PEM certificates"
{ echo "<html>Access Denied</html>"; cat "${WORK}/good.pem"; } > "${WORK}/stray.pem"
check "text outside the certificates fails"            refused "${WORK}/stray.pem" "outside its certificates"
sed '3s/./#/' "${WORK}/good.pem" > "${WORK}/corrupt.pem"
check "a certificate openssl cannot read fails"        refused "${WORK}/corrupt.pem" "cannot read"
cp "${WORK}/one.key" "${WORK}/key.pem"
check "a private key instead of certificates fails"    refused "${WORK}/key.pem" "whole PEM certificates"
finish
