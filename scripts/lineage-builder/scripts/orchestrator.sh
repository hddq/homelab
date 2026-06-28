#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

VARS_FILE="$SCRIPT_DIR/../../../ansible/vars/lineage_vm.yaml"
MANIFESTS_DIR="$SCRIPT_DIR/../manifests"

log "🖥️  Running in Host Orchestrator Mode..."

if [[ ! -f "$VARS_FILE" ]]; then
    error "Ansible vars file not found at $VARS_FILE."
    exit 1
fi

VM_IP=$(python3 -c "
import re
try:
    content = open('$VARS_FILE').read()
    m = re.search(r'ip:\s*[\"\'\']?([^\"\'\']+)[\"\'\']?', content)
    print(m.group(1) if m else '')
except Exception:
    pass
" 2>/dev/null || true)

BUILD_USER=$(python3 -c "
import re
try:
    content = open('$VARS_FILE').read()
    m = re.search(r'build_user:\s*[\"\'\']?([^\"\'\']+)[\"\'\']?', content)
    print(m.group(1) if m else '')
except Exception:
    pass
" 2>/dev/null || true)

if [[ -z "$VM_IP" ]]; then
    error "Could not parse VM IP from $VARS_FILE. Please check the file structure."
    exit 1
fi
if [[ -z "$BUILD_USER" ]]; then
    BUILD_USER="hddq"
fi

log "📡 Lineage Builder VM: $BUILD_USER@$VM_IP"

if [[ -z "$DEVICE" ]]; then
    if [[ -d "$MANIFESTS_DIR" ]]; then
        mapfile -t xml_files < <(find "$MANIFESTS_DIR" -maxdepth 1 -name "*.xml" -printf "%f\n" 2>/dev/null | sed 's/\.xml$//' | sort || true)
        if [[ ${#xml_files[@]} -eq 0 ]]; then
            error "No device manifests found in $MANIFESTS_DIR. Please create manifests/<device>.xml first."
            exit 1
        fi
        
        echo "Available target devices:"
        for i in "${!xml_files[@]}"; do
            echo "  $((i+1))) ${xml_files[$i]}"
        done
        
        read -rp "Select a device [1-${#xml_files[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#xml_files[@]})); then
            DEVICE="${xml_files[$((choice-1))]}"
        else
            error "Invalid choice."
            exit 1
        fi
    else
        error "No device specified and manifests/ directory does not exist."
        exit 1
    fi
fi

DEVICE_MANIFEST="$MANIFESTS_DIR/${DEVICE}.xml"
if [[ ! -f "$DEVICE_MANIFEST" ]]; then
    error "Device manifest for '$DEVICE' not found at: $DEVICE_MANIFEST"
    error "Please create this manifest file with the vendor and device tree details."
    exit 1
fi

log "📱 Target Device:   $DEVICE"
log "🌿 Target Branch:   $BRANCH"
log "🔄 Sync Repos:      $SYNC"
log "🧹 Build Type:      $CLEAN"
if [[ -n "$CHERRYPICKS" ]]; then
    log "🍒 Cherry-picks:    $CHERRYPICKS"
fi
if [[ "$SKIP_OTA" == "true" ]]; then
    log "📵 Skip OTA:        yes"
fi

read -rp "Press Enter to start build or Ctrl+C to cancel..."

if ssh "$BUILD_USER@$VM_IP" "tmux has-session -t lineage-build 2>/dev/null"; then
    error "A build is already running in tmux session 'lineage-build' on the VM!"
    read -rp "Would you like to kill the running build and start a new one? [y/N] " kill_choice
    if [[ "$kill_choice" =~ ^[yY](es)?$ ]]; then
        log "Killing existing tmux session 'lineage-build'..."
        ssh "$BUILD_USER@$VM_IP" "tmux kill-session -t lineage-build"
    else
        log "Aborting."
        exit 0
    fi
fi

REMOTE_BUILD_DIR="/home/$BUILD_USER/android/lineage"
REMOTE_LOCAL_MANIFESTS="$REMOTE_BUILD_DIR/.repo/local_manifests"

log "🔗 Preparing remote folders on the builder VM..."
# shellcheck disable=SC2029
ssh "$BUILD_USER@$VM_IP" "mkdir -p '$REMOTE_LOCAL_MANIFESTS' && rm -f '$REMOTE_LOCAL_MANIFESTS'/*.xml"

log "📤 Uploading manifest for $DEVICE..."
scp "$DEVICE_MANIFEST" "$BUILD_USER@$VM_IP:$REMOTE_LOCAL_MANIFESTS/manifest.xml"

log "📤 Uploading scripts..."
# Copy the whole scripts directory
scp -r "$SCRIPT_DIR" "$BUILD_USER@$VM_IP:/home/$BUILD_USER/"
# Also copy build.sh
scp "$SCRIPT_DIR/../build.sh" "$BUILD_USER@$VM_IP:/home/$BUILD_USER/build.sh"

REMOTE_CMD="bash /home/$BUILD_USER/build.sh --worker --device '$DEVICE' --branch '$BRANCH'"
if [[ "$SYNC" == "true" ]]; then
    REMOTE_CMD="$REMOTE_CMD --sync"
fi
if [[ "$CLEAN" == "clean" ]]; then
    REMOTE_CMD="$REMOTE_CMD --clean"
else
    REMOTE_CMD="$REMOTE_CMD --dirty"
fi
if [[ -n "$CHERRYPICKS" ]]; then
    REMOTE_CMD="$REMOTE_CMD --cherrypick '$CHERRYPICKS'"
fi
if [[ "$SKIP_OTA" == "true" ]]; then
    REMOTE_CMD="$REMOTE_CMD --no-ota"
fi

log "🚀 Launching build in tmux session 'lineage-build' on VM..."
# shellcheck disable=SC2029
ssh "$BUILD_USER@$VM_IP" "tmux new-session -d -s lineage-build \"$REMOTE_CMD; exec bash\""

log "✅ Build triggered!"
echo "------------------------------------------------------------"
echo "The build is running inside a tmux session named 'lineage-build' on the VM."
echo "To attach to the session manually and watch or interact:"
echo "  ssh -t $BUILD_USER@$VM_IP \"tmux a -t lineage-build\""
echo "------------------------------------------------------------"
exit 0
