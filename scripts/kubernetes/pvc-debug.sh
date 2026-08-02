#!/usr/bin/env bash
set -e

VERSION="v1.0.0"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}PVC Debug Shell ${VERSION}${NC}"

# Usage: ./pvc-debug.sh <namespace> <pvc-name> [node-hostname]

NAMESPACE=$1
PVC_NAME=$2
NODE_HOSTNAME=$3

if [[ -z "$NAMESPACE" || -z "$PVC_NAME" ]]; then
    echo -e "${YELLOW}Usage:${NC} $0 <namespace> <pvc-name> [node-hostname]"
    echo -e "${YELLOW}Example:${NC} $0 media qbittorrent-pvc"
    echo -e "${YELLOW}Example (pinned node, needed for RWO PVCs bound elsewhere):${NC} $0 media qbittorrent-pvc k8s-prod-cp-1"
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

POD_NAME="pvc-debug-$(date +%s)"

# Build nodeSelector block only if a node was passed
NODE_SELECTOR_JSON=""
if [[ -n "$NODE_HOSTNAME" ]]; then
    echo -e "${BLUE}📌 Pinning to node: $NODE_HOSTNAME${NC}"
    NODE_SELECTOR_JSON="\"nodeSelector\": {\"kubernetes.io/hostname\": \"$NODE_HOSTNAME\"},"
fi

echo -e "${BLUE}🚀 Starting debug pod $POD_NAME (PVC: $PVC_NAME mounted at /mnt/data)...${NC}"

kubectl run "$POD_NAME" -n "$NAMESPACE" --restart=Never --image=alpine --overrides="
{
  \"spec\": {
    $NODE_SELECTOR_JSON
    \"containers\": [{
      \"name\": \"pvc-debug\",
      \"image\": \"alpine\",
      \"command\": [\"sh\"],
      \"stdin\": true,
      \"tty\": true,
      \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/mnt/data\"}]
    }],
    \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"$PVC_NAME\"}}]
  }
}" -it --rm -- sh

echo -e "${GREEN}✨ Debug pod cleaned up.${NC}"