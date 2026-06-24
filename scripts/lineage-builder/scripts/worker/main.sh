#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/common.sh"

if [[ -z "$DEVICE" ]]; then
    error "Worker mode requires a device specified with --device."
    exit 1
fi

BUILD_DIR="$HOME/android/lineage"
OTA_REPO_DIR="$HOME/lineage-ota"
DATE_STR=$(date +%Y%m%d_%H%M%S)

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

# Export necessary variables for the sub-scripts
export SCRIPT_DIR
export BUILD_DIR
export OTA_REPO_DIR
export DATE_STR

cd "$BUILD_DIR" || exit 1

# shellcheck disable=SC1091
source "$SCRIPT_DIR/worker/sync.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/worker/build_rom.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/worker/release.sh"
