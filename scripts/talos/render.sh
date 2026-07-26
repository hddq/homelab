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

mkdir -p "${output_dir}"
yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
  "${talos_dir}/common.yaml" "${environment_dir}/environment.yaml" > "${output_dir}/talconfig.yaml"

talhelper genconfig \
  --config-file "${output_dir}/talconfig.yaml" \
  --env-file "${talos_dir}/versions.yaml" \
  --env-file "${environment_dir}/talenv.yaml" \
  --secret-file "${environment_dir}/talsecret.yaml" \
  --out-dir "${output_dir}/clusterconfig"
