#!/usr/bin/env bash
# sync-admin-password.sh against REAL PostgreSQL and MySQL: the administrator's
# password really changes, the old one stops working, and a second run changes
# nothing. tests/real-bin/docker runs the container's psql and mysql locally
# against the test servers. MongoDB is covered offline (test_sync_admin.sh).
#
# It changes each server's administrator password and puts the original back
# at the end, even on failure.
#
# Skipped unless the servers are given (the provisioning function's test
# variables; the MySQL root account must accept that password):
#   PROVISION_TEST_PG_HOST, PROVISION_TEST_PG_SUPERUSER=postgres, PROVISION_TEST_PG_SUPERPASSWORD
#   PROVISION_TEST_MYSQL_HOST, PROVISION_TEST_MYSQL_ROOT_USER=root, PROVISION_TEST_MYSQL_ROOT_PASSWORD
set -uo pipefail

if [[ -z "${PROVISION_TEST_PG_HOST:-}" || -z "${PROVISION_TEST_MYSQL_HOST:-}" ]]; then
  echo "  skip real-server administrator-password tests (set PROVISION_TEST_PG_HOST and PROVISION_TEST_MYSQL_HOST)"
  exit 0
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
A="$(cd "$TESTS_DIR/../../../database/host/assets" && pwd)"
WORK="$(mktemp -d)"
export PATH="${TESTS_DIR}/real-bin:${PATH}"
export REAL_SECRETS="$WORK/secrets" REAL_ENGINES="postgres mysql"
mkdir -p "$REAL_SECRETS"

pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok   $1"; }; bad(){ fail=$((fail+1)); echo "  FAIL $1"; }
check(){ local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
refused(){ local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n"; else ok "$n"; fi; }

PG_ORIGINAL="${PROVISION_TEST_PG_SUPERPASSWORD}"
MY_ORIGINAL="${PROVISION_TEST_MYSQL_ROOT_PASSWORD}"
NEW="Rotated-pw.$(tr -dc a-z0-9 </dev/urandom | head -c 8)"

cp "$A/sync-admin-password.sh" "$WORK/"
printf 'AWS_REGION=af-south-1\nCORE_ROOT_SECRET_ARN=arn_core\n' > "$WORK/.env"

secret(){ # <current> [previous]
  printf '{"username":"admin","root_password":"%s"}' "$1" > "$REAL_SECRETS/arn_core"
  if [[ -n "${2:-}" ]]; then printf '{"username":"admin","root_password":"%s"}' "$2" > "$REAL_SECRETS/arn_core.AWSPREVIOUS"
  else rm -f "$REAL_SECRETS/arn_core.AWSPREVIOUS"; fi
}
sync(){ bash "$WORK/sync-admin-password.sh" "$@" > "$WORK/out.txt" 2>&1; }

pg_login(){ PGPASSWORD="$1" psql -h "$PROVISION_TEST_PG_HOST" -U "$PROVISION_TEST_PG_SUPERUSER" -d postgres -tAc "SELECT 1"; }
my_login(){ MYSQL_PWD="$1" mysql -h "$PROVISION_TEST_MYSQL_HOST" -u"$PROVISION_TEST_MYSQL_ROOT_USER" -N -e "SELECT 1"; }

restore(){
  # real-bin/docker signs psql in with PROVISION_TEST_PG_SUPERPASSWORD: say
  # which password the server now has, then change it back.
  export PROVISION_TEST_PG_SUPERPASSWORD="$NEW"
  secret "$PG_ORIGINAL" "$NEW"; sync postgres
  secret "$MY_ORIGINAL" "$NEW"; sync mysql
  export PROVISION_TEST_PG_SUPERPASSWORD="$PG_ORIGINAL"
  if ! pg_login "$PG_ORIGINAL" >/dev/null 2>&1 || ! my_login "$MY_ORIGINAL" >/dev/null 2>&1; then
    echo "  WARNING: could not put the servers' administrator passwords back; reset them by hand" >&2
  fi
  rm -rf "$WORK"
}
trap restore EXIT

echo "== PostgreSQL"
secret "$NEW" "$PG_ORIGINAL"
sync postgres; rc=$?
check   "succeeds"                                  test $rc -eq 0
[[ $rc -eq 0 ]] || cat "$WORK/out.txt"
check   "the new password signs in"                 pg_login "$NEW"
refused "the old one no longer does"                pg_login "$PG_ORIGINAL"
export PROVISION_TEST_PG_SUPERPASSWORD="$NEW"
sync postgres
check   "a second run changes nothing"              pg_login "$NEW"

echo "== MySQL"
secret "$NEW" "$MY_ORIGINAL"
sync mysql; rc=$?
check   "succeeds, from the previous version"       test $rc -eq 0
[[ $rc -eq 0 ]] || cat "$WORK/out.txt"
check   "  and says so"                             grep -q 'was the previous one' "$WORK/out.txt"
check   "the new password signs in"                 my_login "$NEW"
refused "the old one no longer does"                my_login "$MY_ORIGINAL"
sync mysql
check   "a second run: already current"             grep -q 'already the secret' "$WORK/out.txt"
secret "Neither-pw.1" "Nor-pw.2"
sync mysql; rc=$?
check   "a password matching neither version stops" test $rc -ne 0
check   "  and changes nothing"                     my_login "$NEW"
check   "no password is ever printed"               bash -c "! grep -qE '$NEW|$MY_ORIGINAL|$PG_ORIGINAL' '$WORK/out.txt'"

echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
