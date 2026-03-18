#!/usr/bin/env bash
set -e

VERSION="v1.0.1"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Migration Script ${VERSION}${NC}"

# Usage: ./upload-to-pvc.sh <app-name> <namespace> <pvc-name> <local-path> <remote-path>

APP_NAME=$1
NAMESPACE=$2
PVC_NAME=$3
LOCAL_PATH=$4
REMOTE_PATH=$5
ARGOCD_APP="apps-${APP_NAME}"

if [[ -z "$APP_NAME" || -z "$NAMESPACE" || -z "$PVC_NAME" || -z "$LOCAL_PATH" || -z "$REMOTE_PATH" ]]; then
    echo -e "${YELLOW}Usage:${NC} $0 <app-name> <namespace> <pvc-name> <local-path> <remote-path>"
    echo -e "${YELLOW}Example (File):${NC} $0 opodsync opodsync opodsync-pvc ./data.sqlite data.sqlite"
    echo -e "${YELLOW}Example (Folder):${NC} $0 opodsync opodsync opodsync-pvc ./my-data/. ."
    exit 1
fi

if [[ ! -e "$LOCAL_PATH" ]]; then
    echo -e "${RED}Error:${NC} Local path $LOCAL_PATH does not exist."
    exit 1
fi

echo -e "${BLUE}🔍 Checking environment...${NC}"

# Check Namespace
if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "${RED}Error:${NC} Namespace $NAMESPACE not found."
    exit 1
fi

# Check PVC
if ! kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "${RED}Error:${NC} PVC $PVC_NAME not found in namespace $NAMESPACE."
    exit 1
fi

# Check Deployment and Capture Replicas
DEPLOYMENT_NAME="$APP_NAME"

if ! kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning:${NC} Deployment $DEPLOYMENT_NAME not found. Skipping scaling.${NC}"
    SKIP_SCALING=true
else
    ORIGINAL_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    SKIP_SCALING=false
    echo -e "${BLUE}📊 Current replicas for $DEPLOYMENT_NAME: $ORIGINAL_REPLICAS${NC}"
fi

# ArgoCD Detection & Policy Capture
HAS_ARGOCD_APP=false
if kubectl get namespace argocd >/dev/null 2>&1; then
    # Capture the entire automated sync policy as JSON
    SYNC_POLICY=$(kubectl get application -n argocd "$ARGOCD_APP" -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null || true)
    if kubectl get application -n argocd "$ARGOCD_APP" >/dev/null 2>&1; then
        HAS_ARGOCD_APP=true
        if [[ -n "$SYNC_POLICY" ]]; then
            echo -e "${BLUE}⏸️  Suspending ArgoCD Auto-Sync for $ARGOCD_APP...${NC}"
            kubectl patch application -n argocd "$ARGOCD_APP" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
        fi
    fi
fi

if [[ "$SKIP_SCALING" == "false" ]]; then
    echo -e "${BLUE}📉 Scaling deployment $DEPLOYMENT_NAME down to 0...${NC}"
    kubectl scale deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --replicas=0
fi

echo -e "${BLUE}🚀 Starting temporary migration pod...${NC}"
TEMP_POD="migration-temp-$(date +%s)"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: $TEMP_POD
  namespace: $NAMESPACE
spec:
  containers:
  - name: alpine
    image: alpine
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /mnt/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $PVC_NAME
EOF

# Cleanup trap (runs on exit, success or failure)
trap 'echo -e "${YELLOW}🧹 Cleaning up temporary pod...${NC}"; kubectl delete pod "$TEMP_POD" -n "$NAMESPACE" --ignore-not-found --wait=false' EXIT

echo -e "${BLUE}⏳ Waiting for pod $TEMP_POD to be ready...${NC}"
kubectl wait --for=condition=Ready pod/"$TEMP_POD" -n "$NAMESPACE" --timeout=60s

echo -e "${BLUE}📤 Uploading $LOCAL_PATH to /mnt/data/$REMOTE_PATH...${NC}"
if [[ "$REMOTE_PATH" != "." ]]; then
    if [[ -d "$LOCAL_PATH" ]]; then
        kubectl exec -n "$NAMESPACE" "$TEMP_POD" -- mkdir -p "/mnt/data/$REMOTE_PATH"
    else
        REMOTE_DIR=$(dirname "/mnt/data/$REMOTE_PATH")
        kubectl exec -n "$NAMESPACE" "$TEMP_POD" -- mkdir -p "$REMOTE_DIR"
    fi
fi

kubectl cp "$LOCAL_PATH" "${NAMESPACE}/${TEMP_POD}:/mnt/data/$REMOTE_PATH"

echo -e "${GREEN}✅ Upload complete. Verifying structure:${NC}"
kubectl exec -n "$NAMESPACE" "$TEMP_POD" -- ls -lhd "/mnt/data/$REMOTE_PATH"

# Scaling back to ORIGINAL replicas
if [[ "$SKIP_SCALING" == "false" ]]; then
    echo -e "${BLUE}📈 Scaling deployment $DEPLOYMENT_NAME back to $ORIGINAL_REPLICAS...${NC}"
    kubectl scale deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --replicas="$ORIGINAL_REPLICAS"
fi

# Restore ArgoCD Policy exactly as it was
if [[ "$HAS_ARGOCD_APP" == "true" && -n "$SYNC_POLICY" ]]; then
    echo -e "${BLUE}▶️  Restoring ArgoCD Auto-Sync for $ARGOCD_APP...${NC}"
    kubectl patch application -n argocd "$ARGOCD_APP" --type merge -p "{\"spec\":{\"syncPolicy\":{\"automated\":$SYNC_POLICY}}}"
fi

echo -e "${GREEN}✨ Migration successful!${NC}"
