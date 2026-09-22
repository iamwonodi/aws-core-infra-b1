#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# DATABASE HOST BOOTSTRAP (user data)
#
#   Phase 1 - Prepare the persistent data volume (format on first use, mount,
#             persist in fstab).
#   Phase 2 - Create the database workspace and data root.
#   Phase 3 - Install the rendered runtime .env file.
#   Phase 4 - Download and verify the platform scripts (update.sh, provision.sh
#             and the shared deploy library) from the deploy bucket.
#   Phase 5 - Run the first deploy of whatever engines the platforms team has
#             published.
#
# This file is deliberately small. EC2 caps user data at 16 KB, so the scripts
# live in S3 and are verified against a checksum manifest in SSM. The manifest
# -- not this file -- carries the checksums, so editing a script never changes
# this user data and never restarts the database host. To refresh the scripts on
# a running host, send the <project>-database-refresh-scripts SSM document.
#
# Which engines run is decided entirely by the platforms team's registry (see
# update.sh); nothing here knows about any particular database engine.
# ==============================================================================

PROJECT_NAME="${project_name}"
ENVIRONMENT="${environment}"
SERVICE_NAME="${service_name}"
DATABASE_WORKSPACE="${database_workspace}"
DATA_ROOT="${data_root}"

ENABLE_DATA_VOLUME_MOUNT="${enable_data_volume_mount}"
DATA_VOLUME_DEVICE="${data_volume_device}"
DATA_VOLUME_MOUNT_PATH="${data_volume_mount_path}"

DEPLOY_BUCKET_NAME="${deploy_bucket_name}"
AWS_REGION="${aws_region}"
SCRIPTS_MANIFEST_PARAMETER="${scripts_manifest_parameter}"

export DEBIAN_FRONTEND=noninteractive

echo "============================================================"
echo "Starting database host bootstrap"
echo "Project:      $${PROJECT_NAME}"
echo "Environment:  $${ENVIRONMENT}"
echo "Service:      $${SERVICE_NAME}"
echo "Workspace:    $${DATABASE_WORKSPACE}"
echo "============================================================"

for required in PROJECT_NAME DATABASE_WORKSPACE DATA_ROOT DEPLOY_BUCKET_NAME AWS_REGION SCRIPTS_MANIFEST_PARAMETER; do
  if [[ -z "$${!required}" ]]; then
    echo "ERROR: $${required} is empty."
    exit 1
  fi
done

# ==============================================================================
# PERSISTENT DATA VOLUME
#
# Skipped when the mount is already active (a reboot). Otherwise the volume is
# formatted ONLY when it carries no filesystem, so a volume re-attached to a
# replacement instance keeps its data.
# ==============================================================================

