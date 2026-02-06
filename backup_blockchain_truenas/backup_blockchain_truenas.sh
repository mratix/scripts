#!/bin/bash
#
# ============================================================
# backup_blockchain_truenas.sh
# Gold Release v1.0.6
# Maintenance release: config handling, init-config fixes, stability
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
#   --verbose
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
#   - rsync as fallback (merge,verify tool)
#   - minimal persistent state
#
# Author: mratix
# Refactor & extensions: ChatGPT <- With best thanks to
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
SRCDIR=""
DESTDIR=""
RSYNC_OPTS=(-avihH --numeric-ids --mkpath --delete --stats --info=progress2)
RSYNC_EXCLUDES=(
  --exclude=.zfs
  --exclude=.zfs/*
  --exclude=.snapshot
)

LOGFILE="${LOGFILE:-/var/log/backup_blockchain_truenas.log}"
STATEFILE="${STATEFILE:-/var/log/backup_blockchain_truenas.state}"

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
VERIFY="${VERIFY:-true}"
VERBOSE="${VERBOSE:-false}"
DEBUG=false
DRY_RUN=false
INIT_CONFIG=false

########################################
# Logging helpers
########################################

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOGFILE"
}
info() {
    log "Info: $*"
}
vlog() {
    $VERBOSE || return 0
    log "$*"
}
warn() {
    log "Warning: $*"
}
error() {
    log "ERROR: $*"
    exit 1
}


########################################
# Statefile helpers (minimal audit trail)
########################################

state_set() {
    touch "$STATEFILE" 2>/dev/null || warn "Statefile not writable"

  if [ -f "$STATEFILE" ]; then
    local key="$1" value="$2"
    if grep -q "^${key}=" "$STATEFILE"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$STATEFILE"
    else
        echo "${key}=${value}" >> "$STATEFILE"
    fi
  fi
}

########################################
# Config handling
########################################

# Usage:
#   load_config machine.conf|your_config.conf
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
            # syntax check
            command -v shellcheck >/dev/null 2>&1 shellcheck source=$cfg || vlog "load_config__ shellcheck not found"
	    source "$cfg"
        else
            vlog "Config file not found, skipping: $cfg"
        fi
    done
}

# Load configuration files (order matters)
#   default.conf → machine.conf → $THIS_HOST.conf
load_config_chain() {
    local cfg

    # error: config files are normal in script-dir not $PWD located
    for cfg in "./config.conf" "./default.conf" "./machine.conf" "./${THIS_HOST}.conf"; do
        if [[ -f "$cfg" ]]; then
            #todo: check validity/acceptance of readed parameters
            load_config "$cfg"
        else
            vlog "Config file not found, skipping: $cfg"
        fi
    done
}


########################################
# Preparation
########################################

prepare() {
    touch "$STATEFILE" 2>/dev/null || warn "Statefile not writable: $STATEFILE"

    vlog "prepare__ start"
    log "Given is:"
    log "  POOL=${POOL} DATASET=${DATASET} SERVICE=${SERVICE}"
    log "Resolved paths:"
    log "  SRCDIR=${SRCDIR}"
    log "  DESTDIR=${DESTDIR}"
sleep 5 # give some time to look at the output
    [ -n "$SERVICE" ] || error "SERVICE not set"
    [ -n "$POOL" ]    || error "POOL not set"
    [ -n "$DATASET" ] || error "DATASET not set"
    [ -n "$SRCDIR" ]  || error "SRCDIR not set"
    [ -n "$DESTDIR" ] || error "DESTDIR not set"
    [ -d "$SRCDIR" ]  || error "Source directory does not exist: $SRCDIR"
    mkdir -p "$DESTDIR" || error "Failed to create destination: $DESTDIR"
    vlog "prepare__ done"
}

########################################
# ZFS snapshot handling
########################################

take_snapshot() {
    local snapname
    snapname="script-$(date +%Y-%m-%d_%H-%M-%S)"

    log "Snapshot ${POOL}/${DATASET}/${SERVICE}@${snapname} taken."

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: zfs snapshot -r ${POOL}/${DATASET}/${SERVICE}@${snapname}"
        return 0
    fi

    zfs snapshot -r "${POOL}/${DATASET}/${SERVICE}@${snapname}" \
        && { [[ -n "${LAST_RUN_ID:-}" ]] && telemetry_event "info" "snapshot created" "script"; } \
        || { error "Snapshot creation failed"; telemetry_event "error" "Snapshot creation failed" "script"; }

    LAST_SNAPSHOT="${POOL}/${DATASET}/${SERVICE}@${snapname}"
    state_set last_snapshot "$LAST_SNAPSHOT"
}

list_snapshots() {
    log "Listing snapshots for service: $SERVICE"

    zfs list -t snapshot -o name,creation \
        | awk -v ds="${POOL}/${DATASET}/${SERVICE}@" '
            $1 ~ "^"ds {
                snap=$1
                sub("^.*@", "", snap)

                type="unknown"
                if (snap ~ /^manual-/) type="MANUAL"
                else if (snap ~ /^backup-/) type="MANUAL"
                else if (snap ~ /^import-/) type="IMPORT"
                else if (snap ~ /^script-/) type="SCRIPT"
                else if (snap ~ /^auto-/) type="AUTO"

                printf "%-8s | %-25s | %s\n", type, snap, $2" "$3" "$4" "$5
            }
        ' \
        | sort -k3,3
}

########################################
# Backup (rsync-based)
########################################

backup_blockchain() {
    vlog "backup_blockchain__ start"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: rsync ${RSYNC_OPTS[*]} ${SRCDIR}/ ${DESTDIR}/"
        return 0
    fi

    log "Starting rsync from ${SRCDIR}/ to ${DESTDIR}/"
    rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" "$SRCDIR/" "$DESTDIR/"
rsync_exit=$?

case "$rsync_exit" in
  0)
    log "rsync completed successfully"
    ;;
  23|24)
    warn "rsync completed with warnings code=$rsync_exit"
    [[ -n "${LAST_RUN_ID:-}" ]] && db_log_event "warn" "rsync returned code $rsync_exit" "script"
    ;;
  *)
    error "rsync failed code=$rsync_exit"
    telemetry_event "error" "rsync failed code=$rsync_exit" "script"
    [[ -n "${LAST_RUN_ID:-}" ]] && db_log_event "warn" "rsync returned code $rsync_exit" "script"
    ;;
esac

    vlog "backup_blockchain__ done"
}

########################################
# Restore (never headless)
########################################

restore_blockchain() {
    [ "$FORCE" = true ] || error "Restore requires FORCE=true"

    warn "RESTORE MODE – this will overwrite live data"
if [ -t 0 ]; then
    read -r -p "Type YES to continue: " confirm
    [ "$confirm" = "YES" ] || error "Restore aborted by user"

    vlog "restore_blockchain__ start"

    rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" "$SRCDIR/" "$DESTDIR/" \
        || error "Restore failed"

    vlog "restore_blockchain__ done"
else
    error "Restore requires interactive terminal"
fi
}

########################################
# Merge (rsync-based, snapshot protected)
########################################

merge_dirs() {
    vlog "merge_dirs__ start"

    take_snapshot

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: rsync ${RSYNC_OPTS[*]} ${SRCDIR}/ ${DESTDIR}/"
        return 0
    fi

    rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" "$SRCDIR/" "$DESTDIR/" \
        || error "Merge rsync failed"

    log "Merge completed successfully"
    telemetry_event "info" "merge completed" "script"
}

verify_backup() {
    vlog "verify_backup__ start"

    [ -d "$SRCDIR" ]  || error "Source directory missing: $SRCDIR"
    [ -d "$DESTDIR" ] || error "Backup directory missing: $DESTDIR"

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
        "${RSYNC_EXCLUDES[@]}" \
        "$SRCDIR/" "$DESTDIR/" \
        >"/tmp/verify-${SERVICE}.log"

    if [[ -s "/tmp/verify-${SERVICE}.log" ]]; then
        warn "Verify found differences"
        state_set verify_status "partial"
        return 10
    fi

    state_set verify_status "success"
    vlog "verify_backup__ done"
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
 if [ "$TELEMETRY_ENABLED" = true ]; then
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
  fi
}

send_telemetry() {
 if [ "$TELEMETRY_ENABLED" = true ]; then
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
  fi
}

send_telemetry_mysql() {
 if [ "$TELEMETRY_ENABLED" = true ]; then
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
  fi
}

# error: mysql-client is on truenas not available, package installations are strict denied
db_open_run() {
 if [ "$TELEMETRY_ENABLED" = true ]; then
  local started_at
  started_at="$(date '+%Y-%m-%d %H:%M:%S')"
  command -v mysql >/dev/null 2>&1 || {
  warn "mysql not available, skipping db run open"
  return 0
}
  mysql "$DB_NAME" <<SQL
INSERT INTO blockchain_backup_runs
  (host, service, mode, started_at)
VALUES
  ('$THIS_HOST', '$SERVICE', '$MODE', '$started_at');
SQL

  LAST_RUN_ID=$(mysql "$DB_NAME" -N -s -e "SELECT LAST_INSERT_ID();")
  [[ -n "$LAST_RUN_ID" ]] || error "Failed to obtain LAST_RUN_ID"

  log "DB run opened (id=$LAST_RUN_ID)"
  fi
}

db_log_event() {
 if [ "$TELEMETRY_ENABLED" = true ]; then
  local level="$1"
  local msg="$2"
  local source="$3"

  mysql "$DB_NAME" <<SQL
INSERT INTO blockchain_backup_events
  (run_id, level, message, source, created_at)
VALUES
  ($LAST_RUN_ID, '$level', '$msg', '$source', NOW());
SQL
  fi
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


init_config() {
  log "Initializing config files"

  local host
  host="$(hostname -s)"

  create_cfg "default.conf"   default
  create_cfg "machine.conf"   machine
  create_cfg "${host}.conf.example"   host

  log "Config initialization complete"
  vlog "Edit the files and rerun without --init-config"
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
# --- default.conf ---
# Lowest priority config

# This settings results in: $0 --mode backup --dry-run
MODE=backup
DRY_RUN=true
EOF
      ;;
    machine)
      cat >"$file" <<'EOF'
# --- machine.conf ---
# Machine-wide settings

MODE=backup
DRY_RUN=false

POOL="tank"
DATASET="blockchain"

SRC_BASE="/mnt/tank/blockchain"
DEST_BASE="/mnt/tank/backups"

USE_USB=false
USB_ID=""
EOF
      ;;
    host)
      cat >"$file" <<'EOF'
# --- ${host}.conf ---
# Host-specific config
# Last in precedence chain

# Example:
# SERVICE="bitcoind"
# LOGFILE="/var/log/backup_blockchain_truenas.log"
EOF
      ;;
    *)
      error "Unknown config type: $type"
      ;;
  esac
}

parse_cli_args() {
  local OPTIONS
  OPTIONS=$(getopt -o '' \
    --long mode:,service:,verbose,debug,dry-run,force,init-config,help \
    -- "$@") || exit 1

  # if getopt returned an error
  if [ $? -ne 0 ]; then
    error "Error: Invalid options."
  fi
  eval set -- "$OPTIONS" # Set the rearranged arguments

  # Iterate over the options
  while true; do
    case "$1" in
      -m|--mode)
        MODE="$2"
        shift 2
        ;;
      -s|--service)
        SERVICE="$2"
        shift 2
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --debug)
        DEBUG=true
        shift
        ;;
      -t|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -f|--force)
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
        error "Unknown option: $1"
        ;;
    esac
  done

# Handle non-option arguments
log "Non-option arguments: $*"
}

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --mode         <backup|merge|verify|restore>
  --service      <bitcoind|monerod|chia>
  --verbose      Verbose outputs and logging
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
parse_cli_args "$@"
log "Script started: mode=${MODE}, service=${SERVICE}"
vlog "Script started: mode=${MODE}, service=${SERVICE}" # todo show all given args
CT_NAME=""
if [[ -n "${SERVICE:-}" ]]; then
  CT_NAME="${SERVICE_CT_MAP[$SERVICE]:-}"
fi

$DEBUG && set -x

# init-config called, SERVICE not needed
if $INIT_CONFIG; then
  init_config
  exit 0
fi

load_config_chain
vlog "mode=${MODE}, service=${SERVICE}" # todo: after read config, show all feeded variables

# ab hier: normaler Betrieb, SERVICE zwingend
if [[ -z "${SERVICE:-}" ]]; then
  error "SERVICE not set"
fi

prepare
db_open_run

if $USE_USB; then
  [[ -b "$USB_ID" ]] || error "USB device not found"
  DESTDIR="$USB_MOUNT/$SERVICE"
fi


# --- execute part
EXIT_CODE=0
case "$MODE" in
    backup)
        take_snapshot
        backup_blockchain
        $VERIFY && verify_backup || EXIT_CODE=$?
        $VERBOSE && list_snapshots
        ;;
    merge)
        merge_dirs
        $VERIFY && verify_backup || EXIT_CODE=$?
        $VERBOSE && list_snapshots
        ;;
    verify)
        verify_backup || EXIT_CODE=$?
        ;;
    restore)
        $FORCE || error "Restore requires --force"
        restore_blockchain
        $VERIFY && verify_backup || EXIT_CODE=$?
        list_snapshots
        ;;
esac


END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))

# telemetry
END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))
collect_metrics "$RUNTIME" "$EXIT_CODE"
log "Script finished successfully"
exit "$EXIT_CODE"

# ----------------------------------------------------------

Automount minimal:
mount | grep "$USB_MOUNT"
mount "$USB_ID" "$USB_MOUNT"
