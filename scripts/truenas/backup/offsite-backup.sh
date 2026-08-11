#!/usr/bin/env bash

VERSION="v3.9.0"

echo -e "Offsite Backup Script ${VERSION}"

set -Eeuo pipefail

# --- CONFIGURATION ---
DAILY_POOLS=("ssd1")
WEEKLY_POOLS=("hdd")
WEEKLY_BACKUP_DAY="7"
BLACKLISTED_DATASETS=("ssd1/ix-apps" "ssd1/bitmonero")

SNAP_NAME="restic-backup-$$"
TMP_ROOT="/tmp/restic-backup"
LOCK_FILE="/tmp/offsite-restic-backup.lock"

REPO="rclone:gdrive3:/nas-backup/"
CONFIG_DIR="/root/.config/restic"
export RESTIC_PASSWORD_FILE="$CONFIG_DIR/password"
export RCLONE_BWLIMIT="1.25M:12.5M"

declare -a POOLS_TO_PROCESS
LOCK_ACQUIRED=false

mount_exists() {
    findmnt -M "$1" -n >/dev/null 2>&1
}

unmount_all_at() {
    local mountpoint=$1

    # A failed/interrupted run can leave more than one mount stacked at the
    # same target. Remove every layer, not just the visible one.
    while mount_exists "$mountpoint"; do
        echo "Unmounting: $mountpoint"
        if ! umount "$mountpoint"; then
            echo "Warning: Failed to unmount $mountpoint" >&2
            return 1
        fi
    done
}

cleanup_tmp_mounts() {
    local -a mountpoints=()

    mapfile -t mountpoints < <(
        findmnt -R -n -o TARGET "$TMP_ROOT" 2>/dev/null |
            awk '{ depth = gsub(/\//, "/"); print depth "\t" $0 }' |
            sort -rn -k1,1 |
            cut -f2- |
            awk '!seen[$0]++'
    )

    local mountpoint
    for mountpoint in "${mountpoints[@]}"; do
        unmount_all_at "$mountpoint" || return 1
    done
}

prepare_tmp_root() {
    if findmnt -R -n -o TARGET "$TMP_ROOT" >/dev/null 2>&1; then
        echo "Removing stale temporary mounts below $TMP_ROOT..."
        cleanup_tmp_mounts
    fi

    if findmnt -R -n -o TARGET "$TMP_ROOT" >/dev/null 2>&1; then
        echo "FATAL: Mounts still exist below $TMP_ROOT; refusing to continue." >&2
        exit 1
    fi

    rm -rf "$TMP_ROOT"
    mkdir -p "$TMP_ROOT"
}

# --- CORE FUNCTIONS ---

# shellcheck disable=SC2329
cleanup() {
    echo "--- CLEANUP ---"
    if [ "$LOCK_ACQUIRED" != true ]; then
        echo "Skipping cleanup because this process did not acquire the backup lock."
        return
    fi

    if ! cleanup_tmp_mounts; then
        echo "Warning: Failed to fully clean temporary mounts; retaining ZFS snapshots." >&2
        return
    fi

    local ALL_POOLS
    mapfile -t ALL_POOLS < <(printf "%s\n" "${DAILY_POOLS[@]}" "${WEEKLY_POOLS[@]}" | sort -u)
    echo "Searching for and deleting old restic backup snapshots..."
    for pool in "${ALL_POOLS[@]}"; do
        zfs list -H -o name -t snapshot -r "$pool" |
            awk -v pool="$pool" '$0 ~ "^" pool "@restic-backup-"' |
            while IFS= read -r SNAP_TO_DESTROY; do
            echo "  -> Deleting snapshot: $SNAP_TO_DESTROY"
            zfs destroy -r "$SNAP_TO_DESTROY" || echo "  -> Warning: Failed to destroy $SNAP_TO_DESTROY"
        done
    done

    echo "Deleting temporary folder: $TMP_ROOT"
    rm -rf "$TMP_ROOT"
    echo "Cleanup finished."
}

# shellcheck disable=SC2329
error_handler() {
    echo "--- SCRIPT FAILED (Exit Code: $?) ---"
}

