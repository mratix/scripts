#!/bin/bash
#
# ============================================================
# backup_blockchain_truenas.sh
# Gold Release v1.1.0
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
#   --getdata
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
# Author: mratix, 1644259+mratix@users.noreply.github.com
# Refactor & extensions: ChatGPT <- With best thanks to
# ============================================================
#

set -Eeuo pipefail

########################################
# Globals / Defaults
########################################

MODE="backup"                   # backup | merge | verify | restore
SERVICE=""                      # bitcoind|monerod|chia
POOL=""
DATASET=""
SRC_BASE=""
DEST_BASE=""
SRCDIR=""
DESTDIR=""
CLI_SERVICE=""
CLI_MODE=""

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
TELEMETRY_BACKEND=""    # influx
METRIC_EXIT_CODE=""
METRIC_RUNTIME=""
METRIC_BLOCK_HEIGHT=""  # Blockheight

# Runtime flags:
# These MUST NOT be set via config files.
# CLI / environment only.
FORCE=false
VERIFY="${VERIFY:-true}"
VERBOSE="${VERBOSE:-false}"
DEBUG=false
DRY_RUN=false
INIT_CONFIG=false
SERVICE_STOP_BEFORE=true
SERVICE_START_AFTER=false
GET_DATA=true

########################################
# Logging helpers
########################################

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOGFILE"
}
info() {
    echo "$*"
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
# Rules:
# - Later files override earlier ones
# - CLI / environment variables override config
# - Missing files are ignored with warning

load_config() {
    local cfg

    for cfg in "$@"; do
        if [[ -f "$cfg" ]]; then
            log "Loading config: $cfg"

            if ! grep -Eq '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$cfg"; then
                vlog "Config file not enabled, skipping: $cfg"
                continue
            fi

            if ! bash -n "$cfg" 2>/dev/null; then
                warn "Syntax error in config file, skipping: $cfg"
                continue
            fi

            # shellcheck source=/dev/null
            source "$cfg"
        else
            vlog "Config file not found, skipping: $cfg"
        fi
    done
}


# Load configuration files (order matters)
#   default.conf -> machine.conf -> $THIS_HOST.conf
load_config_chain() {
    local cfg
    local scriptdir

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # config files live in the script directory, not the caller's $PWD
    for cfg in "${script_dir}/config.conf" "${script_dir}/default.conf" "${script_dir}/machine.conf" "${script_dir}/${THIS_HOST}.conf"; do
        if [[ -f "$cfg" ]]; then
            #todo: check validity/acceptance of read parameters
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
sleep 4 # give some time to look at the output
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
    local snapdataset snapname
    snapdataset="${POOL}/${DATASET}/${SERVICE}"
    snapname="script-$(date +%Y-%m-%d_%H-%M-%S)"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: zfs snapshot -r ${snapdataset}@${snapname}"
        return 0
    fi

    log "Creating snapshot: ${snapdataset}@${snapname}"

    if ! zfs snapshot -r "${snapdataset}@${snapname}"; then
        error "Snapshot creation failed: ${snapdataset}@${snapname}"
    fi

    LAST_SNAPSHOT="${snapdataset}@${snapname}"
    state_set last_snapshot "$LAST_SNAPSHOT"

    if [ "$TELEMETRY_ENABLED" = true ]; then
        telemetry_event "info" "snapshot created" "script"
    fi

    log "Snapshot created successfully: ${LAST_SNAPSHOT}"
}


list_snapshots_entries() {
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

                printf "%s|%s|%s\n", type, snap, $2" "$3" "$4" "$5
            }
        ' \
        | sort -k3,3
}

list_snapshots_simple() {
    local entry type snap created

    while IFS='|' read -r type snap created; do
        printf "%-8s | %-25s | %s\n" "$type" "$snap" "$created"
    done < <(list_snapshots_entries)
}

