#!/usr/bin/env bash

set -euo pipefail

# Homelab Cluster Bootstrapper for ArgoCD & Root App
# Usage: ./scripts/kubernetes/bootstrap-cluster.sh [environment] [branch] <age-key-path> [kubeconfig]
# Example: ./scripts/kubernetes/bootstrap-cluster.sh production stable ./k8s.key

ENVIRONMENT="${1:-production}"
BRANCH="${2:-stable}"
AGE_KEY_PATH="${3:-}"
KUBECONFIG_PATH="${4:-}"
REPO_SECRET_PATH="kubernetes/clusters/homelab/infra/argocd-secrets/repo-secret.yaml"
ADMIN_SECRET_PATH="kubernetes/clusters/homelab/infra/argocd-secrets/admin-secret.yaml"
ARGOCD_CHART_PATH="kubernetes/clusters/homelab/infra/argocd"
BOOTSTRAP_CHART_PATH="kubernetes/clusters/homelab/bootstrap"
REPO_URL="ssh://git@ssh.github.com:443/hddq/homelab.git"

KUBECTL=(kubectl)
HELM_KUBECONFIG_ARGS=()
if [ -n "${KUBECONFIG_PATH}" ]; then
  KUBECTL+=("--kubeconfig=${KUBECONFIG_PATH}")
  HELM_KUBECONFIG_ARGS+=("--kubeconfig=${KUBECONFIG_PATH}")
fi

echo "🚀 Starting cluster bootstrap..."
echo "  - Environment: ${ENVIRONMENT}"
echo "  - Git Branch:  ${BRANCH}"
echo "  - Kubeconfig:  ${KUBECONFIG_PATH:-active context}"
echo "  - SOPS key:    ${AGE_KEY_PATH}"
echo ""

# 1. Prerequisite checks
if [ -n "${KUBECONFIG_PATH}" ] && [ ! -f "${KUBECONFIG_PATH}" ]; then
  echo "❌ Error: Kubeconfig file not found at '${KUBECONFIG_PATH}'."
  exit 1
fi

if [ -z "${AGE_KEY_PATH}" ]; then
  echo "❌ Error: provide the SOPS Age key path as the third argument."
  echo "Usage: $0 [environment] [branch] <age-key-path> [kubeconfig]"
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

if [ ! -f "${ADMIN_SECRET_PATH}" ]; then
  echo "❌ Error: ArgoCD admin secret file not found at '${ADMIN_SECRET_PATH}'."
  exit 1
fi

# 2. Ensure argocd namespace exists
echo "📁 Ensuring 'argocd' namespace exists..."
"${KUBECTL[@]}" create namespace argocd --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

# 3. Apply SOPS Age key to cluster
echo "🔑 Injecting SOPS Age key secret ('sops-age')..."
"${KUBECTL[@]}" create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt="${AGE_KEY_PATH}" \
  --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

# 4. Decrypt and apply ArgoCD SSH Git repository secret & admin secret
echo "🔐 Decrypting and applying ArgoCD secrets..."
SOPS_AGE_KEY_FILE="${AGE_KEY_PATH}" sops -d "${REPO_SECRET_PATH}" | "${KUBECTL[@]}" apply -f -
SOPS_AGE_KEY_FILE="${AGE_KEY_PATH}" sops -d "${ADMIN_SECRET_PATH}" | "${KUBECTL[@]}" apply -f -

# 5. Build Helm dependencies using isolated repo config
echo "📦 Building ArgoCD Helm dependencies..."
TMP_HELM_REPO_CONF=$(mktemp)
trap 'rm -f "${TMP_HELM_REPO_CONF}"' EXIT

helm repo add argo-cd https://argoproj.github.io/argo-helm --repository-config "${TMP_HELM_REPO_CONF}" >/dev/null 2>&1
helm dependency build "${ARGOCD_CHART_PATH}" --repository-config "${TMP_HELM_REPO_CONF}"

echo "⚓ Installing/Upgrading ArgoCD..."
helm upgrade --install infra-argocd "${ARGOCD_CHART_PATH}" \
  --namespace argocd \
  --create-namespace \
  "${HELM_KUBECONFIG_ARGS[@]}" \
  --wait \
  --timeout 10m

# 6. Apply Root Application (App of Apps controller)
echo "🌱 Applying Root Application ('root-app') tracking branch '${BRANCH}'..."
cat <<EOF | "${KUBECTL[@]}" apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${BOOTSTRAP_CHART_PATH}
    helm:
      parameters:
        - name: targetRevision
          value: ${BRANCH}
        - name: environment
          value: ${ENVIRONMENT}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# 7. Print credentials & status
echo ""
echo "🎉 Cluster bootstrap complete!"
echo "----------------------------------------------------"
echo "🔑 ArgoCD Admin User:     admin"
echo "🔑 ArgoCD Admin Password: (predefined in 'argocd-secret')"
echo ""
echo "🌐 Access ArgoCD Dashboard:"
echo "   kubectl -n argocd port-forward service/infra-argocd-server 8080:80"
echo "   Open: http://localhost:8080"
echo "----------------------------------------------------"
