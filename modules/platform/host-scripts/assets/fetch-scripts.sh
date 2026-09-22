# shellcheck shell=bash
# ==============================================================================
# fetch_platform_scripts <manifest-parameter> <bucket> <region> <destination>
#
# Downloads the platform scripts listed in an SSM manifest parameter and
# installs them into <destination>, refusing anything whose SHA-256 does not
# match the manifest.
#
# The manifest is a JSON object of S3 key -> sha256, written by Terraform from
# the very files it uploads. Keeping the checksums in SSM instead of in user
# data means a script change never changes an instance's user data, so a
# running host is never restarted just because a script was edited.
#
# Nothing is installed until EVERY file has been downloaded and verified, so a
# bad object can never leave a half-updated set of scripts behind.
#
# The same text is embedded in the boot-time user data and in the SSM
# "refresh scripts" document, so the two can never drift apart.
# ==============================================================================
fetch_platform_scripts() {
  local manifest_parameter="$1"
  local bucket="$2"
  local region="$3"
  local destination="$4"
  local manifest key expected file attempt
  local pause="${FETCH_RETRY_SECONDS:-5}"
  local -a keys=()

  # A freshly booted instance can reach IAM before its permissions have
  # propagated; retry rather than fail the whole boot.
  for attempt in 1 2 3 4 5; do
    if manifest="$(aws ssm get-parameter \
      --name "${manifest_parameter}" \
      --region "${region}" \
      --query Parameter.Value \
      --output text 2>/dev/null)" && [[ -n "${manifest}" ]]; then
      break
    fi
    if [[ "${attempt}" -eq 5 ]]; then
      echo "ERROR: could not read ${manifest_parameter}." >&2
      return 1
    fi
    sleep "${pause}"
  done

  mapfile -t keys < <(printf '%s' "${manifest}" | jq -r 'keys[]')

  if [[ ${#keys[@]} -eq 0 ]]; then
    echo "ERROR: ${manifest_parameter} lists no scripts." >&2
    return 1
  fi

  mkdir -p "${destination}"

  for key in "${keys[@]}"; do
    file="${destination}/$(basename "${key}")"
    expected="$(printf '%s' "${manifest}" | jq -r --arg k "${key}" '.[$k]')"

    for attempt in 1 2 3 4 5; do
      if aws s3 cp "s3://${bucket}/${key}" "${file}.new" --region "${region}" --only-show-errors; then
        break
      fi
      if [[ "${attempt}" -eq 5 ]]; then
        echo "ERROR: could not download s3://${bucket}/${key}." >&2
        rm -f "${destination}"/*.new
        return 1
      fi
      sleep "${pause}"
    done

    if ! printf '%s  %s\n' "${expected}" "${file}.new" | sha256sum --check --status; then
      echo "ERROR: ${key} does not match the checksum in ${manifest_parameter}; nothing was installed." >&2
      rm -f "${destination}"/*.new
      return 1
    fi
  done

  for key in "${keys[@]}"; do
    file="${destination}/$(basename "${key}")"
    mv "${file}.new" "${file}"
    chmod 0755 "${file}"
  done
}
