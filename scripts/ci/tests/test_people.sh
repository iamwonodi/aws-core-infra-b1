#!/usr/bin/env bash
# scripts/ci/provision-people.sh against a fake aws.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export FAKE_AWS="${WORK}/aws" PROVISION_INTERVAL=0 PROVISION_TIMEOUT=5
SCRIPT="${SCRIPTS}/ci/provision-people.sh"

reset(){ rm -rf "${FAKE_AWS}"; mkdir -p "${FAKE_AWS}"/{ssm-status,db-status,lambda}; : > "${FAKE_AWS}/calls.log"; }
spec(){ printf '%s' "$1" > "${WORK}/spec.json"; }
run(){ bash "${SCRIPT}" "${WORK}/spec.json" af-south-1 > "${WORK}/out.txt" 2>&1; }
called(){ grep -qF -- "$1" "${FAKE_AWS}/calls.log"; }
said(){ grep -qF -- "$1" "${WORK}/out.txt"; }
not(){ ! "$@"; }

HOST='{"kind":"host","instance_id":"i-0123456789abcdef0","refresh_document":"core-database-refresh-scripts","people_document":"core-database-provision-people"}'
MANAGED='{"kind":"managed","engines":{"postgres":{"function":"core-staging-postgres-provision","database_kind":"rds","database_id":"core-staging-postgres"},"mongodb":{"function":"core-staging-mongodb-provision","database_kind":"docdb","database_id":"core-staging-mongodb"}}}'

echo "== development: the database host"
reset; spec "${HOST}"
run; rc=$?
check "succeeds"                                         test ${rc} -eq 0
check "refreshes the host's scripts first"               bash -c "grep -n 'send-command' '${FAKE_AWS}/calls.log' | head -1 | grep -q refresh-scripts"
check "then provisions people"                           called "send-command --document-name core-database-provision-people --instance-ids i-0123456789abcdef0"
check "shows the host's output"                          said "output of core-database-provision-people"
reset; spec "${HOST}"; echo Failed > "${FAKE_AWS}/ssm-status/core-database-provision-people"
run; rc=$?
check "a failed run on the host fails the step"          test ${rc} -ne 0
check "  showing why"                                    said "it broke"
reset; spec "${HOST}"; echo Failed > "${FAKE_AWS}/ssm-status/core-database-refresh-scripts"
run; rc=$?
check "a failed refresh stops before people"             bash -c "[[ ${rc} -ne 0 ]] && ! grep -q provision-people '${FAKE_AWS}/calls.log'"
reset; spec "${HOST}"; echo InProgress > "${FAKE_AWS}/ssm-status/core-database-provision-people"
PROVISION_TIMEOUT=0 run; rc=$?
check "a run that never finishes times out"              bash -c "[[ ${rc} -ne 0 ]] && grep -q 'giving up' '${WORK}/out.txt'"

echo "== staging and production: the functions"
reset; spec "${MANAGED}"
run; rc=$?
check "succeeds"                                         test ${rc} -eq 0
check "asks each function for people only"               bash -c "[[ \$(grep -c 'lambda invoke' '${FAKE_AWS}/calls.log') == 2 ]] && grep -qF -- '--payload {\"action\":\"people\"}' '${FAKE_AWS}/calls.log'"
check "checks an RDS instance's state"                   called "rds describe-db-instances --db-instance-identifier core-staging-postgres"
check "and a DocumentDB cluster's"                       called "docdb describe-db-clusters --db-cluster-identifier core-staging-mongodb"
check "reports who is provisioned"                       said "people: platform.ada"
reset; spec "${MANAGED}"; echo stopped > "${FAKE_AWS}/db-status/core-staging-postgres"
run; rc=$?
check "a stopped database is skipped, not a failure"     test ${rc} -eq 0
check "  its function is not called"                     not called "core-staging-postgres-provision"
check "  the other engine still is"                      called "core-staging-mongodb-provision"
check "  and the skip is said plainly"                   said 'Run the "Provision people" workflow once it is available'
reset; spec "${MANAGED}"; echo '{"FunctionError":"Unhandled","errorMessage":"platform.x is not a name"}' > "${FAKE_AWS}/lambda/core-staging-mongodb-provision.json"
run; rc=$?
check "a function error fails the step"                  test ${rc} -ne 0
check "  with the function's message"                    said "platform.x is not a name"
check "  after trying every engine"                      called "core-staging-postgres-provision"
reset; spec '{"kind":"managed","engines":{}}'
run; rc=$?
check "no managed database: nothing to do"               bash -c "[[ ${rc} -eq 0 ]] && grep -q 'nothing to do' '${WORK}/out.txt'"

echo "== refusals"
reset; spec '{"kind":"other"}'
run; rc=$?
check "an output that is not people_provisioning"        bash -c "[[ ${rc} -ne 0 ]] && [[ ! -s '${FAKE_AWS}/calls.log' ]]"
reset; spec '{"kind":"host","instance_id":"i-0123456789abcdef0; rm -rf /","refresh_document":"core-database-refresh-scripts","people_document":"core-database-provision-people"}'
run; rc=$?
check "an instance ID that is not one"                   bash -c "[[ ${rc} -ne 0 ]] && ! grep -q send-command '${FAKE_AWS}/calls.log'"

finish