list_snapshots_table() {
    local w_type=8
    local w_snap=25
    local w_date=24
    local hr_type hr_snap hr_date
    local top mid bottom
    local entries

    hr_type=$(printf '%*s' $((w_type + 2)) '' | tr ' ' '-')
    hr_snap=$(printf '%*s' $((w_snap + 2)) '' | tr ' ' '-')
    hr_date=$(printf '%*s' $((w_date + 2)) '' | tr ' ' '-')

    top="+${hr_type}+${hr_snap}+${hr_date}+"
    mid="$top"
    bottom="$top"

    entries=$(list_snapshots_entries)

    printf '%s\n' "$top"
    printf "| %-*s | %-*s | %-*s |\n" "$w_type" "TYPE" "$w_snap" "SNAPSHOT" "$w_date" "CREATED"
    printf '%s\n' "$mid"

    if [ -z "$entries" ]; then
        printf "| %-*s | %-*s | %-*s |\n" "$w_type" "-" "$w_snap" "no snapshots found" "$w_date" "-"
    else
        while IFS='|' read -r type snap created; do
            type=${type:0:$w_type}
            snap=${snap:0:$w_snap}
            created=${created:0:$w_date}
            printf "| %-*s | %-*s | %-*s |\n" "$w_type" "$type" "$w_snap" "$snap" "$w_date" "$created"
        done <<<"$entries"
    fi

    printf '%s\n' "$bottom"
}

list_snapshots() {
    log "List of blockchain-relevant snapshots: $SERVICE"

    if [ "$VERBOSE" = true ]; then
        list_snapshots_simple
    else
        list_snapshots_table
    fi
}

########################################
# Backup (rsync-based, snapshot protected)
# Restore (interactive, never headless)
########################################

backup_blockchain() {
    vlog "backup_blockchain__ start"

    if [ "$DRY_RUN" = true ]; then
        log "DRY-RUN: rsync ${RSYNC_OPTS[*]} ${SRCDIR}/ ${DESTDIR}/"
        return 0
    fi

    info "Starting rsync ${MODE} from ${SRCDIR}/ to ${DESTDIR}/"
    if ! rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" "$SRCDIR/" "$DESTDIR/"; then
        rsync_exit=$?
    else
        rsync_exit=0
    fi

case "$rsync_exit" in
      0)
        log "rsync ${MODE} completed successfully"
        ;;
      23|24)
        warn "rsync ${MODE} completed with warnings code=$rsync_exit; retrying once"
        if ! rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" "$SRCDIR/" "$DESTDIR/"; then
            rsync_exit=$?
        else
            rsync_exit=0
        fi
        if [[ "$rsync_exit" -ne 0 ]]; then
            error "rsync ${MODE} failed after retry code=$rsync_exit"
        fi
        log "rsync ${MODE} completed successfully after retry"
        ;;
      *)
        error "rsync failed code=$rsync_exit"
        ;;
    esac

    vlog "backup_blockchain__ done"
}

########################################
# Merge (rsync-based, snapshot protected)
########################################

merge_dirs() {
vlog "merge_dirs__ start"

# take snapshot destination-dataset, not source
local saved_pool="$POOL"
POOL="tank"
take_snapshot
POOL="$saved_pool"

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
    src_size="$(du -sb "$SRCDIR"  | awk '{print $1}')"
    dst_size="$(du -sb "$DESTDIR" | awk '{print $1}')"

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
        state_set verify_status "partial"
        error "Verify found differences"
    fi

    state_set verify_status "success"
    vlog "verify_backup__ done"
}

service_stop() {
    local ct="${SERVICE_CT_MAP[$SERVICE]:-}"
    [[ -n "$ct" ]] || return 0

    info "Stopping service container: $ct"
    docker stop "$ct" >/dev/null 2>&1 || warn "Failed to stop $ct"
}

service_start() {
    local ct="${SERVICE_CT_MAP[$SERVICE]:-}"
    [[ -n "$ct" ]] || return 0

    info "Starting service container: $ct"
    docker start "$ct" >/dev/null 2>&1 || warn "Failed to start $ct"
}

docker_exec() {
    local service="$1"
    shift

    local ct="${SERVICE_CT_MAP[$service]:-}"
    [[ -n "$ct" ]] || return 1

    docker exec "$ct" "$@" 2>/dev/null
}

