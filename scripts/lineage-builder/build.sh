#!/usr/bin/env bash
# LineageOS Build Trigger Wrapper
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
export DEVICE=""
export BRANCH="lineage-23.2"
export SYNC="false"
export CLEAN="dirty"
export CHERRYPICKS="489879 489705 488403"
WORKER_MODE="false"
export SKIP_OTA="false"

# ── Parse Arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --worker)
            WORKER_MODE="true"
            ;;
        -d|--device)
            export DEVICE="$2"
            shift
            ;;
        -b|--branch)
            export BRANCH="$2"
            shift
            ;;
        -s|--sync)
            if [[ $# -gt 1 ]] && [[ "$2" == "true" || "$2" == "false" ]]; then
                export SYNC="$2"
                shift
            else
                export SYNC="true"
            fi
            ;;
        -c|--clean)
            if [[ $# -gt 1 ]] && [[ "$2" == "clean" || "$2" == "dirty" ]]; then
                export CLEAN="$2"
                shift
            else
                export CLEAN="clean"
            fi
            ;;
        --dirty)
            export CLEAN="dirty"
            ;;
        --no-ota)
            export SKIP_OTA="true"
            ;;
        -cp|--cherrypick|--cherry-pick)
            export CHERRYPICKS="$2"
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
            echo "      --no-ota               Build ROM only, skip OTA release/upload"
            echo "  -cp, --cherrypick <ids>    Space-separated list of Gerrit change numbers/IDs to cherrypick"
            echo "  --worker                   Internal use: Run in worker mode on the VM"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1. Use -h or --help for usage." >&2
            exit 1
            ;;
    esac
    shift
done

if [[ "$WORKER_MODE" == "false" ]]; then
    exec "$SCRIPT_DIR/scripts/orchestrator.sh"
else
    exec "$SCRIPT_DIR/scripts/worker/main.sh"
fi
