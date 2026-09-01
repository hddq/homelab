#!/usr/bin/env bash

set -euo pipefail

# Scripts directory baseline
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${REPO_ROOT}"

NODE_IP="192.168.20.120"
PVE_NODE="z690"
VM_ID="499"
SNAPSHOT_NAME="clean-bootstrapped"
KUBECONFIG_OUT="${REPO_ROOT}/kubeconfig-staging"
TALOS_CONFIG_DIR="${REPO_ROOT}/talos/generated/staging/clusterconfig"
TALOS_CONFIG_FILE="${TALOS_CONFIG_DIR}/homelab-staging-k8s-staging-1.yaml"
TALOSCONFIG_FILE="${TALOS_CONFIG_DIR}/talosconfig"

echo "===================================================="
echo "🚀 Rebuilding Talos Staging Cluster (VM ID: ${VM_ID})"
echo "===================================================="

# 1. Render Talos configuration
echo "🛠️ 1/7 Rendering Talos configuration..."
./scripts/talos/render.sh staging

# 2. Recreate VM via OpenTofu
echo "🔥 2/7 Recreating Proxmox VM via OpenTofu..."
(
  cd terraform/proxmox
  tofu apply -replace="proxmox_virtual_environment_vm.talos[\"staging-cp-1\"]"
)

# 3. Wait for Talos node reachability (Port 50000 maintenance mode)
echo "⏳ 3/7 Waiting for Talos API on ${NODE_IP}:50000..."
until nc -z -v -w5 "${NODE_IP}" 50000 2>/dev/null; do
  sleep 3
done

# 4. Apply Talos configuration
echo "📝 4/7 Applying Talos configuration..."
talosctl apply-config --insecure \
  --nodes "${NODE_IP}" \
  --file "${TALOS_CONFIG_FILE}"

# Wait for node reboot / installation phase
echo "⏳ Waiting for node installation and reboot..."
for _ in {1..10}; do
  if ! nc -z -w2 "${NODE_IP}" 50000 2>/dev/null; then
    break
  fi
  sleep 3
done

echo "⏳ Waiting for node to boot back up on ${NODE_IP}:50000..."
until nc -z -w5 "${NODE_IP}" 50000 2>/dev/null; do
  sleep 3
done

# 5. Bootstrap cluster
echo "🌱 5/7 Bootstrapping Talos control plane..."
MAX_RETRIES=24
RETRY_COUNT=0
until talosctl bootstrap \
  --nodes "${NODE_IP}" \
  --endpoints "${NODE_IP}" \
  --talosconfig "${TALOSCONFIG_FILE}" 2>/dev/null; do
  RETRY_COUNT=$((RETRY_COUNT+1))
  if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
    echo "❌ Bootstrapping failed after ${MAX_RETRIES} attempts."
    exit 1
  fi
  echo "  ⏳ Waiting for Talos bootstrap service readiness (attempt ${RETRY_COUNT}/${MAX_RETRIES})..."
  sleep 5
done

# 6. Fetch Kubeconfig & Wait for API / Node readiness
echo "🔑 6/7 Exporting kubeconfig to ${KUBECONFIG_OUT}..."
RETRY_COUNT=0
until talosctl kubeconfig "${KUBECONFIG_OUT}" \
  --nodes "${NODE_IP}" \
  --endpoints "${NODE_IP}" \
  --talosconfig "${TALOSCONFIG_FILE}" \
  --force 2>/dev/null; do
  RETRY_COUNT=$((RETRY_COUNT+1))
  if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
    echo "❌ Kubeconfig export failed after ${MAX_RETRIES} attempts."
    exit 1
  fi
  echo "  ⏳ Waiting for K8s API server readiness (attempt ${RETRY_COUNT}/${MAX_RETRIES})..."
  sleep 5
done

echo "⏳ Waiting for Kubernetes API server (port 6443) to open..."
until nc -z -w5 "${NODE_IP}" 6443 2>/dev/null; do
  sleep 3
done

echo "⏳ Waiting for Kubernetes Node k8s-staging-1 to register..."
until kubectl --kubeconfig="${KUBECONFIG_OUT}" get node/k8s-staging-1 >/dev/null 2>&1; do
  sleep 3
done
echo "ℹ️ Node registered with API server."

# 7. Create clean Proxmox Snapshot
echo "📸 7/7 Creating clean Proxmox snapshot '${SNAPSHOT_NAME}' on node ${PVE_NODE}..."
# shellcheck disable=SC2029
ssh "root@${PVE_NODE}" "qm snapshot ${VM_ID} ${SNAPSHOT_NAME} --description 'Clean bootstrapped staging cluster without workloads'"

echo ""
echo "🎉 Staging cluster rebuild complete!"
echo "   - Kubeconfig saved to: ./kubeconfig-staging"
echo "   - Snapshot created:    ${SNAPSHOT_NAME}"
echo ""
echo "👉 You can now run: ./scripts/kubernetes/bootstrap-cluster.sh staging stable ./k8s.key ./kubeconfig-staging"
echo "👉 To instant-rollback later, run: ./scripts/talos/rollback-staging.sh"
