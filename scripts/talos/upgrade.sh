#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <staging|production> [all|os|k8s]" >&2
  exit 1
fi

environment=$1
target_component="${2:-all}"

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
talos_dir="${repository_root}/talos"
environment_dir="${talos_dir}/environments/${environment}"
output_dir="${talos_dir}/generated/${environment}"
talosconfig="${output_dir}/clusterconfig/talosconfig"
topfconfig="${environment_dir}/topf.yaml"

if [[ ! -f "${topfconfig}" ]]; then
  echo "❌ Unknown Talos environment: ${environment}" >&2
  exit 1
fi

if [[ "${target_component}" != "all" && "${target_component}" != "os" && "${target_component}" != "k8s" ]]; then
  echo "❌ Invalid target component '${target_component}'. Must be one of: all, os, k8s" >&2
  exit 1
fi

echo "🛠️ Ensuring Talos configuration is rendered for ${environment}..."
"${repository_root}/scripts/talos/render.sh" "${environment}"

if [[ ! -f "${talosconfig}" ]]; then
  echo "❌ Generated talosconfig not found for ${environment}." >&2
  exit 1
fi

target_talos_version=$(yq eval '.talosVersion' "${topfconfig}")
target_k8s_version=$(yq eval '.kubernetesVersion' "${topfconfig}")

target_talos_clean="${target_talos_version#v}"
target_k8s_clean="${target_k8s_version#v}"

# 1. Talos OS Upgrade
if [[ "${target_component}" == "all" || "${target_component}" == "os" ]]; then
  echo ""
  echo "===================================================="
  echo "🔍 Checking Talos OS versions (Target: v${target_talos_clean})"
  echo "===================================================="

  nodes_json=$(yq eval -o=json '.nodes' "${topfconfig}")

  while IFS= read -r node; do
    node_ip=$(echo "${node}" | jq -r '.ip')
    hostname=$(echo "${node}" | jq -r '.host')

    current_talos=$(talosctl get version --nodes "${node_ip}" --talosconfig "${talosconfig}" -o json 2>/dev/null | jq -r '.spec.version // empty' || true)

    if [[ -z "${current_talos}" ]]; then
      echo "⚠️ Unable to query Talos version for ${hostname} (${node_ip}). Node may be unreachable."
      continue
    fi

    current_talos_clean="${current_talos#v}"

    if [[ "${current_talos_clean}" != "${target_talos_clean}" ]]; then
      echo "🚀 Upgrading Talos OS on ${hostname} (${node_ip}): v${current_talos_clean} -> v${target_talos_clean}..."
      topf --topfconfig "${topfconfig}" upgrade --nodes-filter "^${hostname}$"
    else
      echo "✅ ${hostname} (${node_ip}) is already running Talos v${current_talos_clean}."
    fi
  done < <(echo "${nodes_json}" | jq -c '.[]')
fi

# 2. Kubernetes Upgrade
if [[ "${target_component}" == "all" || "${target_component}" == "k8s" ]]; then
  echo ""
  echo "===================================================="
  echo "🔍 Checking Kubernetes version (Target: v${target_k8s_clean})"
  echo "===================================================="

  current_k8s=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // empty' || true)

  if [[ -z "${current_k8s}" ]]; then
    # Fallback to first control plane node via talosctl
    first_cp_ip=$(yq eval '.nodes[] | select(.role == "control-plane") | .ip' "${topfconfig}" | head -n 1)
    if [[ -n "${first_cp_ip}" ]]; then
      current_k8s=$(talosctl --nodes "${first_cp_ip}" --talosconfig "${talosconfig}" get nodestatus -o json 2>/dev/null | jq -r '.spec.kubernetesVersion // empty' || true)
    fi
  fi

  if [[ -z "${current_k8s}" ]]; then
    echo "⚠️ Unable to query current Kubernetes version. Proceeding with upgrade to v${target_k8s_clean}..."
    first_cp_ip=$(yq eval '.nodes[] | select(.role == "control-plane") | .ip' "${topfconfig}" | head -n 1)
    talosctl --nodes "${first_cp_ip}" --talosconfig "${talosconfig}" upgrade-k8s --to "v${target_k8s_clean}"
  else
    current_k8s_clean="${current_k8s#v}"

    if [[ "${current_k8s_clean}" != "${target_k8s_clean}" ]]; then
      echo "🚀 Upgrading Kubernetes: v${current_k8s_clean} -> v${target_k8s_clean}..."
      first_cp_ip=$(yq eval '.nodes[] | select(.role == "control-plane") | .ip' "${topfconfig}" | head -n 1)
      talosctl --nodes "${first_cp_ip}" --talosconfig "${talosconfig}" upgrade-k8s --to "v${target_k8s_clean}"
    else
      echo "✅ Kubernetes is already running v${current_k8s_clean}."
    fi
  fi
fi

echo ""
echo "🎉 Talos cluster upgrade checks completed!"