get_block_height() {
    local ct
    ct="${SERVICE_CT_MAP[$SERVICE]:-}" || return 1
    [[ -n "$ct" ]] || return 1

    case "$SERVICE" in
        bitcoind)
            docker exec "$ct" bitcoin-cli getblockcount 2>/dev/null
            ;;
        monerod)
            #docker exec "$ct" monerod status 2>/dev/null | awk '/Height:/ {print $2}'
            #3384305/3604686
            docker exec "$ct" monerod print_height 2>/dev/null | awk 'END {print $1}'
            #docker exec "$ct" monero-wallet-cli bc_height # unused
            ;;
        chia)
            docker exec "$ct" chia blockchain height 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# --- pull data from service, little node-info
get_service_data() {
    local ct
    ct="${SERVICE_CT_MAP[$SERVICE]:-}" || return 1
    [[ -n "$ct" ]] || return 1

    case "$SERVICE" in
        bitcoind)
            docker exec "$ct" bitcoin-cli -getinfo -color=auto 2>/dev/null 1> info
            ;;
        monerod)
            docker exec "$ct" monerod status 2>/dev/null 1> info
            ;;
        chia)
            ;;
        *)
            return 1
            ;;
    esac
}


########################################
# Metrics / audit
########################################

collect_metrics() {
    METRIC_RUNTIME="${1:-0}"
    METRIC_EXIT_CODE="${2:-0}"

    METRIC_SRC_SIZE="$(du -sb "$SRCDIR" 2>/dev/null | awk '{print $1}' || echo 0)"
    METRIC_DST_SIZE="$(du -sb "$DESTDIR" 2>/dev/null | awk '{print $1}' || echo 0)"
    METRIC_DISKUSAGE="$(du -shL "$SRCDIR" 2>/dev/null | awk '{print $1}' || echo 0)"

    METRIC_SNAPSHOT_COUNT="$(zfs list -t snapshot -o name 2>/dev/null \
        | grep "^${POOL}/${DATASET}/${SERVICE}@" \
        | wc -l || echo 0)"

    METRIC_SERVICE="$SERVICE"
    METRIC_MODE="$MODE"

    METRIC_BLOCK_HEIGHT=""
    if [[ "${METRICS_BLOCKHEIGHT:-false}" = true ]]; then
        METRIC_BLOCK_HEIGHT="$(get_block_height || true)"
        if [[ -z "$METRIC_BLOCK_HEIGHT" ]]; then
            METRIC_BLOCK_HEIGHT="0"
        fi
    fi

    if [[ "${METRICS_BLOCKHEIGHT:-false}" = true ]]; then
        state_set block_height "$METRIC_BLOCK_HEIGHT"
    fi
    state_set snapshot_count "$METRIC_SNAPSHOT_COUNT"
    state_set last_run_service "$METRIC_SERVICE"
    state_set last_run_mode "$METRIC_MODE"
    state_set last_run_runtime_s "$METRIC_RUNTIME"
    state_set last_run_exit_code "$METRIC_EXIT_CODE"
}

telemetry_run_end() {
    $TELEMETRY_ENABLED || return 0

    case "$TELEMETRY_BACKEND" in
        syslog) telemetry_syslog ;;
        http|influx) telemetry_http ;;
        none|"") return 0 ;;
        *) warn "Unknown telemetry backend: $TELEMETRY_BACKEND" ;;
    esac
}


telemetry_http() {
    curl -fsS -XPOST "$INFLUX_URL" \
        --data-binary \
        "backup,host=$THIS_HOST,service=$SERVICE \
runtime=${METRIC_RUNTIME},exit=${METRIC_EXIT_CODE},block_height=${METRIC_BLOCK_HEIGHT}"
}


telemetry_syslog() {
    /usr/bin/logger -t backup_blockchain \
      "service=$SERVICE mode=$MODE exit=$METRIC_EXIT_CODE runtime=${METRIC_RUNTIME}s \
snapshots=${METRIC_SNAPSHOT_COUNT:-0} block_height=${METRIC_BLOCK_HEIGHT:-na}"
}


telemetry_none() {
  return 0
}

telemetry_event() {
  local level="$1"
  local msg="$2"
  local source="${3:-script}"

  case "$TELEMETRY_BACKEND" in
    none|"")
      return 0
      ;;
    syslog)
      telemetry_syslog "$level" "$msg" "$source"
      ;;
    http)
      telemetry_http "$level" "$msg" "$source"
      ;;
    *)
      warn "Unknown telemetry backend: $TELEMETRY_BACKEND"
      ;;
  esac
}


