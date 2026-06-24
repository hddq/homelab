#!/usr/bin/env bash

if [[ "$SYNC" == "true" ]]; then
    log "🔄 Running repo sync..."
    repo sync -c --no-clone-bundle --no-tags -j"$(nproc --all)"
fi
