#!/usr/bin/env bash

set -euo pipefail

# Script to validate Talos configs using talhelper and talosctl

echo "⚙️ Validating Talos configurations..."

TALOS_DIR="talos"

if [ ! -d "${TALOS_DIR}" ]; then
  echo "⚠️ No talos directory found, skipping."
  exit 0
fi

for env_dir in "${TALOS_DIR}"/*; do
  if [ -d "${env_dir}" ] && [ -f "${env_dir}/talconfig.yaml" ]; then
    echo "🔍 Validating Talos environment: ${env_dir}..."
    (
      cd "${env_dir}"
      talhelper genconfig
      for config_file in clusterconfig/*.yaml; do
        # Skip talosconfig or gitignore files if matched
        if [[ "$(basename "${config_file}")" == "talosconfig" ]]; then
          continue
        fi
        echo "  - Validating ${config_file}..."
        talosctl validate -c "${config_file}" -m metal
      done
    )
  fi
done

echo "✅ All Talos configurations are valid!"
