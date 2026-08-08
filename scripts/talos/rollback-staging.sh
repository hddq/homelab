#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

PVE_NODE="z690"
VM_ID="499"
SNAPSHOT_NAME="clean-bootstrapped"

echo "===================================================="
echo "⏪ Rolling back Talos Staging Cluster (VM ID: ${VM_ID})"
echo "===================================================="

echo "⚡ Rolling back VM ${VM_ID} to snapshot '${SNAPSHOT_NAME}' on ${PVE_NODE}..."
# shellcheck disable=SC2029
ssh "root@${PVE_NODE}" "qm stop ${VM_ID} && qm rollback ${VM_ID} ${SNAPSHOT_NAME} && qm start ${VM_ID}"

echo ""
echo "✅ Snapshot restored and VM booting in background!"
echo "👉 Run next: ./scripts/kubernetes/bootstrap-cluster.sh staging stable ./k8s.key ./kubeconfig-staging"
