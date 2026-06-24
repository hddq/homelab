#!/usr/bin/env bash
# LineageOS Build Trigger & Worker Script
# Designed to run both locally (as orchestrator) and remotely (as build worker inside the VM)
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Helper: Logging
# ─────────────────────────────────────────────────────────────────────────────
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] \e[31mERROR:\e[0m $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# Configuration and Paths (Local and Remote)
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS_FILE="$SCRIPT_DIR/../ansible/vars/lineage_vm.yaml"
MANIFESTS_DIR="$SCRIPT_DIR/manifests"

# Defaults
DEVICE="marble"
BRANCH="lineage-23.2"
SYNC="false"
CLEAN="dirty"
CHERRYPICKS="489879 489705 488403"
WORKER_MODE="false"

# ── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --worker)
            WORKER_MODE="true"
            ;;
        -d|--device)
            DEVICE="$2"
            shift
            ;;
        -b|--branch)
            BRANCH="$2"
            shift
            ;;
        -s|--sync)
            if [[ $# -gt 1 ]] && [[ "$2" == "true" || "$2" == "false" ]]; then
                SYNC="$2"
                shift
            else
                SYNC="true"
            fi
            ;;
        -c|--clean)
            if [[ $# -gt 1 ]] && [[ "$2" == "clean" || "$2" == "dirty" ]]; then
                CLEAN="$2"
                shift
            else
                CLEAN="clean"
            fi
            ;;
        --dirty)
            CLEAN="dirty"
            ;;
        -cp|--cherrypick|--cherry-pick)
            CHERRYPICKS="$2"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  -d, --device <codename>    Device codename (e.g., marble)"
            echo "  -b, --branch <branch>      LineageOS branch (default: lineage-23.2)"
            echo "  -s, --sync                 Sync repo before building (default: false)"
            echo "  -c, --clean                Perform clean build (clobber)"
            echo "      --dirty                Perform dirty build (default)"
            echo "  -cp, --cherrypick <ids>    Space-separated list of Gerrit change numbers/IDs to cherrypick"
            echo "  --worker                   Internal use: Run in worker mode on the VM"
            exit 0
            ;;
        *)
            error "Unknown argument: $1. Use -h or --help for usage."
            exit 1
            ;;
    esac
    shift
done

