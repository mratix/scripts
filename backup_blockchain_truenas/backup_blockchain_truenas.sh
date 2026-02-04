#!/bin/bash
#
# ============================================================
# backup_blockchain_truenas.sh
# Gold Release v1.0.4
#
# Stable, production-ready release with verification & telemetry support
#
# Backup & restore script for blockchain nodes on TrueNAS
#
# Supported services:
#   - bitcoind
#   - monerod
#   - chia
#
# Supported long flags:
#   --mode:     backup|merge|verify|restore
#   --service:  bitcoind|monerod|chia
#   --debug
#   --dry-run
#   --force
#   --init-config
#   --help
#
# Design goals:
#   - deterministic
#   - headless-safe (except restore)
#   - ZFS-first (snapshots, replication)
#   - rsync as fallback / merge tool
#   - minimal persistent state
#
# Author: mratix
# Refactor & extensions: ChatGPT <- my big Thanks
# ============================================================
#

set -Eeuo pipefail

########################################
# Globals / Defaults
########################################

MODE="backup"                   # backup | merge | verify | restore
SERVICE=""                      # bitcoind|monerod|chia
POOL="${POOL:-}"
DATASET="${DATASET:-}"
SRC_BASE=""
DEST_BASE=""
SRCDIR="${SRCDIR:-$SRC_BASE/$SERVICE}"
DESTDIR="${DESTDIR:-$DEST_BASE/$SERVICE}"
FS_TYPE="${FS_TYPE:-unknown}"
RSYNC_EXCLUDES=(
  --exclude=.zfs
  --exclude=.zfs/*
  --exclude=.snapshot
)

RSYNC_OPTS=(-avihH --numeric-ids --delete --stats --info=progress2)

LOGFILE="${LOGFILE:-/var/log/backup_blockchain_truenas.log}"
STATEFILE="/var/log/backup_blockchain_truenas.state"
declare -A SERVICE_CT_MAP=(
  [bitcoind]="ix-bitcoind-bitcoind-1"
  [monerod]="ix-monerod-monerod-1"
  [chia]="ix-chia-farmer-1"
)
TELEMETRY_ENABLED=false
TELEMETRY_BACKEND=""    # influx|mysql

# Runtime flags:
# These MUST NOT be set via config files.
# CLI / environment only.
FORCE=false
DEBUG=false
DRY_RUN=false
INIT_CONFIG=false

########################################
# Logging helpers
########################################

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOGFILE"
}

warn() {
    log "WARNING: $*"
}

error() {
    log "ERROR: $*"
    exit 1
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

# Load configuration files (order matters)
#   default.conf → machine.conf → $THIS_HOST.conf
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


########################################
# Preparation
########################################

prepare() {
    log "prepare__ start"
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

    log "prepare__ done"
}

########################################
# ZFS snapshot handling
########################################

take_snapshot() {
    local snapname=backup-$(date +%Y-%m-%d_%H-%M-%S)

    log "take_snapshot__ ${POOL}/${DATASET}@${snapname}"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: zfs snapshot -r ${POOL}/${DATASET}@${snapname}"
        return 0
    fi

    zfs snapshot -r "${POOL}/${DATASET}@${snapname}" \
        && { telemetry_event "info" "snapshot created" "script"; } \
        || { fatal "Snapshot creation failed"; telemetry_event "fatal" "Snapshot creation failed" "script"; }

    LAST_SNAPSHOT="${POOL}/${DATASET}@${snapname}"
    state_set last_snapshot "$LAST_SNAPSHOT"
}

########################################
# Backup (rsync-based)
########################################

backup_blockchain() {
    log "backup_blockchain__ start"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: rsync ${RSYNC_OPTS[@]} ${SRCDIR}/ ${DESTDIR}/"
        return 0
    fi

    log "Starting rsync from ${SRCDIR}/ to ${DESTDIR}/"
    rsync ${RSYNC_OPTS[@]} ${RSYNC_EXCLUDES[@]} ${SRCDIR}/ ${DESTDIR}/
rsync_exit=$?

case "$rsync_exit" in
  0)
    log "rsync completed successfully"
    ;;
  23|24)
    warn "rsync completed with warnings code=$rsync_exit"
    db_log_event "warn" "rsync returned code $rsync_exit" "script"
    ;;
  *)
    fatal "rsync failed code=$rsync_exit"
    telemetry_event "error" "rsync failed code=$rsync_exit" "script"
    db_log_event "warn" "rsync returned code $rsync_exit" "script"
    ;;
esac

    log "backup_blockchain__ done"
}

########################################
# Restore (never headless)
########################################

restore_blockchain() {
    [ "$FORCE" = true ] || fatal "Restore requires FORCE=true"

    warn "RESTORE MODE – this will overwrite live data"
    read -r -p "Type YES to continue: " confirm
    [ "$confirm" = "YES" ] || fatal "Restore aborted by user"

    log "restore_blockchain__ start"

    rsync ${RSYNC_OPTS[@]} ${DESTDIR}/ ${SRCDIR}/ \
        || fatal "Restore failed"

    log "restore_blockchain__ done"
}

########################################
# Merge (rsync-based, snapshot protected)
########################################

merge_dirs() {
    log "merge_dirs__ start"

    take_snapshot

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: rsync ${RSYNC_OPTS[@]} ${SRCDIR}/ ${DESTDIR}/"
        return 0
    fi

    rsync ${RSYNC_OPTS[@]} ${SRCDIR}/ ${DESTDIR}/ \
        || fatal "Merge rsync failed"

    log "Merge completed successfully"
    telemetry_event "info" "merge completed" "script"
}

verify_backup() {
    log "verify_backup__ start"

    [ -d "$SRCDIR" ]  || fatal "Source directory missing: $SRCDIR"
    [ -d "$DESTDIR" ] || fatal "Backup directory missing: $DESTDIR"

    log "Verifying structure and size"

    local src_size dst_size
    src_size="$(du -sb $SRCDIR  | awk '{print $1}')"
    dst_size="$(du -sb $DESTDIR | awk '{print $1}')"

    log "Source size: $src_size bytes"
    log "Backup size: $dst_size bytes"

    if [[ "$src_size" -ne "$dst_size" ]]; then
        warn "Size mismatch detected (not fatal on ZFS)"
        telemetry_event "warn" "Size mismatch detected" "script"
        state_set verify_status "partial"
    fi

    log "Running rsync dry-run verify (no delete, no checksum)"
    rsync -nav \
        ${RSYNC_EXCLUDES[@]} \
        $SRCDIR/" "$DESTDIR/ \
        >"/tmp/verify-${SERVICE}.log"

    if [[ -s "/tmp/verify-${SERVICE}.log" ]]; then
        warn "Verify found differences"
        state_set verify_status "partial"
        return 10
    fi

    state_set verify_status "success"
    log "verify_backup__ done"
}


########################################
# Metrics / audit
########################################

collect_metrics() {
    local runtime="$1" exit_code="$2" diskusage src_size dst_size

    src_size="$(du -sb "$SRCDIR" 2>/dev/null | awk '{print $1}')"
    dst_size="$(du -sb "$DESTDIR" 2>/dev/null | awk '{print $1}')"
    diskusage="$(du -shL "$SRCDIR" 2>/dev/null | awk '{print $1}')"

    state_set last_run_service   "$SERVICE"
    state_set last_run_mode      "$MODE"
    state_set last_run_runtime_s "$runtime"
    state_set last_run_diskusage "$diskusage"
    state_set last_run_exit_code "$exit_code"

    $TELEMETRY_ENABLED && send_telemetry \
        "$runtime" "$exit_code" "$src_size" "$dst_size"
}

telemetry_event() {
    local level="$1"
    local msg="$2"
    local source="${3:-script}"

    [[ "$TELEMETRY_BACKEND" = "mysql" ]] || return 0
    [[ -n "${LAST_RUN_ID:-}" ]] || return 0

    mysql ... -e "
      INSERT INTO blockchain_backup_events
        (run_id, level, message, source, created_at)
      VALUES
        (${LAST_RUN_ID}, '$level', '$msg', '$source', NOW());
    " >/dev/null 2>&1 || true
}

send_telemetry() {
    local runtime="$1" exit="$2" src="$3" dst="$4"

    case "$TELEMETRY_BACKEND" in
        influx)
            #curl -sS -XPOST "$INFLUX_URL/write?db=$INFLUX_DB" \
            #  --data-binary \
            #  "backup,host=$THIS_HOST,service=$SERVICE,mode=$MODE runtime=${runtime},exit=${exit},src=${src},dst=${dst}"
            send_telemetry_influx "$runtime" "$exit" "$src" "$dst"
            ;;
        mysql)
            send_telemetry_mysql "$runtime" "$exit" "$src" "$dst"
            ;;
        *)
            warn "Unknown telemetry backend: $TELEMETRY_BACKEND"
            ;;
    esac
}

send_telemetry_mysql() {
    local runtime="$1"
    local exit="$2"
    local src="$3"
    local dst="$4"

    # Sanity checks
    command -v mysql >/dev/null 2>&1 || {
        warn "mysql client not found, skipping telemetry"
        return 0
    }

    [[ -n "${MYSQL_DB:-}" && -n "${MYSQL_USER:-}" ]] || {
        warn "MySQL telemetry not configured, skipping"
        return 0
    }

    local sql
    sql=$(cat <<EOF
INSERT INTO ${MYSQL_TABLE} (
    host, service, mode,
    runtime_s, exit_code,
    src_size_b, dst_size_b,
    snapshot
) VALUES (
    '${THIS_HOST}',
    '${SERVICE}',
    '${MODE}',
    ${runtime},
    ${exit},
    ${src:-NULL},
    ${dst:-NULL},
    '${LAST_SNAPSHOT:-}'
);
EOF
)

    mysql \
        -h "${MYSQL_HOST:-localhost}" \
        -P "${MYSQL_PORT:-3306}" \
        -u "$MYSQL_USER" \
        -p"$MYSQL_PASS" \
        "$MYSQL_DB" \
        -e "$sql" \
        >/dev/null 2>&1 \
        || warn "MySQL telemetry insert failed"
}

db_open_run() {
  local started_at
  started_at="$(date '+%Y-%m-%d %H:%M:%S')"

  mysql "$DB_NAME" <<SQL
INSERT INTO blockchain_backup_runs
  (host, service, mode, started_at)
VALUES
  ('$THIS_HOST', '$SERVICE', '$MODE', '$started_at');
SQL

  LAST_RUN_ID=$(mysql "$DB_NAME" -N -s -e "SELECT LAST_INSERT_ID();")

  [[ -n "$LAST_RUN_ID" ]] || fatal "Failed to obtain LAST_RUN_ID"

  log "DB run opened (id=$LAST_RUN_ID)"
}

db_log_event() {
  local level="$1"
  local msg="$2"
  local source="$3"

  mysql "$DB_NAME" <<SQL
INSERT INTO blockchain_backup_events
  (run_id, level, message, source, created_at)
VALUES
  ($LAST_RUN_ID, '$level', '$msg', '$source', NOW());
SQL
}

db_close_run() {
  mysql "$DB_NAME" <<SQL
UPDATE blockchain_backup_runs
SET
  runtime_s = $RUNTIME,
  exit_code = $EXIT_CODE
WHERE id = $LAST_RUN_ID;
SQL
}

detect_fs_type() {
  FS_TYPE="$(stat -f -c %T "$SRCDIR")"
}

init_config() {
  log "Initializing config files"

  local host
  host="$(hostname -s)"

  create_cfg "default.conf"   default
  create_cfg "machine.conf"   machine
  create_cfg "${host}.conf"   host

  log "Config initialization complete"
  log "Edit the files and rerun without --init-config"
}

create_cfg() {
  local file="$1"
  local type="$2"

  if [[ -f "$file" ]]; then
    warn "Config already exists, skipping: $file"
    return
  fi

  log "Creating $file"

  case "$type" in
    default)
      cat >"$file" <<'EOF'
# default.conf
# Lowest priority config

MODE=backup
DRY_RUN=true

RSYNC_OPTS="-avihH --numeric-ids --delete --stats --info=progress2"
EOF
      ;;
    machine)
      cat >"$file" <<'EOF'
# machine.conf
# Machine-wide settings

POOL="tank"
DATASET="blockchain"

SRC_BASE="/mnt/tank/blockchain"
DEST_BASE="/mnt/tank/backups"

USE_USB=false
USB_ID=""
USB_MOUNT="/mnt/usb"
EOF
      ;;
    host)
      cat >"$file" <<'EOF'
# Host-specific config
# Last in precedence chain

# Example:
# SERVICE="bitcoind"
# LOGFILE="/var/log/backup_blockchain_truenas.log"
EOF
      ;;
    *)
      fatal "Unknown config type: $type"
      ;;
  esac
}

parse_cli() {
  local OPTIONS
  OPTIONS=$(getopt -o '' \
    --long mode:,service:,debug,dry-run,force,help \
    -- "$@") || exit 1

  eval set -- "$OPTIONS"

  while true; do
    case "$1" in
      --mode)
        MODE="$2"
        shift 2
        ;;
      --service)
        SERVICE="$2"
        shift 2
        ;;
      --debug)
        DEBUG=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
        --init-config)
        INIT_CONFIG=true
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        fatal "Unknown option: $1"
        ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --mode         <backup|merge|verify|restore>
  --service      <bitcoind|monerod|chia>
  --debug        Enable bash xtrace
  --dry-run      Do not modify anything
  --force        Required for restore
  --init-config  Init new config files
  --help
EOF
}

########################################
# Main
########################################

START_TS=$(date +%s)
THIS_HOST=${THIS_HOST:-$(hostname -s)}
parse_cli "$@"
log "Script started (mode=${MODE}, service=${SERVICE})"
CT_NAME="${SERVICE_CT_MAP[$SERVICE]:-}"
$DEBUG && set -x

if $INIT_CONFIG; then
  init_config
  exit 0
fi

load_config_chain
prepare
db_open_run

if $USE_USB; then
  [[ -b "$USB_ID" ]] || fatal "USB device not found"
  DESTDIR="$USB_MOUNT/$SERVICE"
fi
EXIT_CODE=0

# --- execute part
case "$MODE" in
    backup)
        take_snapshot
        backup_blockchain
        verify_backup
        ;;
    merge)
        merge_dirs
        verify_backup
        ;;
    verify)
        verify_backup
        ;;
    restore)
        $FORCE || fatal "Restore requires --force"
        restore_blockchain
        verify_backup
        ;;
    *)
        fatal "Unknown MODE: $MODE"
        ;;
esac
EXIT_CODE=$?

END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))

# telemetry
END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))
collect_metrics "$RUNTIME" "$EXIT_CODE"
log "Script finished successfully"
exit "$EXIT_CODE"

