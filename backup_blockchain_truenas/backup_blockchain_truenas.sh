#!/bin/bash
#
# ============================================================
# backup_blockchain_truenas.sh
# Gold Release v1.1.3
# Maintenance release: config handling, init-config fixes, stability
#
# Backup & restore script for blockchain nodes on TrueNAS Scale
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
# Refactor & extensions: ChatGPT codex <- With best thanks for the support
# ============================================================
#

set -Eeuo pipefail

########################################
# Globals / Defaults
#
MODE="backup"                   # backup | merge | verify | restore
SERVICE=""                      # bitcoind|monerod|chia
POOL=""
DATASET=""
SRC_BASE=""
DEST_BASE=""
SRCDIR=""
DESTDIR=""
CLI_MODE=""
CLI_SERVICE=""
RSYNC_OPTS=(-avihH --numeric-ids --mkpath --delete --stats --info=progress2)
RSYNC_EXCLUDES=(
  --exclude='/.zfs'
  --exclude='/.zfs/**'
  --exclude='/.snapshot'
  --exclude='/.snapshot/**'
)
declare -A SERVICE_CT_MAP=(
  [bitcoind]="ix-bitcoind-bitcoind-1"
  [monerod]="ix-monerod-monerod-1"
  [chia]="ix-chia-farmer-1"
)
declare -A SERVICE_APP_MAP=(
  [bitcoind]="bitcoind"
  [monerod]="monerod"
  [chia]="chia"
)
LOGFILE="${LOGFILE:-/var/log/backup_restore_blockchain_truenas.log}"
STATEFILE="${STATEFILE:-/var/log/backup_restore_blockchain_truenas.state}"

TELEMETRY_ENABLED=true
TELEMETRY_BACKEND="syslog"      # none|syslog|http|influx
BLOCK_HEIGHT=""                 # Blockheight
SERVICE_STOP_BEFORE=true
SERVICE_START_AFTER=false
SERVICE_STOP_METHOD="graceful"  # midclt|graceful|docker
CLI_OVERRIDES=()

########################################
# Helper variables and state holder
#
METRIC_EXIT_CODE=""
METRIC_RUNTIME=""
SERVICE_GETDATA=true
SERVICE_RUNNING=""
SERVICE_WAS_RUNNING=""

########################################
# Runtime flags
# These MUST NOT be set via config files
# CLI / environment only
FORCE=false
DEBUG=false
INIT_CONFIG=false
# These Runtime flags can be set via config files
DRY_RUN="${DRY_RUN:-false}"
VERIFY="${VERIFY:-true}"
VERBOSE="${VERBOSE:-false}"

