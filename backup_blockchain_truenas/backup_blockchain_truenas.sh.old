#!/bin/bash
#
# ============================================================
# backup_blockchain_truenas.sh
# Gold Release v1.0.0
#
# Backup & restore script for blockchain nodes on TrueNAS
#
# Supported services:
#   - bitcoind
#   - monerod
#   - chia
#
# Design goals:
#   - deterministic
#   - headless-safe (except restore)
#   - ZFS-first (snapshots, replication)
#   - rsync as fallback / merge tool
#   - minimal persistent state
#
# Author: mratix
# Refactor & extensions: ChatGPT
# ============================================================
#

set -Eeuo pipefail

########################################
# Globals / Defaults
########################################

MODE="${MODE:-backup}"            # backup | restore | merge | verify
SERVICE="${SERVICE:-}"
POOL="${POOL:-}"
DATASET="${DATASET:-}"
SRCDIR="${SRCDIR:-}"
DESTDIR="${DESTDIR:-}"

FORCE="${FORCE:-false}"
DEBUG="${DEBUG:-false}"
DRY_RUN="${DRY_RUN:-false}"

RSYNC_EXCLUDES=(
  --exclude='.zfs'
  --exclude='.zfs/'
  --exclude='.zfs/*'
  --exclude='.snapshot/'
)
RSYNC_OPTS="${RSYNC_OPTS:--avihH --numeric-ids ${RSYNC_EXCLUDES} --delete --stats --info=progress2}"

LOGFILE="${SCLOGFILE:-/var/log/backup_blockchain_truenas.log}"
STATEFILE="/var/log/backup_blockchain_truenas.state"

########################################
# Logging helpers
########################################

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOGFILE"
}

warn() {
    log "WARNING: $*"
}

fatal() {
    log "ERROR: $*"
    exit 1
}

########################################
# Statefile helpers (minimal audit trail)
########################################

state_set() {
    local key="$1"
    local value="$2"

    if [ -f "$STATEFILE" ] && grep -q "^${key}=" "$STATEFILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$STATEFILE"
    else
        echo "${key}=${value}" >> "$STATEFILE"
    fi
}

########################################
# Config handling
########################################

# Usage:
#   load_config default.conf hpms1.conf machine.conf
#
# Rules:
# - Later files override earlier ones
# - CLI / environment variables override config
# - Missing files are ignored with warning

load_config() {
    local cfg

    for cfg in "$@"; do
        if [ -f "$cfg" ]; then
            log "Loading config: $cfg"
            # shellcheck source=/dev/null
            source "$cfg"
        else
            warn "Config file not found, skipping: $cfg"
        fi
    done
}

load_config_chain() {
    local cfg

    for cfg in "./config.conf" "./default.conf" "./machine.conf" "./${THIS_HOST}.conf"; do
        if [[ -f "$cfg" ]]; then
            load_config "$cfg"
        else
            log "WARNING: Config file not found, skipping: $cfg"
        fi
    done
}

# Apply CLI / environment overrides after config load
apply_overrides() {
    # Only override if variable is already set in env/CLI
    [ -n "${MODE+x}"    ] && MODE="$MODE"
    [ -n "${SERVICE+x}" ] && SERVICE="$SERVICE"
    [ -n "${POOL+x}"    ] && POOL="$POOL"
    [ -n "${DATASET+x}" ] && DATASET="$DATASET"
    [ -n "${SRCDIR+x}"  ] && SRCDIR="$SRCDIR"
    [ -n "${DESTDIR+x}" ] && DESTDIR="$DESTDIR"

    [ -n "${FORCE+x}"   ] && FORCE="$FORCE"
    [ -n "${DEBUG+x}"   ] && DEBUG="$DEBUG"
    [ -n "${DRY_RUN+x}" ] && DRY_RUN="$DRY_RUN"
}

########################################
# Preparation
########################################

