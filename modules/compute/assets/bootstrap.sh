#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# FLEET INSTANCE BOOTSTRAP (user data)
#
# Prepares a fleet instance to run team-provided Docker Compose services, then
# performs an initial sync + deploy.
#
#   Phase 1 - Create the application workspace directory tree.
#   Phase 2 - Install the rendered runtime .env file.
#   Phase 3 - Download and verify the platform scripts (update.sh and its
#             shared library) from the deploy bucket.
#   Phase 4 - Perform the initial sync + deploy.
#   Phase 5 - Clean temporary package data.
#
# This file is deliberately small. EC2 caps user data at 16 KB, and the deploy
# scripts alone are larger than that, so they live in S3 and are verified
# against a checksum manifest in SSM (see fetch_platform_scripts below). Editing
# a script therefore never changes this file and never restarts a running host.
#
# This instance owns no compiler and generates no compose files -- every
# service's compose file and env file are provided directly by that service's
# own team, synced down from the deploy bucket by update.sh.
# ==============================================================================

APPLICATION_ROOT="/opt/applications"

# ==============================================================================
# RUNTIME CONFIGURATION (rendered by Terraform)
# ==============================================================================

# shellcheck disable=SC2034 # read through indirect expansion below
PROJECT_NAME="${project_name}"
DEPLOY_BUCKET_NAME="${deploy_bucket_name}"
AWS_REGION="${aws_region}"
SCRIPTS_MANIFEST_PARAMETER="${scripts_manifest_parameter}"

for required in PROJECT_NAME DEPLOY_BUCKET_NAME AWS_REGION SCRIPTS_MANIFEST_PARAMETER; do
  if [[ -z "$${!required}" ]]; then
    echo "ERROR: $${required} is empty."
    exit 1
  fi
done

# ==============================================================================
# APPLICATION WORKSPACE
#
# services/  -- one directory per team-provided service, synced from the deploy
#               bucket. Holds <service>/docker-compose.yml, <service>/.env and
#               any <service>/data seed material.
# .resolved/ -- reserved; update.sh writes each service's secret-resolved env
#               copy inside that service's own directory, never here.
# ==============================================================================

echo "Preparing application workspace at $${APPLICATION_ROOT}."

mkdir -p "$${APPLICATION_ROOT}/services"
chmod 0755 "$${APPLICATION_ROOT}"
chmod 0755 "$${APPLICATION_ROOT}/services"

# ==============================================================================
# RUNTIME ENVIRONMENT
#
# Platform-level configuration only -- see update.sh for per-service env files.
# ==============================================================================

echo "Installing runtime environment configuration."

cat > "$${APPLICATION_ROOT}/.env" <<'FLEET_ENV'
${fleet_env}
FLEET_ENV

chmod 0600 "$${APPLICATION_ROOT}/.env"

# ==============================================================================
# PLATFORM SCRIPTS
# ==============================================================================

${fetch_scripts_function}

echo "Installing platform scripts."

fetch_platform_scripts \
  "$${SCRIPTS_MANIFEST_PARAMETER}" \
  "$${DEPLOY_BUCKET_NAME}" \
  "$${AWS_REGION}" \
  "$${APPLICATION_ROOT}"

# ==============================================================================
# INITIAL SYNC + DEPLOY
#
# A fresh fleet instance genuinely has nothing to deploy until this runs --
# service files live in S3, not baked into the instance. This always runs at
# boot.
# ==============================================================================

echo "Performing initial sync and deploy."

"$${APPLICATION_ROOT}/update.sh"

# ==============================================================================
# CLEANUP
# ==============================================================================

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Fleet instance bootstrap completed successfully."