########################################
# Logging helpers
#
show() {
    echo "$*"
}
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOGFILE"
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
#
set_statefile() {
vlog "__set_statefile__"
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
# Rules:
# - Missing files are ignored with warning
# - Later files override earlier ones
# - CLI / environment variables override config
load_config() {
vlog "__load_config__"
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

########################################
# Load configuration files (order matters)
# default.conf -> machine.conf -> $THIS_HOST.conf
#
load_config_chain() {
vlog "__load_config_chain__"
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
#
prepare() {
vlog "__prepare__"
    touch "$STATEFILE" 2>/dev/null || warn "Statefile not writable: $STATEFILE"
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
}

########################################
# ZFS snapshot handling
#
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
    set_statefile last_snapshot "$LAST_SNAPSHOT"

    if [ "$TELEMETRY_ENABLED" = true ]; then
        telemetry_event "info" "snapshot created" "script"
    fi

    log "Snapshot created successfully: ${LAST_SNAPSHOT}"
}

########################################
#
list_snapshots_entries() {
vlog "__list_snapshots_entries__"
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
# Main task
# Backup (rsync-based, snapshot protected)
# Restore (interactive, never headless)
#
backup_restore_blockchain() {
vlog "__backup_restore_blockchain__ start"

    if [ "$DRY_RUN" = true ]; then
        log "Starting rsync dry-run backup ${RSYNC_OPTS[*]} ${SRCDIR}/ ${DESTDIR}/"
        return 0
    fi

    show "Starting rsync ${MODE} from ${SRCDIR}/ to ${DESTDIR}/"
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
}

########################################
# Merge (rsync-based, snapshot protected)
#
merge_dirs() {
vlog "__merge_dirs__"

# take snapshot destination-dataset, not source
local saved_pool="$POOL"
POOL="tank"
take_snapshot
POOL="$saved_pool"

if [ "$DRY_RUN" = true ]; then
    log "Starting rsync dry-run merge ${RSYNC_OPTS[*]} ${SRCDIR}/ ${DESTDIR}/"
    return 0
fi

    rsync "${RSYNC_OPTS[@]}" "${RSYNC_EXCLUDES[@]}" "$SRCDIR/" "$DESTDIR/" \
        || error "Merge rsync failed"

    log "Merge completed successfully"
    telemetry_event "info" "merge completed" "script"
}

########################################
# Verify
#
verify_backup_restore() {
vlog "__verify_backup_restore__"

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
        set_statefile verify_status "partial"
    fi

    log "Starting rsync verify"
    local verify_log="/tmp/verify-${SERVICE}.log"
    local verify_diffs="/tmp/verify-${SERVICE}-diffs.log"
    rsync -na --delete --itemize-changes --out-format='%i %n%L' \
        "${RSYNC_EXCLUDES[@]}" \
        "$SRCDIR/" "$DESTDIR/" \
        >"$verify_log"
    local rsync_exit=$?

    if [[ "$rsync_exit" -ne 0 ]]; then
        error "Verify rsync failed code=$rsync_exit"
    fi

    grep -Ev '^(sending incremental file list|sent |total size|$)' "$verify_log" >"$verify_diffs" || true

    if [[ -s "$verify_diffs" ]]; then
        set_statefile verify_status "partial"
        if $VERBOSE; then
            log "Verify diffs detected:"
            sed 's/^/  /' "$verify_diffs" | tee -a "$LOGFILE"
        fi
        error "Verify found differences"
    fi

    set_statefile verify_status "success"
vlog "__verify_backup_restore__ done"
}

########################################
# pre-tasks, stop service
#
service_stop() {
    case "${SERVICE_STOP_METHOD}" in
        docker) service_stop_docker ;;
        graceful) service_stop_graceful ;;
        midclt) service_stop_midclt ;;
        *)
            warn "Unknown SERVICE_STOP_METHOD=${SERVICE_STOP_METHOD}, falling back to docker"
            service_stop_docker
            ;;
    esac
}

service_stop_docker() {
vlog "__service_stop_docker__"
    local ct="${SERVICE_CT_MAP[$SERVICE]:-}"
    [[ -n "$ct" ]] || return 0

    log "Stopping service container: $ct"
    if docker stop "$ct" >/dev/null 2>&1; then
        SERVICE_RUNNING=false
    else
        warn "Failed to stop $ct"
    fi
}

service_stop_graceful() {
vlog "__service_stop_graceful__"
    local ct="${SERVICE_CT_MAP[$SERVICE]:-}"
    [[ -n "$ct" ]] || return 0

    if ! command -v docker >/dev/null 2>&1; then
        warn "docker binary not available; falling back to docker stop"
        service_stop_docker
        return 0
    fi

    log "Attempting graceful stop (inside container): $ct"
    case "$SERVICE" in
        bitcoind)
            docker exec "$ct" bitcoin-cli stop >/dev/null 2>&1 || warn "Graceful stop failed for bitcoind"
            ;;
        monerod)
            docker exec "$ct" monerod exit >/dev/null 2>&1 || warn "Graceful stop failed for monerod"
            ;;
        chia)
            docker exec "$ct" chia stop -d all >/dev/null 2>&1 || warn "Graceful stop failed for chia"
            ;;
        *)
            warn "Graceful stop not defined for service=${SERVICE}"
            ;;
    esac

    service_stop_docker
vlog "__service_stop_graceful__ done"
}

service_stop_midclt() {
vlog "__service_stop_midclt__"
    local app_name="${SERVICE_APP_MAP[$SERVICE]:-$SERVICE}"

    if ! command -v midclt >/dev/null 2>&1; then
        warn "midclt binary not available; falling back to docker stop"
        service_stop_docker
        return 0
    fi

    log "Stopping TrueNAS app via midclt: ${app_name}"
    if ! midclt call app.stop "${app_name}" >/dev/null 2>&1; then
        warn "midclt app.stop failed for ${app_name}; falling back to docker stop"
        service_stop_docker
    fi
}

########################################
# post-tasks, start service
#
service_start() {
    local ct="${SERVICE_CT_MAP[$SERVICE]:-}"
    [[ -n "$ct" ]] || return 0

    log "Starting service container: $ct"
    if docker start "$ct" >/dev/null 2>&1; then
        SERVICE_RUNNING=true
    else
        warn "Failed to start $ct"
    fi
}

