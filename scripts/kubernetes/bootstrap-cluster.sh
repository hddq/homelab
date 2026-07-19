#!/usr/bin/env bash

set -euo pipefail

# Homelab Cluster Bootstrapper for ArgoCD & Root App
# Usage: ./scripts/kubernetes/bootstrap-cluster.sh [environment] [branch] [kubeconfig]
# Example: ./scripts/kubernetes/bootstrap-cluster.sh production stable kubeconfig-production

ENVIRONMENT="${1:-production}"
BRANCH="${2:-stable}"
KUBECONFIG_PATH="${3:-kubeconfig-${ENVIRONMENT}}"
AGE_KEY_PATH="homelab.key"
REPO_SECRET_PATH="kubernetes/clusters/homelab/infra/argocd-secrets/secret.yaml"
ARGOCD_CHART_PATH="kubernetes/clusters/homelab/infra/argocd"
BOOTSTRAP_CHART_PATH="kubernetes/clusters/homelab/bootstrap"

echo "🚀 Starting cluster bootstrap..."
echo "  - Environment: ${ENVIRONMENT}"
echo "  - Git Branch:  ${BRANCH}"
echo "  - Kubeconfig:  ${KUBECONFIG_PATH}"
echo ""

# 1. Prerequisite checks
if [ ! -f "${KUBECONFIG_PATH}" ]; then
  echo "❌ Error: Kubeconfig file not found at '${KUBECONFIG_PATH}'."
  exit 1
fi

if [ ! -f "${AGE_KEY_PATH}" ]; then
  echo "❌ Error: SOPS Age key file not found at '${AGE_KEY_PATH}'."
  exit 1
fi

if [ ! -f "${REPO_SECRET_PATH}" ]; then
  echo "❌ Error: ArgoCD repository secret file not found at '${REPO_SECRET_PATH}'."
  exit 1
fi

# 2. Ensure argocd namespace exists
echo "📁 Ensuring 'argocd' namespace exists..."
kubectl --kubeconfig="${KUBECONFIG_PATH}" create namespace argocd --dry-run=client -o yaml | kubectl --kubeconfig="${KUBECONFIG_PATH}" apply -f -

# 3. Apply SOPS Age key to cluster
echo "🔑 Injecting SOPS Age key secret ('sops-age')..."
kubectl --kubeconfig="${KUBECONFIG_PATH}" create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt="${AGE_KEY_PATH}" \
  --dry-run=client -o yaml | kubectl --kubeconfig="${KUBECONFIG_PATH}" apply -f -

# 4. Decrypt and apply ArgoCD SSH Git repository secret
echo "🔐 Decrypting and applying ArgoCD Git SSH secret..."
SOPS_AGE_KEY_FILE="${AGE_KEY_PATH}" sops -d "${REPO_SECRET_PATH}" | kubectl --kubeconfig="${KUBECONFIG_PATH}" apply -f -

# 5. Build Helm dependencies and install ArgoCD
echo "📦 Building ArgoCD Helm dependencies..."
helm dependency build "${ARGOCD_CHART_PATH}"

echo "⚓ Installing/Upgrading ArgoCD..."
helm upgrade --install infrastructure-argocd "${ARGOCD_CHART_PATH}" \
  --namespace argocd \
  --create-namespace \
  --kubeconfig="${KUBECONFIG_PATH}" \
  --wait \
  --timeout 10m

# 6. Render and apply Root App of Apps
echo "🌱 Applying Root App of Apps for branch '${BRANCH}'..."
helm template homelab-bootstrap "${BOOTSTRAP_CHART_PATH}" \
  --set targetRevision="${BRANCH}" \
  --set environment="${ENVIRONMENT}" \
  | kubectl --kubeconfig="${KUBECONFIG_PATH}" apply -f -

# 7. Print credentials & status
echo ""
echo "🎉 Cluster bootstrap complete!"
echo "----------------------------------------------------"
if kubectl --kubeconfig="${KUBECONFIG_PATH}" -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  ARGOCD_PASS=$(kubectl --kubeconfig="${KUBECONFIG_PATH}" -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
  echo "🔑 ArgoCD Admin User:     admin"
  echo "🔑 ArgoCD Admin Password: ${ARGOCD_PASS}"
fi
echo ""
echo "🌐 Access ArgoCD Dashboard:"
echo "   kubectl --kubeconfig=${KUBECONFIG_PATH} -n argocd port-forward service/infrastructure-argocd-server 8080:80"
echo "   Open: http://localhost:8080"
echo "----------------------------------------------------"
