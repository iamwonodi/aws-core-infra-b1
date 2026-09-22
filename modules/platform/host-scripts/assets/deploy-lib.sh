#!/usr/bin/env bash
# ==============================================================================
# DEPLOY LIBRARY -- shared by the fleet update.sh and the database update.sh
#
# Source this file; do not execute it. It defines functions only and changes no
# shell options, so the caller keeps control of "set -euo pipefail".
#
# Everything here is security-sensitive (it resolves secrets and decides what
# a team-supplied compose file may do), which is why it exists once instead of
# being copied into each update script: a fix made here reaches every host.
#
# Functions:
#   deploy_lock <lock-file> [wait-seconds]
#   deploy_jitter <max-seconds>
#   ecr_login <region> <registry-url>
#   find_compose_file <directory>
#   resolve_env_file <source-env> <destination-env>
#   compose_guard_violations <allowed-roots-json> [image-prefix]     (JSON on stdin)
#   compose_guard <compose-file> <project-dir> <env-file> <allowed-roots-json> [image-prefix]
# ==============================================================================

DEPLOY_SECRET_SENTINEL_PREFIX="__FROM_SECRET__:"

# ------------------------------------------------------------------------------
# deploy_lock
#
# Serialises runs. Three things can start an update at once: the boot-time
# deploy, a CI SSM command, and the secret-rotation EventBridge rule. Two
# overlapping runs would sync over each other's files and delete each other's
# .resolved scratch copies mid-deploy. The lock is held on file descriptor 9
# and released automatically when the process exits, however it exits.
# ------------------------------------------------------------------------------
deploy_lock() {
  local lock_file="$1"
  local wait_seconds="${2:-600}"

  exec 9>"${lock_file}"

  if ! flock --wait "${wait_seconds}" 9; then
    echo "ERROR: another update held ${lock_file} for over ${wait_seconds} seconds." >&2
    return 1
  fi
}

# ------------------------------------------------------------------------------
# deploy_jitter
#
# Sleeps a random 0..max seconds. A secret rotation triggers every host at the
# same moment; without this they would all recreate the same container at once
# and the service would be briefly down everywhere.
# ------------------------------------------------------------------------------
deploy_jitter() {
  local max_seconds="${1:-0}"

  if ! [[ "${max_seconds}" =~ ^[0-9]{1,3}$ ]]; then
    echo "ERROR: jitter must be a whole number of seconds (0-999), got '${max_seconds}'." >&2
    return 1
  fi

  if [[ "${max_seconds}" -gt 0 ]]; then
    local delay=$((RANDOM % (max_seconds + 1)))
    echo "Waiting ${delay}s (jitter, max ${max_seconds}s) before deploying."
    sleep "${delay}"
  fi
}

# ------------------------------------------------------------------------------
# ecr_login
#
# The instance profile only grants permission to READ from ECR; Docker still
# has to be logged in, or every pull of a private image fails with "no basic
# auth credentials". ECR tokens last 12 hours, so this runs on every update.
#
# HOME is set because SSM Run Command does not always provide one and
# "docker login" writes its credentials under it.
# ------------------------------------------------------------------------------
ecr_login() {
  local region="$1"
  local registry="$2"

  export HOME="${HOME:-/root}"

  local token

  echo "Logging in to ${registry}"

  # Two separate steps rather than a pipe, so a failure of "aws" is caught
  # whether or not the caller enabled pipefail. The token stays in a shell
  # variable and is never placed on a command line.
  if ! token="$(aws ecr get-login-password --region "${region}")" || [[ -z "${token}" ]]; then
    echo "ERROR: could not get an ECR login token. Check the instance profile's ECR read permissions and that the ECR endpoints are reachable." >&2
    return 1
  fi

  if ! printf '%s' "${token}" | docker login --username AWS --password-stdin "${registry}" >/dev/null; then
    echo "ERROR: docker login to ${registry} failed." >&2
    return 1
  fi
}

# ------------------------------------------------------------------------------
# find_compose_file
#
# Prints the compose file in a directory. Both docker-compose.yml and
# docker-compose.yaml are accepted, because teams use both spellings.
# ------------------------------------------------------------------------------
find_compose_file() {
  local directory="${1%/}"
  local candidate

  for candidate in docker-compose.yml docker-compose.yaml; do
    if [[ -f "${directory}/${candidate}" ]]; then
      echo "${directory}/${candidate}"
      return 0
    fi
  done

  return 1
}