########################################
# Rotating log file
#
rotate_logfile() {
vlog "__rotate_logfile__"
    local service_logfile
    local logfile_dir logfile_name logfile_base
    local rotated_file
    local suffix=""
    local was_running
    local height
    local today=$(date +%y%m%d)

    if [[ "$MODE" != "backup" ]]; then
        return 0
    fi

    case "$SERVICE" in
        bitcoind) service_logfile="${SRCDIR}/debug.log" ;;
        monerod) service_logfile="${SRCDIR}/bitmonero.log" ;;
        chia) return 0 ;;
        *) return 0 ;;
    esac

    if [[ ! -f "$service_logfile" ]]; then
        vlog "Log rotation skipped: ${service_logfile} not found"
        return 0
    fi

    was_running="${SERVICE_WAS_RUNNING:-$SERVICE_RUNNING}"
    if [[ -z "${was_running}" ]]; then
        check_service_running || true
        was_running="${SERVICE_RUNNING}"
    fi

    if [[ "${was_running}" == true ]]; then
        suffix="-unclean"
    fi

    local raw_height
    raw_height="${BLOCK_HEIGHT:-$(get_block_height || true)}"
    BLOCK_HEIGHT="$(normalize_block_height "$raw_height")"
    if [[ -n "${BLOCK_HEIGHT}" && "${BLOCK_HEIGHT}" -ge 111111 ]]; then
        height="_h${BLOCK_HEIGHT}"
    else
        height=""
    fi

    logfile_dir="$(dirname "$service_logfile")"
    logfile_name="$(basename "$service_logfile")"
    logfile_base="${logfile_name%.*}"
    rotated_file="${logfile_dir}/${logfile_base}_${today}${height}${suffix}.log"

    if [[ "${was_running}" == true ]]; then
        cp -u "$service_logfile" "$rotated_file" || warn "Failed to copy log to ${rotated_file}"
    else
        mv -u "$service_logfile" "$rotated_file" || warn "Failed to move log to ${rotated_file}"
    fi

    log "Rotated ${service_logfile} -> ${rotated_file}"
vlog "__rotate_logfile__ done"
}

########################################
# Helpers
#
resolve_paths() {
vlog "__resolve_paths__"
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

docker_exec() {
    local service="$1"
    shift

    local ct="${SERVICE_CT_MAP[$service]:-}"
    [[ -n "$ct" ]] || return 1

    docker exec "$ct" "$@" 2>/dev/null
}

get_block_height() {
vlog "__get_block_height__"
  if check_service_running; then
    # get from running service
    local ct
    ct="${SERVICE_CT_MAP[$SERVICE]:-}" || return 1
    [[ -n "$ct" ]] || return 1
    command -v docker >/dev/null 2>&1 || return

    case "$SERVICE" in
        bitcoind)
            docker exec "$ct" bitcoin-cli getblockcount 2>/dev/null
            ;;
        monerod)
            #docker exec "$ct" monerod status 2>/dev/null | awk '/Height:/ {print $2}'
            #3384305/3604686
            #docker exec "$ct" monerod print_height 2>/dev/null | awk 'END {print $1}' # wert ans ende geh#ngt
            docker exec "$ct" monerod print_height 2>/dev/null | tail -n1
            #docker exec "$ct" monero-wallet-cli bc_height # unused
            ;;
        chia)
            docker exec "$ct" chia blockchain height 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
  #elif    # parse from logfile
  fi
}

normalize_block_height() {
  local value="$1"
  awk 'match($0, /[0-9]+/) {print substr($0, RSTART, RLENGTH); exit}' <<<"$value"
}

check_service_running() {
    local ct
    ct="${SERVICE_CT_MAP[$SERVICE]:-}"
    if [[ -z "$ct" ]]; then
        SERVICE_RUNNING=false
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        warn "docker binary not available; assuming service is not running"
        SERVICE_RUNNING=false
        return 1
    fi

    if docker ps -q -f "name=^${ct}$" | grep -q .; then
        SERVICE_RUNNING=true
        return 0
    fi

    SERVICE_RUNNING=false
    return 1
}

# grab data from service, little node-info
get_service_data() {
  check_service_running || return 0
  if [[ "$SERVICE_RUNNING" == true ]]; then
    local ct
    ct="${SERVICE_CT_MAP[$SERVICE]:-}" || return 1
    [[ -n "$ct" ]] || return 1

    show "Short service summary:"
    case "$SERVICE" in
        bitcoind)
            docker exec "$ct" bitcoin-cli -getinfo -color=auto 2>/dev/null \
                | while IFS= read -r line; do show "$line"; done
            ;;
        monerod)
            docker exec "$ct" monerod status 2>/dev/null \
                | while IFS= read -r line; do show "$line"; done
            ;;
        chia)
            ;;
        *)
            return 1
            ;;
    esac
  fi
}


