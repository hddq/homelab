#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <staging|production>" >&2
  exit 1
fi

environment=$1
repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
talos_dir="${repository_root}/talos"
environment_dir="${talos_dir}/environments/${environment}"
output_dir="${talos_dir}/generated/${environment}"

if [[ ! -f "${environment_dir}/environment.yaml" ]]; then
  echo "Unknown Talos environment: ${environment}" >&2
  exit 1
fi

if [[ ! -f "${output_dir}/talconfig.yaml" ]]; then
  echo "Configuration not found for environment: ${environment}. Please run render.sh first." >&2
  exit 1
fi

echo "Generating and executing Talos OS upgrade commands for ${environment}..."

talhelper gencommand upgrade \
  --config-file "${output_dir}/talconfig.yaml" \
  --out-dir "${output_dir}/clusterconfig" \
  --env-file "${talos_dir}/versions.yaml" \
  --env-file "${environment_dir}/talenv.yaml" \
  --extra-flags="--talosconfig ${output_dir}/clusterconfig/talosconfig" | bash

echo "Upgrade commands executed successfully!"
