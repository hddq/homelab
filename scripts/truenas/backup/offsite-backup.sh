#!/bin/bash
# v3.8.2

set -e

# --- CONFIGURATION ---
DAILY_POOLS=("ssd1")
WEEKLY_POOLS=("hdd")
WEEKLY_BACKUP_DAY="7"
BLACKLISTED_DATASETS=("ssd1/ix-apps" "ssd1/bitmonero")

SNAP_NAME="restic-backup-$$"
TMP_ROOT="/tmp/restic-backup"

REPO="rclone:gdrive-union:/nas-backup/"
CONFIG_DIR="/root/.config/restic"
export RESTIC_PASSWORD_FILE="$CONFIG_DIR/password"
export RCLONE_BWLIMIT="1.25M:12.5M"

declare -a MOUNT_POINTS
declare -a POOLS_TO_PROCESS

# --- CORE FUNCTIONS ---

cleanup() {
    echo "--- CLEANUP ---"
    if [ ${#MOUNT_POINTS[@]} -gt 0 ]; then
        for mp in $(printf "%s\n" "${MOUNT_POINTS[@]}" | sort -r); do
            echo "Unmounting: $mp"
            umount "$mp" || echo "Warning: Failed to unmount $mp"
        done
    fi

    local ALL_POOLS=($(printf "%s\n" "${DAILY_POOLS[@]}" "${WEEKLY_POOLS[@]}" | sort -u))
    echo "Searching for and deleting old restic backup snapshots..."
    for pool in "${ALL_POOLS[@]}"; do
        zfs list -H -o name -t snapshot | grep "${pool}@restic-backup-" | while IFS= read -r SNAP_TO_DESTROY; do
            echo "  -> Deleting snapshot: $SNAP_TO_DESTROY"
            zfs destroy -r "$SNAP_TO_DESTROY" || echo "  -> Warning: Failed to destroy $SNAP_TO_DESTROY"
        done
    done

    echo "Deleting temporary folder: $TMP_ROOT"
    rm -rf "$TMP_ROOT"
    echo "Cleanup finished."
}

error_handler() {
    echo "--- SCRIPT FAILED (Exit Code: $?) ---"
}

determine_pools_to_process() {
    local day_of_week=$(date +%u)
    echo "Today is day $day_of_week. (Weekly backup day: $WEEKLY_BACKUP_DAY)."
    
    POOLS_TO_PROCESS+=("${DAILY_POOLS[@]}")
    
    if [ "$day_of_week" -eq "$WEEKLY_BACKUP_DAY" ]; then
        echo "Weekly backup day! Adding weekly pools."
        POOLS_TO_PROCESS+=("${WEEKLY_POOLS[@]}")
    fi

    POOLS_TO_PROCESS=($(printf "%s\n" "${POOLS_TO_PROCESS[@]}" | sort -u))
    
    if [ ${#POOLS_TO_PROCESS[@]} -eq 0 ]; then
        echo "No pools scheduled for backup today. Exiting. ✅"
        exit 0
    fi
    echo "Pools to process: ${POOLS_TO_PROCESS[*]}"
}

mount_pool_datasets() {
    local pool=$1
    echo "Creating temporary snapshot: ${pool}@${SNAP_NAME}"
    zfs snapshot -r "${pool}@${SNAP_NAME}"

    local dataset_list=$(zfs list -r -H -o name "$pool" | grep -v "/\.")

    for item in "${BLACKLISTED_DATASETS[@]}"; do
        dataset_list=$(echo "$dataset_list" | grep -v "^${item}")
    done
    
    while IFS= read -r dataset; do
        [ -z "$dataset" ] && continue
        
        local source_snap="/mnt/${dataset}/.zfs/snapshot/${SNAP_NAME}"
        local dest_mount="${TMP_ROOT}/${dataset}"

        if [ -d "$source_snap" ]; then
            mkdir -p "$dest_mount"
            mount --bind "$source_snap" "$dest_mount"
            MOUNT_POINTS+=("$dest_mount")
            echo "  -> Mounted: $dataset"
        else
            echo "FATAL: Snapshot path '$source_snap' missing!" >&2
            exit 1
        fi
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

    local current_check=$(cat "$check_counter_file")
    local next_check=$(( (current_check % check_subset_total) + 1 ))
    echo "$next_check" > "$check_counter_file"

    echo "Restic check on data subset $next_check/$check_subset_total..."
    restic check --repo "$REPO" --read-data-subset "$next_check/$check_subset_total"
}

# --- EXECUTION ---
trap error_handler ERR
trap cleanup EXIT

echo ">>> Starting backup process: $(date)"

determine_pools_to_process

for pool in "${POOLS_TO_PROCESS[@]}"; do
    echo "--- PROCESSING POOL: $pool ---"
    mount_pool_datasets "$pool"
    run_restic_backup "$pool"
done

run_maintenance

echo ">>> Backup process finished successfully: $(date)"
exit 0