determine_pools_to_process() {
    local day_of_week
    day_of_week=$(date +%u)
    echo "Today is day $day_of_week. (Weekly backup day: $WEEKLY_BACKUP_DAY)."
    
    POOLS_TO_PROCESS+=("${DAILY_POOLS[@]}")
    
    if [ "$day_of_week" -eq "$WEEKLY_BACKUP_DAY" ]; then
        echo "Weekly backup day! Adding weekly pools."
        POOLS_TO_PROCESS+=("${WEEKLY_POOLS[@]}")
    fi

    mapfile -t POOLS_TO_PROCESS < <(printf "%s\n" "${POOLS_TO_PROCESS[@]}" | sort -u)
    
    if [ "${#POOLS_TO_PROCESS[@]}" -eq 0 ]; then
        echo "No pools scheduled for backup today. Exiting. ✅"
        exit 0
    fi
    echo "Pools to process: ${POOLS_TO_PROCESS[*]}"
}

mount_pool_datasets() {
    local pool=$1

    local dataset_list
    dataset_list=$(zfs list -r -H -o name -t filesystem "$pool" | grep -v "/\.")

    for item in "${BLACKLISTED_DATASETS[@]}"; do
        dataset_list=$(echo "$dataset_list" | grep -v "^${item}")
    done

    local snapshot_args=()
    while IFS= read -r dataset; do
        [ -z "$dataset" ] && continue
        snapshot_args+=("${dataset}@${SNAP_NAME}")
    done <<< "$dataset_list"

    if [ "${#snapshot_args[@]}" -gt 0 ]; then
        echo "Creating temporary snapshots (excluding zvols and blacklisted datasets)..."
        zfs snapshot "${snapshot_args[@]}"
    fi
    
    while IFS= read -r dataset; do
        [ -z "$dataset" ] && continue
        
        local dest_mount="${TMP_ROOT}/${dataset}"

        mkdir -p "$dest_mount"
        # Mount the snapshot itself instead of bind-mounting its dynamic .zfs
        # pathname. This avoids ZFS's lazy snapshot mount tree and gives
        # Restic one stable path on every run.
        mount -t zfs -o ro "${dataset}@${SNAP_NAME}" "$dest_mount"

        local mounted_source
        mounted_source=$(findmnt -M "$dest_mount" -n -o SOURCE | tail -n 1)
        if [ "$mounted_source" != "${dataset}@${SNAP_NAME}" ]; then
            echo "FATAL: $dest_mount is not mounted from ${dataset}@${SNAP_NAME} (got: ${mounted_source:-nothing})." >&2
            exit 1
        fi

        echo "  -> Mounted: $dataset"
    done <<< "$dataset_list"
}

run_restic_backup() {
    local pool=$1
    local backup_path="${TMP_ROOT}/${pool}"

    if [ -d "$backup_path" ]; then
        echo "Starting Restic backup for: $backup_path"
        restic backup "$backup_path" --repo "$REPO" --tag "nas-backup" --tag "$(hostname)" --tag "$pool"
    else
        echo "ERROR: Backup directory $backup_path does not exist." >&2
        exit 1
    fi
}

run_maintenance() {
    echo "--- GLOBAL TASKS ---"
    for pool in "${POOLS_TO_PROCESS[@]}"; do
        echo "Applying retention policy for: $pool"
        restic forget --repo "$REPO" --tag "$pool" --keep-daily 7 --keep-weekly 4 --keep-monthly 6
    done

    echo "Pruning repository..."
    restic prune --repo "$REPO"

    local check_counter_file="$CONFIG_DIR/restic_check_counter"
    local check_subset_total=7
    [ ! -f "$check_counter_file" ] && echo 0 > "$check_counter_file"

    local current_check
    current_check=$(cat "$check_counter_file")
    local next_check=$(( (current_check % check_subset_total) + 1 ))
    echo "$next_check" > "$check_counter_file"

    echo "Restic check on data subset $next_check/$check_subset_total..."
    restic check --repo "$REPO" --read-data-subset "$next_check/$check_subset_total"
}

# --- EXECUTION ---
trap error_handler ERR
trap cleanup EXIT

echo ">>> Starting backup process: $(date)"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "FATAL: Another offsite backup process holds $LOCK_FILE." >&2
    exit 1
fi
LOCK_ACQUIRED=true

prepare_tmp_root

determine_pools_to_process

for pool in "${POOLS_TO_PROCESS[@]}"; do
    echo "--- PROCESSING POOL: $pool ---"
    mount_pool_datasets "$pool"
    run_restic_backup "$pool"
done

run_maintenance

echo ">>> Backup process finished successfully: $(date)"
exit 0