# On current instance types an EBS volume attached as /dev/sdb appears as an
# NVMe device (/dev/nvme1n1), and the requested name may not exist. This prints
# the configured device when it exists; otherwise the single unmounted EBS disk.
resolve_data_device() {
  local configured="$1" candidate
  local -a candidates=()

  if [[ -b "$${configured}" ]]; then
    echo "$${configured}"
    return 0
  fi

  while read -r candidate; do
    [[ -z "$${candidate}" ]] && continue
    # Skip any disk with a mounted partition -- that is the root volume.
    if lsblk -no MOUNTPOINT "$${candidate}" 2>/dev/null | grep -q .; then
      continue
    fi
    candidates+=("$${candidate}")
  done < <(lsblk -dpno NAME,MODEL 2>/dev/null | awk '/Amazon Elastic Block Store/ {print $1}')

  if [[ $${#candidates[@]} -eq 1 ]]; then
    echo "$${candidates[0]}"
    return 0
  fi

  return 1
}

if [[ "$${ENABLE_DATA_VOLUME_MOUNT}" == "true" ]]; then

  if [[ -z "$${DATA_VOLUME_MOUNT_PATH}" ]]; then
    echo "ERROR: data volume mounting is enabled but DATA_VOLUME_MOUNT_PATH is empty."
    exit 1
  fi

  mkdir -p "$${DATA_VOLUME_MOUNT_PATH}"

  if mountpoint -q "$${DATA_VOLUME_MOUNT_PATH}"; then

    echo "Data volume is already mounted at $${DATA_VOLUME_MOUNT_PATH}."

  else

    echo "Waiting for the data volume ($${DATA_VOLUME_DEVICE})."

    DEVICE=""

    for _ in $(seq 1 30); do
      if DEVICE="$(resolve_data_device "$${DATA_VOLUME_DEVICE}")"; then
        break
      fi
      DEVICE=""
      sleep 2
    done

    if [[ -z "$${DEVICE}" ]]; then
      echo "ERROR: the data volume did not become available (configured device $${DATA_VOLUME_DEVICE})."
      exit 1
    fi

    echo "Using device $${DEVICE}."

    EXISTING_FILESYSTEM="$(blkid -o value -s TYPE "$${DEVICE}" 2>/dev/null || true)"

    if [[ -z "$${EXISTING_FILESYSTEM}" ]]; then
      echo "No filesystem detected; formatting $${DEVICE} as ext4."
      mkfs -t ext4 "$${DEVICE}"
    else
      echo "Existing $${EXISTING_FILESYSTEM} filesystem detected; keeping it."
    fi

    DATA_VOLUME_UUID="$(blkid -o value -s UUID "$${DEVICE}")"

    if [[ -z "$${DATA_VOLUME_UUID}" ]]; then
      echo "ERROR: could not determine the filesystem UUID for $${DEVICE}."
      exit 1
    fi

    mount "$${DEVICE}" "$${DATA_VOLUME_MOUNT_PATH}"

    if ! mountpoint -q "$${DATA_VOLUME_MOUNT_PATH}"; then
      echo "ERROR: the data volume could not be mounted at $${DATA_VOLUME_MOUNT_PATH}."
      exit 1
    fi

    # nofail: a missing volume must not stop the host booting into a state
    # where it cannot be reached to fix it. The UUID is used because device
    # names are not stable across reboots.
    if ! grep -qF "UUID=$${DATA_VOLUME_UUID} $${DATA_VOLUME_MOUNT_PATH}" /etc/fstab; then
      echo "UUID=$${DATA_VOLUME_UUID} $${DATA_VOLUME_MOUNT_PATH} ext4 defaults,nofail 0 2" >> /etc/fstab
    fi

    echo "Persistent data volume mounted at $${DATA_VOLUME_MOUNT_PATH}."

  fi

else

  echo "Persistent data volume mounting is disabled; data will live on the root volume."

fi

# ==============================================================================
# WORKSPACE
#
# engines/   -- the platforms team's engine folders, synced from the deploy bucket
# configs/   -- service database configs read by provision.sh
# inits/     -- service initialization scripts read by provision.sh
# DATA_ROOT  -- where every engine keeps its data. On the persistent volume when
#               one is mounted; the compose guard refuses bind mounts anywhere else.
# ==============================================================================

mkdir -p "$${DATABASE_WORKSPACE}/engines" "$${DATABASE_WORKSPACE}/configs" "$${DATABASE_WORKSPACE}/inits" "$${DATA_ROOT}"

chmod 0755 "$${DATABASE_WORKSPACE}" "$${DATABASE_WORKSPACE}/engines" "$${DATABASE_WORKSPACE}/configs" "$${DATABASE_WORKSPACE}/inits"
chmod 0755 "$${DATA_ROOT}"

# ==============================================================================
# RUNTIME ENVIRONMENT
#
# Configuration only. The database administrator password is never written
# here: CORE_ROOT_SECRET_ARN is a pointer to it in Secrets Manager.
# ==============================================================================

cat > "$${DATABASE_WORKSPACE}/.env" <<'DATABASE_ENV'
${database_env}
DATABASE_ENV

chmod 0600 "$${DATABASE_WORKSPACE}/.env"

# ==============================================================================
# PLATFORM SCRIPTS
# ==============================================================================

${fetch_scripts_function}

echo "Installing platform scripts."

fetch_platform_scripts \
  "$${SCRIPTS_MANIFEST_PARAMETER}" \
  "$${DEPLOY_BUCKET_NAME}" \
  "$${AWS_REGION}" \
  "$${DATABASE_WORKSPACE}"

# ==============================================================================
# FIRST DEPLOY
#
# A successful no-op until the platforms team publishes a registry.
# ==============================================================================

echo "Running the first database deploy."

"$${DATABASE_WORKSPACE}/update.sh"

apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Database host bootstrap completed successfully."