# ------------------------------------------------------------------------------
# resolve_env_file
#
# Reads $1 (a team-provided env file) and writes a secret-resolved copy to $2.
# Lines that do not use the sentinel -- including the ARN-holding lines
# themselves -- are copied through unchanged. This is the only place a real
# secret value exists on disk, and only for as long as the caller needs it.
#
# Sentinel formats:
#
#   KEY=__FROM_SECRET__:ARN_VAR
#     Looks up the secret field named by lowercasing KEY.
#
#   KEY=__FROM_SECRET__:ARN_VAR:field_name
#     Looks up field_name explicitly. Needed when the application's variable
#     name differs from the secret's field name.
#
# ARN_VAR names another variable in the same file whose value is the secret's
# ARN. One secret is fetched at most once per call.
#
# Returns non-zero (and removes the partial output) on any failure, so a caller
# can skip one service without stopping the others.
# ------------------------------------------------------------------------------
resolve_env_file() {
  local source_file="$1"
  local dest_file="$2"
  local tmp_file="${dest_file}.tmp"
  local line key arn_var explicit_field arn_value secret_json field resolved_value fetch_status jq_status

  local -A secret_cache=()

  : > "${tmp_file}"
  chmod 0600 "${tmp_file}"

  while IFS= read -r line || [[ -n "${line}" ]]; do

    # A file authored on Windows carries a trailing CR. Left in place it makes
    # the sentinel pattern below fail to match, and the literal
    # "__FROM_SECRET__" text would be passed to the application as its value.
    line="${line%$'\r'}"

    if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "${line}" >> "${tmp_file}"
      continue
    fi

    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=${DEPLOY_SECRET_SENTINEL_PREFIX}([A-Za-z_][A-Za-z0-9_]*)(:([A-Za-z0-9_.-]+))?$ ]]; then

      key="${BASH_REMATCH[1]}"
      arn_var="${BASH_REMATCH[2]}"
      explicit_field="${BASH_REMATCH[4]:-}"

      # grep exits 1 when arn_var is genuinely unset, which is an expected
      # outcome handled just below.
      arn_value="$(grep -E "^${arn_var}=" "${source_file}" | head -n1 | cut -d'=' -f2- || true)"
      arn_value="${arn_value%$'\r'}"

      if [[ -z "${arn_value}" ]]; then
        echo "ERROR: ${key} references ${arn_var} for its secret ARN, but ${arn_var} is not set (or is empty) in ${source_file}." >&2
        rm -f "${tmp_file}"
        return 1
      fi

      if [[ -z "${secret_cache[${arn_value}]+x}" ]]; then
        fetch_status=0
        secret_json="$(aws secretsmanager get-secret-value \
          --secret-id "${arn_value}" \
          --region "${AWS_REGION}" \
          --query SecretString \
          --output text 2>/dev/null)" || fetch_status=$?

        if [[ ${fetch_status} -ne 0 || -z "${secret_json}" ]]; then
          echo "ERROR: unable to fetch secret ${arn_value} (referenced by ${arn_var})." >&2
          rm -f "${tmp_file}"
          return 1
        fi

        secret_cache["${arn_value}"]="${secret_json}"
      fi

      if [[ -n "${explicit_field}" ]]; then
        field="${explicit_field}"
      else
        field="$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]')"
      fi

      jq_status=0
      resolved_value="$(printf '%s' "${secret_cache[${arn_value}]}" | jq -er --arg k "${field}" '.[$k] // empty')" || jq_status=$?

      if [[ ${jq_status} -ne 0 || -z "${resolved_value}" ]]; then
        echo "ERROR: secret ${arn_value} has no field named '${field}' (looked up for ${key} in ${source_file})." >&2
        if [[ -z "${explicit_field}" ]]; then
          echo "       The field name was derived by lowercasing ${key}. If the secret names it differently, say so explicitly:" >&2
          echo "       ${key}=${DEPLOY_SECRET_SENTINEL_PREFIX}${arn_var}:<field_name>" >&2
        fi
        rm -f "${tmp_file}"
        return 1
      fi

      # A value containing a newline would be written as a second, unintended
      # line in the env file.
      if [[ "${resolved_value}" == *$'\n'* ]]; then
        echo "ERROR: the value for ${key} contains a newline and cannot be written to an env file." >&2
        rm -f "${tmp_file}"
        return 1
      fi

      printf '%s=%s\n' "${key}" "${resolved_value}" >> "${tmp_file}"

    else
      printf '%s\n' "${line}" >> "${tmp_file}"
    fi

  done < "${source_file}"

  mv "${tmp_file}" "${dest_file}"
  chmod 0600 "${dest_file}"
}