########################################
# Metrics / audit
#
collect_metrics() {
vlog "__collect_metrics__"
    METRIC_RUNTIME="${1:-0}"
    METRIC_EXIT_CODE="${2:-0}"

    METRIC_SRC_SIZE="$(du -sb "$SRCDIR" 2>/dev/null | awk '{print $1}' || echo 0)"
    METRIC_DST_SIZE="$(du -sb "$DESTDIR" 2>/dev/null | awk '{print $1}' || echo 0)"
    METRIC_DISKUSAGE="$(du -shL "$SRCDIR" 2>/dev/null | awk '{print $1}' || echo 0)"

    METRIC_SNAPSHOT_COUNT="0"
    if command -v zfs >/dev/null 2>&1; then
        METRIC_SNAPSHOT_COUNT="$(zfs list -t snapshot -o name 2>/dev/null \
            | grep "^${POOL}/${DATASET}/${SERVICE}@" \
            | wc -l || echo 0)"
    else
        warn "zfs binary not available; snapshot metrics defaulting to 0"
    fi

    METRIC_SERVICE="$SERVICE"
    METRIC_MODE="$MODE"
    METRIC_BLOCK_HEIGHT="$(normalize_block_height "$(get_block_height || true)")"

    set_statefile block_height "$METRIC_BLOCK_HEIGHT"
    set_statefile snapshot_count "$METRIC_SNAPSHOT_COUNT"
    set_statefile last_run_service "$METRIC_SERVICE"
    set_statefile last_run_mode "$METRIC_MODE"
    set_statefile last_run_runtime_s "$METRIC_RUNTIME"
    set_statefile last_run_exit_code "$METRIC_EXIT_CODE"
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
    /usr/bin/logger -t backup_restore_blockchain \
      "service=$SERVICE mode=$MODE exit=$METRIC_EXIT_CODE runtime=${METRIC_RUNTIME}s \
snapshots=${METRIC_SNAPSHOT_COUNT:-0} block_height=${METRIC_BLOCK_HEIGHT:-na}"
}


telemetry_none() {
  return 0
}

telemetry_event() {
vlog "__telemetry_event__"
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
vlog "__send_telemetry__"
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
logger -t backup_restore_blockchain \
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

########################################
# Create example config files
#
init_config() {
vlog "__init_config__"
  log "Initializing config files"

  local host
  host="$(hostname -s)"

  create_config "default.conf"   default
  create_config "machine.conf"   machine
  create_config "${host}.conf.example"   host

  log "Config initialization complete"
  log "Edit the files and rerun without --init-config"
}

create_config() {
vlog "__create_config__"
  local file="$1"
  local type="$2"

  if [[ -f "$file" ]]; then
    show "Config already exists, skipping: $file"
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

VERIFY=true                     # enable always verify
VERBOSE=true                    # enable verbose outputs

TELEMETRY_ENABLED=true
TELEMETRY_BACKEND="syslog"      # none|syslog|http|influx
EOF
      ;;
    host)
      cat >"$file" <<'EOF'
# --- ${host}.conf ---
# Host-specific config
# Last in precedence chain

# Example:
SERVICE="bitcoind"
LOGFILE="/var/log/backup_restore_blockchain_truenas.log"
EOF
      ;;
    *)
      error "Unknown config type: $type"
      ;;
  esac
vlog "__create_config__ done"
}