send_telemetry() {
 if [ "$TELEMETRY_ENABLED" = true ]; then
    local runtime="$1" exit="$2" src="$3" dst="$4"

    case "$TELEMETRY_BACKEND" in
        influx)
#            curl -sS -XPOST "$INFLUX_URL/api/v2/write?org=$ORG&bucket=$BUCKET&precision=s" \
#  -H "Authorization: Token $INFLUX_TOKEN" \
#  --data-binary \
#  "backup,host=$THIS_HOST,service=$SERVICE mode=\"$MODE\",runtime=$RUNTIME,exit=$EXIT_CODE"
            send_telemetry_influx "$runtime" "$exit" "$src" "$dst"
            ;;
        *)
            warn "Unknown telemetry backend: $TELEMETRY_BACKEND"
            ;;
    esac
  fi
}


send_telemetry_syslog() {
logger -t backup_blockchain \
  "service=$SERVICE mode=$MODE exit=$EXIT_CODE runtime=${RUNTIME}s snapshot=${LAST_SNAPSHOT:-}"
}

send_telemetry_http() {
  curl -fsS -X POST "$TELEMETRY_URL" \
    -H "Authorization: Bearer $TELEMETRY_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"host\": \"$THIS_HOST\",
      \"service\": \"$SERVICE\",
      \"mode\": \"$MODE\",
      \"runtime\": $RUNTIME,
      \"exit\": $EXIT_CODE,
      \"snapshot\": \"${LAST_SNAPSHOT:-}\"
    }" || true
}


init_config() {
  log "Initializing config files"

  local host
  host="$(hostname -s)"

  create_cfg "default.conf"   default
  create_cfg "machine.conf"   machine
  create_cfg "${host}.conf.example"   host

  log "Config initialization complete"
  log "Edit the files and rerun without --init-config"
}

create_cfg() {
  local file="$1"
  local type="$2"

  if [[ -f "$file" ]]; then
    info "Config already exists, skipping: $file"
    return
  fi

  log "Creating $file"

  case "$type" in
    default)
      cat >"$file" <<'EOF'
# --- default.conf ---
# Lowest priority config

ENABLED=true

# This settings results in: $0 --mode backup --dry-run
MODE=backup
DRY_RUN=true
EOF
      ;;
    machine)
      cat >"$file" <<'EOF'
# --- machine.conf ---
# Machine-wide settings

ENABLED=true

MODE=backup
DRY_RUN=false

POOL="tank"
DATASET="blockchain"

SRC_BASE="/mnt/tank/blockchain"
DEST_BASE="/mnt/tank/backups"

USE_USB=false
USB_ID=""

VERIFY=true # enable always verify
VERBOSE=false # enable verbose outputs

TELEMETRY_ENABLED=true
TELEMETRY_BACKEND="syslog"    # none|syslog|http|influx
EOF
      ;;
    host)
      cat >"$file" <<'EOF'
# --- ${host}.conf ---
# Host-specific config
# Last in precedence chain

# Example:
SERVICE="bitcoind"
LOGFILE="/var/log/backup_blockchain_truenas.log"
EOF
      ;;
    *)
      error "Unknown config type: $type"
      ;;
  esac
}

parse_cli_args() {
  local OPTIONS
  OPTIONS=$(getopt -o 'm:s:gtf' \
  --long mode:,service:,getdata,verbose,debug,dry-run,force,init-config,help \
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
        CLI_MODE="$2"
        shift 2
        ;;
      -s|--service)
        SERVICE="$2"
        CLI_SERVICE="$2"
        shift 2
        ;;
      -g|--getdata)
        GET_DATA=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        GET_DATA=true
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

resolve_paths() {
  local src_base dest_base src_root dest_root svc

  [ -n "$POOL" ]    || error "POOL not set"
  [ -n "$DATASET" ] || error "DATASET not set"
  [ -n "$SERVICE" ] || error "SERVICE not set"

  src_base="${SRC_BASE:-/mnt/${POOL}/${DATASET}}"
  dest_base="${DEST_BASE:-/mnt/tank/backups/${DATASET}}"

  src_root="${src_base%/}"
  dest_root="${dest_base%/}"
  for svc in "${!SERVICE_CT_MAP[@]}"; do
    if [[ "$src_root" == *"/${svc}" ]]; then
      src_root="${src_root%/${svc}}"
      break
    fi
  done

  for svc in "${!SERVICE_CT_MAP[@]}"; do
    if [[ "$dest_root" == *"/${svc}" ]]; then
      dest_root="${dest_root%/${svc}}"
      break
    fi
  done

  SRCDIR="${src_root%/}/${SERVICE}"
  DESTDIR="${dest_root%/}/${SERVICE}"

  SRC_BASE="$src_root"
  DEST_BASE="$dest_root"
}

