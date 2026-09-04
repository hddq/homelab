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
clusterconfig_dir="${output_dir}/clusterconfig"

if [[ ! -f "${environment_dir}/topf.yaml" ]]; then
  echo "Unknown Talos environment: ${environment}" >&2
  exit 1
fi

mkdir -p "${clusterconfig_dir}"

topf --topfconfig "${environment_dir}/topf.yaml" render -o "${clusterconfig_dir}"
topf --topfconfig "${environment_dir}/topf.yaml" talosconfig > "${clusterconfig_dir}/talosconfig"

echo "✅ Talos configuration rendered for ${environment} in ${clusterconfig_dir}"