########################################
# Parsing CLI arguments
#
parse_cli_args() {
vlog "__parse_cli_args__"
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
        SERVICE_GETDATA=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        SERVICE_GETDATA=true
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

# Handle non-option arguments (VAR=VALUE overrides only)
vlog "__parse_cli_args_non__"
  CLI_OVERRIDES=()
  if [[ $# -gt 0 ]]; then
    local arg
    for arg in "$@"; do
      if [[ "$arg" == *=* ]]; then
        CLI_OVERRIDES+=("$arg")
      else
        error "Unknown argument: $arg"
      fi
    done
  fi
}

# CLI overrides (for testing, without changing config)
apply_cli_overrides() {
vlog "__apply_cli_overrides__"
  local override key value
  local -a allowed_vars=(
    DATASET
    DEST_BASE
    DRY_RUN
    FORCE
    INIT_CONFIG
    LOGFILE
    BLOCK_HEIGHT
    POOL
    SERVICE_GETDATA
    SERVICE_STOP_METHOD
    SERVICE_RUNNING
    SERVICE_START_AFTER
    SERVICE_STOP_BEFORE
    SRC_BASE
    STATEFILE
    TELEMETRY_BACKEND
    TELEMETRY_ENABLED
    VERBOSE
    VERIFY
  )

  for override in "${CLI_OVERRIDES[@]}"; do
    key="${override%%=*}"
    value="${override#*=}"
    case " ${allowed_vars[*]} " in
      *" ${key} "*)
        declare -g "${key}=${value}"
        ;;
      *)
        error "Unknown override variable: ${key}"
        ;;
    esac
  done
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

Overrides (VAR=VALUE, after options):
  BLOCK_HEIGHT DATASET DEST_BASE DRY_RUN FORCE INIT_CONFIG LOGFILE POOL
  SERVICE_GETDATA SERVICE_RUNNING SERVICE_START_AFTER SERVICE_STOP_BEFORE
  SERVICE_STOP_METHOD SRC_BASE STATEFILE TELEMETRY_BACKEND TELEMETRY_ENABLED
  VERBOSE VERIFY
EOF
}

########################################
# Main
#
vlog "__main__ start"
$DEBUG && set -x # enable debug

START_TS=$(date +%s)
THIS_HOST=$(hostname -s)
show "Script started on node $THIS_HOST"

vlog "Start settings: $@" # all given args
parse_cli_args "$@"
CT_NAME=""
if [[ -n "${SERVICE:-}" ]]; then
  CT_NAME="${SERVICE_CT_MAP[$SERVICE]:-}"
fi

# init-config called, SERVICE not needed
if $INIT_CONFIG; then
  init_config
  exit 0
fi

load_config_chain
vlog "Using settings: mode=${MODE}, service=${SERVICE}" # todo: after read config, show all feeded variables

if [[ -n "${CLI_MODE:-}" ]]; then
  MODE="$CLI_MODE"
fi
if [[ -n "${CLI_SERVICE:-}" ]]; then
  SERVICE="$CLI_SERVICE"
fi
apply_cli_overrides

resolve_home_paths

# ab hier: normaler Betrieb, SERVICE zwingend
vlog "__main_normal__"
if [[ -z "${SERVICE:-}" ]]; then
  error "SERVICE not set"
fi

resolve_paths
prepare

if [[ -n "${SERVICE_GETDATA:-}" ]]; then
  get_service_data
fi

if $USE_USB; then
  [[ -b "$USB_ID" ]] && DESTDIR="$USB_MOUNT/$DATASET/$SERVICE" || error "USB device not found"
  # Automount minimal
  # mount | grep "$USB_MOUNT" || mount "$USB_ID" "$USB_MOUNT"
fi


########################################
# Execute part
#
vlog "__main_execute__"
EXIT_CODE=0
case "$MODE" in
    backup)
        check_service_running || true
        SERVICE_WAS_RUNNING="${SERVICE_RUNNING}"
        take_snapshot
        $SERVICE_STOP_BEFORE && service_stop
        rotate_logfile
        backup_restore_blockchain
        $VERIFY && verify_backup_restore || EXIT_CODE=$?
        $SERVICE_START_AFTER && service_start
        $VERBOSE && list_snapshots
        ;;
    merge)
        service_stop
        merge_dirs
        $VERIFY && verify_backup_restore || EXIT_CODE=$?
        #$SERVICE_START_AFTER && service_start
        $VERBOSE && list_snapshots
        ;;
    verify)
        verify_backup_restore || EXIT_CODE=$?
        $VERBOSE && list_snapshots
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
        service_stop
        restore_tmp="$SRCDIR"; SRCDIR="$DESTDIR"; DESTDIR="$restore_tmp"
        backup_restore_blockchain
        restore_tmp="$SRCDIR"; SRCDIR="$DESTDIR"; DESTDIR="$restore_tmp"
        $VERIFY && verify_backup_restore || EXIT_CODE=$?
        ;;
esac

########################################
# Telemetry
#
vlog "__main_telemetry__"
END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))
END_TS=$(date +%s)
RUNTIME=$((END_TS - START_TS))
collect_metrics "$RUNTIME" "$EXIT_CODE"
telemetry_run_end "$RUNTIME" "$EXIT_CODE"
log "Script finished successfully"
exit "$EXIT_CODE"
#
# End
########################################
