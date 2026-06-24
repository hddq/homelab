#!/usr/bin/env bash

log "🔧 Setting up build env..."
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
    set +u
    # shellcheck disable=SC2086
    repopick $CHERRYPICKS
    set -u
fi

log "🩹 Patching lineage makefiles with OTA updater URI..."
UPDATER_URI="https://raw.githubusercontent.com/hddq/lineage-ota/main/test/${DEVICE}.json"

MAIN_MAKEFILE=$(find device/ -name "lineage_${DEVICE}.mk" -type f | head -n 1)
if [[ -z "$MAIN_MAKEFILE" ]]; then
    MAIN_MAKEFILE=$(find device/ -path "*/${DEVICE}/lineage.mk" -type f | head -n 1)
fi

DEVICE_DIR=""
if [[ -n "$MAIN_MAKEFILE" ]]; then
    DEVICE_DIR=$(dirname "$MAIN_MAKEFILE")
fi
if [[ -z "$DEVICE_DIR" ]]; then
    DEVICE_DIR=$(find device/ -type d -name "$DEVICE" | head -n 1)
fi

if [[ -n "$DEVICE_DIR" && -d "$DEVICE_DIR" ]]; then
    log "Device directory: $DEVICE_DIR"
    mapfile -t MK_FILES < <(grep -rl "lineage.updater.uri" "$DEVICE_DIR" --include="*.mk" || true)
    
    if [[ ${#MK_FILES[@]} -gt 0 ]]; then
        for mk_file in "${MK_FILES[@]}"; do
            log "Replacing existing lineage.updater.uri in $mk_file..."
            python3 "$SCRIPT_DIR/scripts/worker/patch_updater.py" "$mk_file" "$UPDATER_URI"
        done
    else
        if [[ -n "$MAIN_MAKEFILE" && -f "$MAIN_MAKEFILE" ]]; then
            log "No existing lineage.updater.uri found. Appending to main makefile: $MAIN_MAKEFILE"
            python3 "$SCRIPT_DIR/scripts/worker/patch_updater.py" "$MAIN_MAKEFILE" "$UPDATER_URI"
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

log "🏗️  Building LineageOS for $DEVICE..."
BUILD_START=$(date +%s)
mka bacon
BUILD_END=$(date +%s)
log "✅ Build finished in $(( (BUILD_END - BUILD_START) / 60 ))min"