prepare() {
    log "prepare(): start"
    log "Resolved paths:"
    log "  SRCDIR=${SRCDIR}"
    log "  DESTDIR=${DESTDIR}"
    log "  POOL=${POOL} DATASET=${DATASET}"

    [ -n "$SERVICE" ] || fatal "SERVICE not set"
    [ -n "$POOL" ]    || fatal "POOL not set"
    [ -n "$DATASET" ] || fatal "DATASET not set"
    [ -n "$SRCDIR" ]  || fatal "SRCDIR not set"
    [ -n "$DESTDIR" ] || fatal "DESTDIR not set"

    [ -d "$SRCDIR" ] || fatal "Source directory does not exist: $SRCDIR"

    mkdir -p "$DESTDIR" || fatal "Failed to create destination: $DESTDIR"

    log "prepare(): done"
}

########################################
# ZFS snapshot handling
########################################

take_snapshot() {
    local snapname="backup-$(date +%Y-%m-%d_%H-%M-%S)"

    log "take_snapshot(): ${POOL}/${DATASET}@${snapname}"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: zfs snapshot -r ${POOL}/${DATASET}@${snapname}"
        return 0
    fi

    zfs snapshot -r "${POOL}/${DATASET}@${snapname}" \
        || fatal "Snapshot creation failed"

    state_set last_snapshot "${POOL}/${DATASET}@${snapname}"
}

########################################
# Backup (rsync-based)
########################################

backup_blockchain() {
    log "backup_blockchain(): start"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: rsync $RSYNC_OPTS ${SRCDIR}/ ${DESTDIR}/"
        return 0
    fi

    log "Starting rsync from '${SRCDIR}/' to '${DESTDIR}/'"
    rsync $RSYNC_OPTS "${SRCDIR}/" "${DESTDIR}/" \
        || fatal "rsync backup failed"

rsync_exit=$?

case "$rsync_exit" in
  0)
    log "rsync completed successfully"
    ;;
  23|24)
    warn "rsync completed with warnings (code=$rsync_exit) – acceptable"
    ;;
  *)
    err "rsync failed (code=$rsync_exit)"
    return 1
    ;;
esac

    log "backup_blockchain(): done"
}

########################################
# Restore (never headless)
########################################

restore_blockchain() {
    [ "$FORCE" = true ] || fatal "Restore requires FORCE=true"

    warn "RESTORE MODE – this will overwrite live data"
    read -r -p "Type YES to continue: " confirm
    [ "$confirm" = "YES" ] || fatal "Restore aborted by user"

    log "restore_blockchain(): start"

    rsync $RSYNC_OPTS "${DESTDIR}/" "${SRCDIR}/" \
        || fatal "Restore failed"

    log "restore_blockchain(): done"
}

########################################
# Merge (rsync-based, snapshot protected)
########################################

merge_dirs() {
    log "merge_dirs(): start"

    take_snapshot

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: rsync $RSYNC_OPTS ${SRCDIR}/ ${DESTDIR}/"
        return 0
    fi

    rsync $RSYNC_OPTS "${SRCDIR}/" "${DESTDIR}/" \
        || fatal "Merge rsync failed"

    log "merge_dirs(): done"
}

########################################
# Metrics / audit
########################################

collect_metrics() {
    local runtime="$1"
    local diskusage

    diskusage="$(du -shL "$SRCDIR" 2>/dev/null | awk '{print $1}')"

    state_set last_run_service   "$SERVICE"
    state_set last_run_mode      "$MODE"
    state_set last_run_runtime_s "$runtime"
    state_set last_run_diskusage "$diskusage"
}

########################################
# Main
########################################

START_TS=$(date +%s)
THIS_HOST=${THIS_HOST:-$(hostname -s)}

log "Script started (mode=${MODE}, service=${SERVICE})"

load_config_chain

# Load configuration files (order matters)
# Example:
#   default.conf → host.conf → machine.conf
load_config \
    "./default.conf" \
    "./${THIS_HOST:-}.conf" \
    "./machine.conf"

apply_overrides

prepare

case "$MODE" in
    backup)
        take_snapshot
        backup_blockchain
        ;;
    restore)
        restore_blockchain
        ;;
    merge)
        merge_dirs
        ;;
    *)
        fatal "Unknown MODE: $MODE"
        ;;
esac

END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))

collect_metrics "$RUNTIME"

log "Script finished successfully"
exit 0