resolve_home_paths() {
  local effective_user effective_home

  effective_user="${SUDO_USER:-$USER}"
  effective_home="$(getent passwd "$effective_user" | cut -d: -f6)"

  if [[ -n "$effective_home" && "${HOME:-}" = "/root" && -n "${SUDO_USER:-}" ]]; then
    LOGFILE="${LOGFILE/#\/root/$effective_home}"
    STATEFILE="${STATEFILE/#\/root/$effective_home}"
  fi
}

usage() {
  cat <<EOF
Usage: $0 [options] <command> [params]

Options:
  -m,--mode         <backup|merge|verify|restore>
  -s,--service      <bitcoind|monerod|chia>

  -g,--getdata      Pull data from service
  --verbose         Verbose outputs and logging
  --debug           Enable bash xtrace
  -t,--dry-run      Do not modify anything
  -f,--force        Required for restore
  --init-config     Init new config files
  --help
EOF
}

########################################
# Main
########################################

START_TS=$(date +%s)
THIS_HOST=${THIS_HOST:-$(hostname -s)}
parse_cli_args "$@"
info "Script started: mode=${MODE}, service=${SERVICE}"
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

if [[ -n "${CLI_MODE:-}" ]]; then
  MODE="$CLI_MODE"
fi
if [[ -n "${CLI_SERVICE:-}" ]]; then
  SERVICE="$CLI_SERVICE"
fi

resolve_home_paths

# ab hier: normaler Betrieb, SERVICE zwingend
if [[ -z "${SERVICE:-}" ]]; then
  error "SERVICE not set"
fi

resolve_paths
prepare

if [[ -n "${GET_DATA:-}" ]]; then
  get_service_data
fi

if $USE_USB; then
  [[ -b "$USB_ID" ]] && DESTDIR="$USB_MOUNT/$DATASET/$SERVICE" || error "USB device not found"
  # Automount minimal
  # mount | grep "$USB_MOUNT" || mount "$USB_ID" "$USB_MOUNT"
fi


# --- execute part ---
EXIT_CODE=0
case "$MODE" in
    backup)
        $SERVICE_STOP_BEFORE && service_stop
        take_snapshot
        backup_blockchain
        $SERVICE_START_AFTER && service_start
        $VERIFY && verify_backup || EXIT_CODE=$?
        $VERBOSE && list_snapshots
        ;;
    merge)
        $SERVICE_STOP_BEFORE && service_stop
        merge_dirs
        $VERIFY && verify_backup || EXIT_CODE=$?
        $VERBOSE && list_snapshots
        #$SERVICE_START_AFTER && service_start
        ;;
    verify)
        verify_backup || EXIT_CODE=$?
        ;;
    restore)
        $FORCE || error "Restore requires --force"
        warn "RESTORE MODE – this will overwrite local data"
        if [ -t 0 ]; then
            read -r -p "Type YES to continue: " confirm
            [ "$confirm" = "YES" ] || error "Restore aborted by user"
        else
            error "Restore requires interactive terminal"
        fi
        $SERVICE_STOP_BEFORE && service_stop
        restore_tmp="$SRCDIR"; SRCDIR="$DESTDIR"; DESTDIR="$restore_tmp"
        backup_blockchain
        restore_tmp="$SRCDIR"; SRCDIR="$DESTDIR"; DESTDIR="$restore_tmp"
        $VERIFY && verify_backup || EXIT_CODE=$?
        ;;
esac
# --- execute part done ---

END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))

# --- telemetry
END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))
collect_metrics "$RUNTIME" "$EXIT_CODE"
telemetry_run_end "$RUNTIME" "$EXIT_CODE"
log "Script finished successfully"
exit "$EXIT_CODE"

# ----------------------------------------------------------