# ------------------------------------------------------------------------------
# compose_guard_violations
#
# Reads the JSON printed by "docker compose config --format json" on stdin and
# prints one line per problem. Prints nothing for an acceptable file.
#
# THIS IS A BEST-EFFORT DENY-LIST, NOT A SECURITY BOUNDARY. It stops mistakes
# and casual abuse -- a service reaching for root on a shared host -- but a
# team that can write a compose file is still trusted. Real isolation is one
# host per service.
#
# Rejected: privileged mode, added capabilities, devices, the host network / PID
# / IPC / UTS / user / cgroup namespaces (and joining another container's),
# unconfined seccomp/AppArmor/label security options, the Docker socket, and any
# bind mount whose source is outside the allowed roots. When an image prefix is
# supplied, images from any other registry are rejected too (the isolated tier
# has no internet path, so a public image could never be pulled).
# ------------------------------------------------------------------------------
compose_guard_violations() {
  local roots_json="$1"
  local image_prefix="${2:-}"

  jq -r --argjson roots "${roots_json}" --arg prefix "${image_prefix}" '
    (.services // {}) | to_entries[]
    | .key as $name | .value as $s
    | (
        (if ($s.privileged // false) == true
          then "\($name): privileged mode is not allowed" else empty end),

        (if (($s.cap_add // []) | length) > 0
          then "\($name): cap_add is not allowed (\(($s.cap_add) | join(",")))" else empty end),

        (if (($s.devices // []) | length) > 0
          then "\($name): devices are not allowed" else empty end),

        (["network_mode", "pid", "ipc", "uts", "userns_mode", "cgroup"][] as $k
          | (($s[$k] // "") | tostring) as $v
          | if ($v == "host") or ($v | startswith("container:"))
              then "\($name): \($k)=\($v) is not allowed" else empty end),

        (($s.security_opt // [])[]
          | select(test("unconfined|label[:=]disable"))
          | "\($name): security_opt \(.) is not allowed"),

        (($s.volumes // [])[]
          | select(.type == "bind")
          | .source as $src
          | if ($src | test("docker\\.sock$"))
              then "\($name): mounting the Docker socket is not allowed"
            elif ([$roots[] | select(. as $r | ($src == $r) or ($src | startswith($r + "/")))] | length) == 0
              then "\($name): bind mount \($src) is outside the allowed paths"
            else empty end),

        (if $prefix != "" and ((($s.image // "") | startswith($prefix)) | not)
          then "\($name): image \($s.image // "(none)") is not from \($prefix)" else empty end)
      )
  '
}

# ------------------------------------------------------------------------------
# compose_guard
#
# Renders a compose file with docker itself -- so anchors, extends, variable
# interpolation and relative paths are all resolved exactly as "up" would see
# them -- and checks the result. The rendered JSON can contain resolved secret
# values, so it is only ever piped into jq and never printed.
#
# Returns 0 when acceptable, 1 with the violations on stderr otherwise.
# ------------------------------------------------------------------------------
compose_guard() {
  local compose_file="$1"
  local project_dir="$2"
  local env_file="$3"
  local roots_json="$4"
  local image_prefix="${5:-}"

  local rendered violations render_status=0

  rendered="$(docker compose \
    --project-directory "${project_dir}" \
    --file "${compose_file}" \
    --env-file "${env_file}" \
    config --format json 2>&1)" || render_status=$?

  if [[ ${render_status} -ne 0 ]]; then
    # The message can echo file content, so keep it to the first line.
    echo "ERROR: docker compose could not render ${compose_file}: $(printf '%s' "${rendered}" | head -n1)" >&2
    return 1
  fi

  violations="$(printf '%s' "${rendered}" | compose_guard_violations "${roots_json}" "${image_prefix}")"

  if [[ -n "${violations}" ]]; then
    echo "ERROR: ${compose_file} was rejected by the compose guard:" >&2
    printf '%s\n' "${violations}" | sed 's/^/       - /' >&2
    return 1
  fi
}