# ─────────────────────────────────────────────────────────────────────────────
# Host Orchestrator Mode (Runs on your local control machine)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$WORKER_MODE" == "false" ]]; then
    log "🖥️  Running in Host Orchestrator Mode..."
    
    # Read VM configurations from Ansible vars
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
        BUILD_USER="hddq" # Default fallback
    fi

    log "📡 Lineage Builder VM: $BUILD_USER@$VM_IP"

    # Handle interactive device selection if --device is not passed
    if [[ -z "$DEVICE" ]]; then
        if [[ -d "$MANIFESTS_DIR" ]]; then
            # Find all .xml files in manifests dir
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

    # Verify device manifest exists
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

    read -rp "Press Enter to start build or Ctrl+C to cancel..."

    # Check if build is already running on VM
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

    log "📤 Uploading build script..."
    scp "${BASH_SOURCE[0]}" "$BUILD_USER@$VM_IP:/home/$BUILD_USER/build.sh"

    # Build remote command line dynamically to avoid quoting and parser issues
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

    log "🚀 Launching build in tmux session 'lineage-build' on VM..."
    # Launch in a tmux session
    # shellcheck disable=SC2029
    ssh "$BUILD_USER@$VM_IP" "tmux new-session -d -s lineage-build \"$REMOTE_CMD; exec bash\""

    log "✅ Build triggered!"
    echo "------------------------------------------------------------"
    echo "The build is running inside a tmux session named 'lineage-build' on the VM."
    echo "To attach to the session manually and watch or interact:"
    echo "  ssh -t $BUILD_USER@$VM_IP \"tmux a -t lineage-build\""
    echo "------------------------------------------------------------"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Remote Worker Mode (Runs inside the VM)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$WORKER_MODE" == "true" ]]; then
    if [[ -z "$DEVICE" ]]; then
        error "Worker mode requires a device specified with --device."
        exit 1
    fi

    BUILD_DIR="$HOME/android/lineage"
    OTA_REPO_DIR="$HOME/lineage-ota"
    DATE_STR=$(date +%Y%m%d_%H%M%S)

    # Configure build environment variables explicitly
    # (Since non-interactive shells inside tmux do not load ~/.bashrc)
    export PATH="$HOME/bin:$PATH"
    export OUT_DIR="out"
    export NINJA_ARGS="-j8"
    export MAKE_JOBS=8
    export USE_CCACHE=1
    export CCACHE_EXEC=/usr/bin/ccache
    export CCACHE_DIR="$HOME/.ccache"

    log "========================================================="
    log "LineageOS Build Worker Started"
    log "Device:      $DEVICE"
    log "Branch:      $BRANCH"
    log "Sync:        $SYNC"
    log "Clean:       $CLEAN"
    log "Cherrypicks: $CHERRYPICKS"
    log "========================================================="

    # ── repo sync ────────────────────────────────────────
    cd "$BUILD_DIR"

    if [[ "$SYNC" == "true" ]]; then
        log "🔄 Running repo sync..."
        repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)"
    fi

    # ── build env ────────────────────────────────────────
    log "🔧 Setting up build env..."
    # AOSP/Lineage build environment scripts reference many unbound variables.
    # We temporarily disable the 'unbound variables' check (-u) while sourcing envsetup.sh.
    set +u
    # shellcheck disable=SC1091
    source build/envsetup.sh
    set -u

    log "🍳 Running breakfast for $DEVICE..."
    set +u
    breakfast "$DEVICE"
    set -u

    if [[ -n "$CHERRYPICKS" ]]; then
        log "🍒 Cherry-picking changes from Lineage Gerrit..."
        # Run repopick with the provided change IDs
        set +u
        # shellcheck disable=SC2086
        repopick $CHERRYPICKS
        set -u
    fi

    # ── Patch OTA Updater URI ────────────────────────────
    log "🩹 Patching lineage makefiles with OTA updater URI..."
    UPDATER_URI="https://raw.githubusercontent.com/hddq/lineage-ota/main/test/${DEVICE}.json"

    # Find the main lineage makefile for appending if needed
    MAIN_MAKEFILE=$(find device/ -name "lineage_${DEVICE}.mk" -type f | head -n 1)
    if [[ -z "$MAIN_MAKEFILE" ]]; then
        MAIN_MAKEFILE=$(find device/ -path "*/${DEVICE}/lineage.mk" -type f | head -n 1)
    fi

    # Find the device tree directory
    DEVICE_DIR=""
    if [[ -n "$MAIN_MAKEFILE" ]]; then
        DEVICE_DIR=$(dirname "$MAIN_MAKEFILE")
    fi
    if [[ -z "$DEVICE_DIR" ]]; then
        DEVICE_DIR=$(find device/ -type d -name "$DEVICE" | head -n 1)
    fi

    if [[ -n "$DEVICE_DIR" && -d "$DEVICE_DIR" ]]; then
        log "Device directory: $DEVICE_DIR"
        
        # Find all .mk files containing lineage.updater.uri
        mapfile -t MK_FILES < <(grep -rl "lineage.updater.uri" "$DEVICE_DIR" --include="*.mk" || true)
        
        if [[ ${#MK_FILES[@]} -gt 0 ]]; then
            for mk_file in "${MK_FILES[@]}"; do
                log "Replacing existing lineage.updater.uri in $mk_file..."
                python3 -c '
import sys
import re

makefile = sys.argv[1]
uri = sys.argv[2]

with open(makefile, "r") as f:
    content = f.read()

pattern = r"lineage\.updater\.uri\s*=\s*\S+"
new_content = re.sub(pattern, f"lineage.updater.uri={uri}", content)

with open(makefile, "w") as f:
    f.write(new_content)
' "$mk_file" "$UPDATER_URI"
            done
        else
            # If not found anywhere, append it to the main makefile
            if [[ -n "$MAIN_MAKEFILE" && -f "$MAIN_MAKEFILE" ]]; then
                log "No existing lineage.updater.uri found. Appending to main makefile: $MAIN_MAKEFILE"
                python3 -c '
import sys

makefile = sys.argv[1]
uri = sys.argv[2]

with open(makefile, "r") as f:
    content = f.read()

new_content = content
if not new_content.endswith("\n"):
    new_content += "\n"
new_content += f"\nPRODUCT_SYSTEM_DEFAULT_PROPERTIES += \\\n    lineage.updater.uri={uri}\n"

with open(makefile, "w") as f:
    f.write(new_content)
' "$MAIN_MAKEFILE" "$UPDATER_URI"
            else
                error "Could not find a lineage makefile to append the updater URI!"
                exit 1
            fi
        fi
    else
        error "Could not locate device directory for $DEVICE!"
        exit 1
    fi

    if [[ "$CLEAN" == "clean" ]]; then
        log "🧹 Clean build — running clobber..."
        mka clobber
    fi

    # ── build ─────────────────────────────────────────────
    log "🏗️  Building LineageOS for $DEVICE..."
    BUILD_START=$(date +%s)
    
    # Run the actual build
    mka bacon
    
    BUILD_END=$(date +%s)
    log "✅ Build finished in $(( (BUILD_END - BUILD_START) / 60 ))min"

    # ── find output zip ───────────────────────────────────
    log "🔍 Locating output ZIP..."
    # Find the most recently modified zip file in the output directory.
    # This is robust under set -e and doesn't depend on fragile build_date.txt files.
    ZIP=$(find "out/target/product/$DEVICE" -name "lineage-*.zip" -not -name "*-ota-*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -f2- -d' ' || true)

    if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
      error "Output ZIP not found in out/target/product/$DEVICE!"
      exit 1
    fi

    ZIP=$(realpath "$ZIP")
    ZIPNAME=$(basename "$ZIP")
    log "📦 ZIP found: $ZIP"

    # ── Upload to GitHub Releases ────────────────────────
    log "📤 Uploading ZIP to GitHub Releases..."
    if ! command -v gh &>/dev/null; then
        error "gh CLI is not installed on this VM! Cannot upload ZIP to GitHub Releases."
        exit 1
    fi

    # Check if gh is authenticated
    if ! gh auth status &>/dev/null; then
        error "gh CLI is not authenticated! Please log in on the VM using 'gh auth login'."
        exit 1
    fi

    TAG="build-${DEVICE}-${DATE_STR}"
    VERSION="${BRANCH#lineage-}"
    RELEASE_TITLE="LineageOS ${VERSION} - ${DEVICE} (${DATE_STR})"

    log "🏷️ Creating release tag '$TAG' on GitHub..."
    if gh release create "$TAG" "$ZIP" \
        --repo "hddq/lineage-ota" \
        --title "$RELEASE_TITLE" \
        --notes "Automated LineageOS UNOFFICIAL build for $DEVICE ($BRANCH) on $(date)"; then
        log "✅ GitHub Release created and ZIP uploaded!"
    else
        error "Failed to create GitHub Release."
        exit 1
    fi

    # ── Update OTA JSON in git repo ────────────────────────
    log "🌐 Cloning/updating OTA repository..."
    if [[ ! -d "$OTA_REPO_DIR" ]]; then
        git clone "git@github.com:hddq/lineage-ota.git" "$OTA_REPO_DIR"
    else
        cd "$OTA_REPO_DIR"
        # Force correct SSH remote and clean up any local changes/untracked files
        git remote set-url origin "git@github.com:hddq/lineage-ota.git" || true
        git reset --hard || true
        git clean -fd || true
    fi

    cd "$OTA_REPO_DIR"
    # Fetch latest references
    git fetch origin || true

    # Verify if 'main' exists on the remote repository
    if git show-ref --verify --quiet refs/remotes/origin/main; then
        git checkout -f main
        git pull origin main
    else
        # If it's a new or empty repository, we initialize a local 'main' branch
        log "ℹ️ Remote 'main' branch not found. Initializing a new local 'main' branch..."
        git checkout -B main || true
    fi

    log "✏️ Generating OTA JSON file..."
    mkdir -p test

    SHA256=$(sha256sum "$ZIP" | awk '{print $1}')
    SIZE=$(stat -c%s "$ZIP")
    # Extract ro.build.date.utc directly from the zip's metadata
    DATETIME=$(unzip -p "$ZIP" META-INF/com/android/metadata 2>/dev/null | grep post-timestamp | cut -d= -f2)
    if [[ -z "$DATETIME" ]]; then
        error "Failed to extract post-timestamp from OTA zip metadata."
        exit 1
    fi
    URL="https://github.com/hddq/lineage-ota/releases/download/${TAG}/${ZIPNAME}"

    JSON_FILE="test/${DEVICE}.json"

    jq -n \
      --arg fn "$ZIPNAME" \
      --arg id "$SHA256" \
      --arg url "$URL" \
      --argjson size "$SIZE" \
      --argjson dt "$DATETIME" \
      --arg ver "$VERSION" \
      '[{"datetime": $dt, "version": $ver, "type": "UNOFFICIAL", "files": [{"filename": $fn, "sha256": $id, "size": $size, "url": $url}]}]' \
      > "$JSON_FILE"

    log "📋 OTA JSON generated at $JSON_FILE"

    # Commit and Push
    git add "$JSON_FILE"
    if git diff --cached --quiet; then
        log "ℹ️ No changes in OTA JSON. Nothing to commit or push."
    else
        log "🚀 Committing and pushing OTA update to GitHub..."
        git commit -m "build: update ota JSON for $DEVICE to $ZIPNAME"
        git push origin main
    fi

    log "🎉 All done! Build complete, uploaded to GitHub Releases, and OTA JSON updated."
fi
