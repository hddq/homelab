#!/usr/bin/env bash

log "🔍 Locating output ZIP..."
ZIP=$(find "out/target/product/$DEVICE" -name "lineage-*.zip" -not -name "*-ota-*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -f2- -d' ' || true)

if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
  error "Output ZIP not found in out/target/product/$DEVICE!"
  exit 1
fi

ZIP=$(realpath "$ZIP")
ZIPNAME=$(basename "$ZIP")
log "📦 ZIP found: $ZIP"

log "📤 Uploading ZIP to GitHub Releases..."
if ! command -v gh &>/dev/null; then
    error "gh CLI is not installed on this VM! Cannot upload ZIP to GitHub Releases."
    exit 1
fi

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

log "🌐 Cloning/updating OTA repository..."
if [[ ! -d "$OTA_REPO_DIR" ]]; then
    git clone "git@github.com:hddq/lineage-ota.git" "$OTA_REPO_DIR"
else
    cd "$OTA_REPO_DIR" || exit 1
    git remote set-url origin "git@github.com:hddq/lineage-ota.git" || true
    git reset --hard || true
    git clean -fd || true
fi

cd "$OTA_REPO_DIR" || exit 1
git fetch origin || true

if git show-ref --verify --quiet refs/remotes/origin/main; then
    git checkout -f main
    git pull origin main
else
    log "ℹ️ Remote 'main' branch not found. Initializing a new local 'main' branch..."
    git checkout -B main || true
fi

log "✏️ Generating OTA JSON file..."
mkdir -p test

SHA256=$(sha256sum "$ZIP" | awk '{print $1}')
SIZE=$(stat -c%s "$ZIP")
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

git add "$JSON_FILE"
if git diff --cached --quiet; then
    log "ℹ️ No changes in OTA JSON. Nothing to commit or push."
else
    log "🚀 Committing and pushing OTA update to GitHub..."
    git commit -m "build: update ota JSON for $DEVICE to $ZIPNAME"
    git push origin main
fi

log "🎉 All done! Build complete, uploaded to GitHub Releases, and OTA JSON updated."
