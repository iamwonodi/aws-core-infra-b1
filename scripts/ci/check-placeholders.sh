#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# FAIL WHEN AN ENVIRONMENT STILL CONTAINS THE BLUEPRINT'S PLACEHOLDER
#
# This repository is a blueprint: values that must be chosen per project ship as
# the marker CHANGE_ME. A clone that forgot to replace one would otherwise reach
# terraform plan (or worse, apply) half-configured, for example pointing at a
# domain nobody owns.
#
# Scans, for each environment directory given:
#   terraform.tfvars, backend.tf and data/*.json (except *.example.json)
# and, if present, ../../local-config/*.env relative to the environment.
# Comment lines are ignored, so documentation may mention the marker.
#
# Usage: check-placeholders.sh <environment-dir>...
# ==============================================================================

MARKER="CHANGE_ME"

if [[ $# -lt 1 ]]; then
  echo "ERROR: Usage: ${0} <environment-dir>..." >&2
  exit 1
fi

found=0

scan_file() {
  local file="$1"
  local hits

  [[ -f "${file}" ]] || return 0

  # -n: line numbers. The second grep drops comment-only lines (# or //).
  hits="$(grep -n "${MARKER}" "${file}" | grep -vE '^[0-9]+:[[:space:]]*(#|//)' || true)"

  if [[ -n "${hits}" ]]; then
    while IFS= read -r line; do
      echo "  ${file}:${line}"
    done <<< "${hits}"
    found=1
  fi
}

for env_dir in "$@"; do

  if [[ ! -d "${env_dir}" ]]; then
    echo "ERROR: not a directory: ${env_dir}" >&2
    exit 1
  fi

  echo "Checking ${env_dir} for ${MARKER}"

  scan_file "${env_dir}/terraform.tfvars"
  scan_file "${env_dir}/backend.tf"

  shopt -s nullglob
  for json_file in "${env_dir}"/data/*.json; do
    [[ "${json_file}" == *.example.json ]] && continue
    scan_file "${json_file}"
  done
  for env_file in "${env_dir}"/../../local-config/*.env; do
    scan_file "${env_file}"
  done
  shopt -u nullglob

done

if [[ ${found} -ne 0 ]]; then
  echo
  echo "ERROR: the lines above still contain the placeholder ${MARKER}."
  echo "       Replace each with your project's value (scripts/init-project.sh does this"
  echo "       for you), then commit."
  exit 1
fi

echo "No placeholders remain."
