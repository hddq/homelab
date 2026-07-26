#!/usr/bin/env bash

set -euo pipefail

# Script to render and validate each Talos environment using talhelper and talosctl.

echo "⚙️ Validating Talos configurations..."

TALOS_DIR="talos"
ENVIRONMENTS_DIR="${TALOS_DIR}/environments"

if [ ! -d "${ENVIRONMENTS_DIR}" ]; then
  echo "⚠️ No talos directory found, skipping."
  exit 0
fi

# Create a temporary dummy secret file for CI generation without needing a SOPS key.
DUMMY_SECRET=$(mktemp)
VALIDATION_DIR=$(mktemp -d)
trap 'rm -f "${DUMMY_SECRET}"; rm -rf "${VALIDATION_DIR}"' EXIT

for env_dir in "${ENVIRONMENTS_DIR}"/*; do
  [ -d "${env_dir}" ] || continue
  [ -f "${env_dir}/environment.yaml" ] || continue

  environment=$(basename "${env_dir}")
  output_dir="${VALIDATION_DIR}/${environment}"
  mkdir -p "${output_dir}"

  echo "🔍 Validating Talos environment: ${environment}..."
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
    "${TALOS_DIR}/common.yaml" "${env_dir}/environment.yaml" > "${output_dir}/talconfig.yaml"
  talhelper gensecret > "${DUMMY_SECRET}"
  talhelper genconfig \
    --config-file "${output_dir}/talconfig.yaml" \
    --env-file "${TALOS_DIR}/versions.yaml" \
    --env-file "${env_dir}/talenv.yaml" \
    --secret-file "${DUMMY_SECRET}" \
    --out-dir "${output_dir}/clusterconfig"

  for config_file in "${output_dir}"/clusterconfig/*.yaml; do
    if [[ "$(basename "${config_file}")" == "talosconfig" ]]; then
      continue
    fi
    echo "  - Validating ${config_file}..."
    talosctl validate -c "${config_file}" -m metal
  done
done

echo "✅ All Talos configurations are valid!"
