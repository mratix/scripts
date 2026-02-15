#!/bin/bash
set -euo pipefail
# ============================================================
# backup_blockchain_truenas-safe.sh
# Backup & restore script for blockchain on TrueNAS Scale (safe version)
#
# NOTE: All scripts (gold/pro/safe/pacman) and *.conf files
#       live together in $HOME/scripts - keep them compatible!
#
# Supported apps/services:
#   - bitcoind
#   - monerod
#   - chia
#   - electrs
#   - mempool
#
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="260215-safe"
# ============================================================

echo "-------------------------------------------------------------------------------"
echo "Backup blockchain and or services to NAS/USB (safe version)"
THIS_HOST=$(hostname -s)

# --- globals (override via safe.conf)
NAS_USER="" NAS_HOST="" NAS_HOSTNAME="" NAS_SHARE="" POOL="" DATASET=""
DEFAULT_MOUNTPATH="" USB_DEVICE="" USB_ID="" USB_MOUNT="" RSYNC_OPTS=""
LOG_FORMAT="" LOG_LEVELS="" SRCDIR="" DESTDIR="" SRC_BASE="" DEST_BASE=""

# --- Load external configuration (see safe.conf.example)
scriptdir="$(dirname "$(readlink -f "$0")")"
configfile="${scriptdir}/safe.conf"
if [[ -f "$configfile" ]]; then
    source "$configfile"
fi

# --- config defaults (you can edit here)
NAS_USER="${NAS_USER:-}"
NAS_HOST="${NAS_HOST:-}"
NAS_HOSTNAME="${NAS_HOSTNAME:-}"
NAS_SHARE="${NAS_SHARE:-blockchain}"
POOL="${POOL:-tank}"
DATASET="${DATASET:-blockchain}"
NAS_MOUNT="${DEFAULT_MOUNTPATH:-/mnt/$NAS_HOSTNAME/${NAS_SHARE}}"
SRC_BASE="${SRC_BASE:-/mnt/$POOL/$DATASET}"
DEST_BASE="${NAS_MOUNT:-/mnt/$NAS_HOSTNAME/${NAS_SHARE}}"

# --- runtime defaults
today=$(date +%y%m%d)
now=$(date +%y%m%d%H%M%S)
BLOCKCHAIN=""
SERVICE=""
HEIGHT=0
RESTORE=false
SRCDIR="${SRCDIR:-}"
DESTDIR="${DESTDIR:-}"
is_zfs=true
is_mounted=false
use_usb=false
VERBOSE=false
FORCE=false
srcsynctime=""
destsynctime=""

# --- logger
show() { echo "$*"; }
log() { echo "$(date +'%Y-%m-%d %H:%M:%S') $*"; }
#vlog() { [[ "${VERBOSE:-false}" == true ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') $*" >&2 || true; }
vlog() { $VERBOSE || return 0; log "> $*"; }
warn() { log "WARNING: $*"; }
error() { log "ERROR: $*" >&2; exit 1; }


# --- Validate height input
validate_height() {
    local input_height="$1"
    local service_name="$2"

    case "$service_name" in
        bitcoind)
            # Bitcoin height should be 6-8 digits (current ~800k)
            if ! [[ "$input_height" =~ ^[0-9]{6,8}$ ]]; then
                warn "Invalid Bitcoin height: $input_height (should be 6-8 digits)"
                return 1
            fi
            ;;
        monerod)
            # Monero height should be 6-7 digits (current ~3M)
            if ! [[ "$input_height" =~ ^[0-9]{6,7}$ ]]; then
                warn "Invalid Monero height: $input_height (should be 6-7 digits)"
                return 1
            fi
            ;;
        chia)
            # Chia height can vary, use reasonable range
            if ! [[ "$input_height" =~ ^[0-9]{6,8}$ ]]; then
                warn "Invalid Chia height: $input_height (should be 6-8 digits)"
                return 1
            fi
            ;;
        *)
            # undefined case, exit
            warn "Error: Invalid argument '$1'"
            show "Usage: $0 btc|xmr|xch|electrs|mempool|<servicename> <height>|restore|verbose|force|mount|umount"
            exit 1
        ;;
    esac

    vlog "Validated height: $input_height for SERVICE: $service_name"
    return 0
}


# --- mount destination
mount_dest(){
vlog "__mount_dest__"

[ ! -d "${NAS_MOUNT}" ] && mkdir -p ${NAS_MOUNT}
if [[ "$use_usb" == true ]]; then
    mount_usb
else
    # mount nas share
    if mount | grep -q "${NAS_MOUNT}"; then
        log "Network share already mounted"
    elif mount -t cifs -o user="$NAS_USER" "//$NAS_HOST/${NAS_SHARE}" "${NAS_MOUNT}"; then
        log "Network share mounted successfully"
    else
        error "Failed to mount network share //${NAS_HOST}/${NAS_SHARE} to ${NAS_MOUNT}"
    fi
    sleep 2
    if [ -f "${NAS_MOUNT}/$NAS_HOSTNAME.dummy" ] && [ -f "${NAS_MOUNT}/dir.dummy" ]; then
        show "${NAS_MOUNT} is a valid backup storage."
    else
        error "${NAS_MOUNT} validation failed - check dummy files"
    fi
    if [ ! -w "${NAS_MOUNT}/" ]; then
        warn "Error: Destination ${NAS_MOUNT} on //$NAS_HOST/${NAS_SHARE} is NOT writable."
        error "${NAS_MOUNT} write permissions deny"
    fi
    is_mounted=true
fi
}


# --- mount usb device
mount_usb(){
    [ ! -d "${USB_MOUNT}" ] && mkdir -p ${USB_MOUNT}
    if mount | grep -q ${USB_MOUNT}; then
        log "USB already mounted"
    elif mount "${USB_DEVICE}" ${USB_MOUNT}; then
        log "USB mounted successfully"
    else
        error "Failed to mount ${USB_DEVICE} to ${USB_MOUNT}"
    fi
    sleep 2
    if [ ! -f "${USB_MOUNT}/usb.dummy" ]; then
        error "Mounted disk is not valid and/or not prepared as backup storage!"
    fi
    if [ ! -w "${USB_MOUNT}/" ]; then
        warn "Error: Disk ${USB_MOUNT} is NOT writable!"
        error "${USB_MOUNT} write permissions deny"
    fi
    is_mounted=true
    show "USB disk is (now) mounted and valid backup storage."
    log "${USB_MOUNT} mounted, valid"
}


# --- unmount destination
unmount_dest(){
        sync
        df -h | grep ${NAS_SHARE}
        mount | grep ${NAS_MOUNT} >/dev/null
        [ $? -eq 0 ] && umount ${NAS_MOUNT} || is_mounted=false
}


# --- evaluate environment
prepare() {
log "Script started at $(date +%H:%M:%S)"

# rsync options
if [[ "$VERBOSE" == true ]]; then
    RSYNC_OPTS="-aLx --numeric-ids --mkpath --delete --stats --info=progress2"
else
    RSYNC_OPTS="-avLhx --numeric-ids --mkpath --delete --stats --info=progress2"
fi

# construct paths
    [[ "$RESTORE" == false ]] && SRCDIR=${SRC_BASE}/${SERVICE} DESTDIR=${DEST_BASE}/${SERVICE}
    [[ "$RESTORE" == true ]] && DESTDIR=${SRC_BASE}/${SERVICE} SRCDIR=${DEST_BASE}/${SERVICE}
    [[ "$use_usb" == true ]] && DESTDIR=${USB_MOUNT}/${NAS_SHARE}/${SERVICE}

# output results
    show "------------------------------------------------------------"
    show "Identified blockchain is: ${BLOCKCHAIN}"
    show "Used service is         : ${SERVICE}"
    show "Source path             : ${SRCDIR}"
    show "Destination path        : ${DESTDIR}"
    show "------------------------------------------------------------"
    log "Backup direction: ${SRCDIR} > ${DESTDIR}"

    show "Please check paths (continuing in 5 seconds)..."
    sleep 5
mount_dest
}


# --- pre-tasks, stop SERVICE
prestop(){
vlog "__prestop__"

    show "Time to stop running service."
    # Wait for service down with timeout
    local timeout=180  # 3 minutes max wait
    local elapsed=0
    local check_interval=10

    while [ $elapsed -lt $timeout ]; do
        if [ -f "${SRCDIR}/${SERVICE}.pid" ]; then
            show "  Wait for process to stop... (${elapsed}s elapsed)"
            sleep $check_interval
            ((elapsed += check_interval))
        else
            show "Great, service ${SERVICE} is down."
            break
        fi
    done

# service check, final verification
if [ -f "${SRCDIR}/${SERVICE}.pid" ]; then
    show "Warning: Service may still be running after $timeout seconds."
    show "Please verify manually that ${SERVICE} is stopped before proceeding."
    read -r -p "Continue anyway? (y/N): " -t 30 confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        warn "Aborting due to potentially running service."
        exit 1
    fi
fi

show "------------------------------------------------------------"
}


latest_manifest() {
    # Take only the latest MANIFEST file
    ls -1t "$1"/chainstate/MANIFEST-* 2>/dev/null | head -n1
}

# --- compare src-dest times
compare() {
    if [ "${SERVICE}" = "bitcoind" ]; then
        srcfile=$(latest_manifest "${SRCDIR}")
        destfile=$(latest_manifest "${DESTDIR}")
    elif [ "${SERVICE}" = "monerod" ]; then
        srcfile="${SRCDIR}/lmdb/data.mdb"
        destfile="${DESTDIR}/lmdb/data.mdb"
    elif [ "${SERVICE}" = "chia" ]; then
        srcfile="${SRCDIR}/.chia/mainnet/db/blockchain_v2_mainnet.sqlite"
        destfile="${DESTDIR}/.chia/mainnet/db/blockchain_v2_mainnet.sqlite"
    fi

    srcsynctime=$(stat -c %Y "$srcfile")
    destsynctime=$(stat -c %Y "$destfile")

    show "------------------------------------------------------------"
    show "Remote backup : $(date -d "@$destsynctime")"
    show "Local data    : $(date -d "@$srcsynctime")"
    if (( $destsynctime > $srcsynctime )); then
        show "Attention: Remote backup is newer than local data."
    fi
    if [ "$destfile" -nt "$srcfile" ]; then
        return 1    # backup is newer
    else
        return 0    # local newer or equal
    fi
}


# --- get blockchain height from logs
get_block_height() {
    local parsed_height=0

    # First try: parse from current log file
    case "${SERVICE}" in
        bitcoind)
            if [ -f "${SRCDIR}/debug.log" ]; then
                vlog "Looking for height in ${SRCDIR}/debug.log"
                local update_tip_line=$(tail -n20 "${SRCDIR}/debug.log" | grep UpdateTip | tail -1)
                if [[ "$update_tip_line" =~ height=([0-9]+) ]]; then
                    parsed_height="${BASH_REMATCH[1]}"
                    vlog "Parsed Bitcoin height: $parsed_height from debug.log"
                fi
            else
                vlog "debug.log not found, trying h*-stamp"
                # Fallback: get height from h* files (last backup height)
                local last_h=$(ls -1t ${SRCDIR}/h[0-9]* 2>/dev/null | head -1)
                if [ -n "$last_h" ]; then
                    parsed_height=$(basename "$last_h" | sed 's/h//')
                    vlog "Got height from h*-stamp: $parsed_height"
                fi
            fi
            ;;
        monerod)
            if [ -f "${SRCDIR}/bitmonero.log" ]; then
                # Parse height from Synced line: Synced 3495136/3608034
                local synced_line=$(tail -n20 "${SRCDIR}/bitmonero.log" | grep "Synced" | tail -1)
                if [[ "$synced_line" =~ Synced\ ([0-9]+)/[0-9]+ ]]; then
                    parsed_height="${BASH_REMATCH[1]}"
                    vlog "Parsed Monero height: $parsed_height from bitmonero.log"
                fi
            fi
            ;;
        chia)
            # Chia height parsing - check multiple log locations
            local chia_log_files=(
                "${SRCDIR}/.chia/mainnet/log/debug.log"
                "${SRCDIR}/.chia/mainnet/log/wallet.log"
                "${SRCDIR}/log/debug.log"
            )

            for log_file in "${chia_log_files[@]}"; do
                if [ -f "$log_file" ]; then
                    # Try to parse height from various chia log patterns
                    local height_line=$(tail -n50 "$log_file" | grep -E "(height|Height|block|Block)" | tail -1)
                    if [[ "$height_line" =~ (HEIGHT|Height)[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                        parsed_height="${BASH_REMATCH[2]}"
                        vlog "Parsed Chia height: $parsed_height from $log_file"
                        break
                    elif [[ "$height_line" =~ (block|Block)[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                        parsed_height="${BASH_REMATCH[2]}"
                        vlog "Parsed Chia block height: $parsed_height from $log_file"
                        break
                    fi
                fi
            done
            ;;
        electrs)
            # electrs doesn't have direct height in logs, use bitcoind height
            if [ -f "${SRCDIR}/../bitcoind/debug.log" ]; then
                local update_tip_line=$(tail -n20 "${SRCDIR}/../bitcoind/debug.log" | grep UpdateTip | tail -1)
                if [[ "$update_tip_line" =~ height=([0-9]+) ]]; then
                    parsed_height="${BASH_REMATCH[1]}"
                    vlog "Parsed electrs height: $parsed_height from bitcoind debug.log"
                fi
            fi
            ;;
    esac

    # Validate parsed height is numeric and greater than 111111
    if [[ "$parsed_height" =~ ^[0-9]+$ ]] && [ "$parsed_height" -gt 111111 ]; then
        echo "$parsed_height"
    else
        echo "0"
    fi
}

# --- pre-tasks, update height-stamps
prebackup(){
cd ${SRCDIR}

compare
rc=$?
if [ "$rc" -ne 0 ]; then
    show "Remote backup holds newer data. Prevent overwrite, stopping."
    error "remote backup is higher as local"
fi

    # Service-specific minimum reasonable heights
    local min_height=0
    case "${SERVICE}" in
        bitcoind) min_height=900000 ;;   # Bitcoin ~936k, min ~900k
        monerod)  min_height=3000000 ;;  # Monero ~3.5M, min ~3M
        chia)     min_height=800000 ;;   # Chia ~945k, min ~800k
        electrs)  min_height=900000 ;;   # Electrs follows Bitcoin
        *)        min_height=111111 ;;   # Default fallback
    esac

    # Check if height needs to be set (either too low or zero)
    if [[ "$HEIGHT" -lt "$min_height" ]]; then
        vlog "Current height: $HEIGHT, min: $min_height - will try detection"
        # Try to auto-detect height from logs
        local detected_height=$(get_block_height)
        vlog "Detected value: '$detected_height'"
        if [[ "$detected_height" -gt 0 ]]; then
            log "Detected blockchain height: $detected_height"
            HEIGHT="$detected_height"
            show "Using detected height."
        else
            # Show log snippets for manual reference
            show "Height too low for ${SERVICE} (minimum: $min_height)"
            show "Showing recent log entries for manual height setting..."
            # bitcoind
            [ -f ${SRCDIR}/debug.log ] && tail -n20 debug.log | grep UpdateTip

            # monerod
            [ -f ${SRCDIR}/bitmonero.log ] && tail -n20 bitmonero.log | grep Synced

            # chia
            # no parsable height in log file
            #[ -f ${SRCDIR}/.chia/mainnet/log/debug.log ] && tail -n20 ${SRCDIR}/.chia/mainnet/log/debug.log | grep ...

            # electrs
            [ -f ${SRCDIR}/db/bitcoin/LOG ] && tail -n20 ${SRCDIR}/db/bitcoin/LOG

            # Ask for manual height input only if not detected
            read -p "Set new Blockchain height: h" HEIGHT
        fi

        # Show height summary (always)
        show "Remote backuped heights found: $(find ${DESTDIR} -maxdepth 1 -name "h[0-9]*" 2>/dev/null | xargs -n1 basename 2>/dev/null | sed -e 's/\..*$//' | tr '\n' ' ' || echo "None")"
        show "Last backuped height         : $(find ${SRCDIR} -maxdepth 1 -name "h[0-9]*" 2>/dev/null | xargs -n1 basename 2>/dev/null | sed -e 's/\..*$//' | tr '\n' ' ' || echo "None")"
        show "Current detected height      : $detected_height"
        show "Current configured height    : $HEIGHT"
        #show "Minimum reasonable height    : $min_height"
    fi

    # Validate height before proceeding
    if [[ ! "$HEIGHT" =~ ^[0-9]+$ ]] || [ "$HEIGHT" -le 0 ]; then
        warn "Error: Invalid height value '$HEIGHT'. Must be a positive number."
        error "invalid height $HEIGHT"
    fi

    show "Blockchain height is now: $HEIGHT"

show ""
show "Rotate log file started at $(date +%H:%M:%S)"
    cd ${SRCDIR}

    # Validate source directory exists and is writable
    if [[ ! -w "${SRCDIR}" ]]; then
        warn "Error: Source directory ${SRCDIR} is not writable."
        error "SRCDIR ${SRCDIR} not writable"
    fi

    # Move existing height stamp files more safely
    log "Set height stamp to h$HEIGHT"
    find ${SRCDIR} -maxdepth 1 -name "h[0-9]*" -type f -exec mv -u {} ${SRCDIR}/h$HEIGHT \; 2>/dev/null || true

    # Rotate SERVICE-specific log files with validation
    if [ -f ${SRCDIR}/debug.log ]; then
        log "Rotating Bitcoin log with height $HEIGHT"
        mv -u ${SRCDIR}/debug.log ${SRCDIR}/debug_h$HEIGHT.log
    fi

    if [ -f ${SRCDIR}/bitmonero.log ]; then
        log "Rotating Monero log with height $HEIGHT"
        mv -u ${SRCDIR}/bitmonero.log ${SRCDIR}/bitmonero_h$HEIGHT.log
    fi

    if [ -f ${SRCDIR}/.chia/mainnet/log/debug.log ]; then
        log "Rotating Chia log with height $HEIGHT"
        mv -u ${SRCDIR}/.chia/mainnet/log/debug.log ${SRCDIR}/.chia/mainnet/log/debug_h$HEIGHT.log
    fi

    if [ -f ${SRCDIR}/db/bitcoin/LOG ]; then
        log "Rotating Electrum log with height $HEIGHT"
        mv -u ${SRCDIR}/db/bitcoin/LOG ${SRCDIR}/electrs_h$HEIGHT.log
    fi
    # Clean up old log files safely
    find ${SRCDIR}/db/bitcoin/LOG.old* -type f -exec rm {} \; 2>/dev/null || true
}


# --- snapshot
snapshot(){
show "Hint: Best time to take a snapshot is now."
# snapshot zfs dataset
if [ "$is_zfs" ]; then
    show "Prepare dataset $DATASET for a snapshot..."
    sync
    sleep 1
    snapname="script-$(date +%Y-%m-%d_%H-%M)"
    zfs snapshot -r $POOL/$DATASET/$SERVICE@$snapname 2>/dev/null || true
    log "Snapshot '$snapname' was taken."
fi
}

# --- Folders Array leeren
reset_folders_array() {
    folder[1]=""
    folder[2]=""
    folder[3]=""
    folder[4]=""
    folder[5]=""
}

# --- main rsync job
backup_blockchain(){
cd ${SRCDIR}

show ""
show "Main task started at $(date +%H:%M:%S)"
vlog "backup_blockchain__pre"
reset_folders_array    # Array leeren

# Ensure both timestamps are valid numbers
if [ -z "$srcsynctime" ] || [ -z "$destsynctime" ]; then
    warn "Error: One of the timestamps is missing or invalid."
    error "Exit"
fi

# Prevent overwrite if destination is newer (and no force flag set)
if [ "$srcsynctime" -lt "$destsynctime" ] && [ ! "$FORCE" ]; then
    show "Destination is newer (and maybe higher) than the source."
    show "Better use RESTORE. A force will ignore this situation. End."
    error "src-dest comparing triggers abort"
    exit 1
elif [ "$srcsynctime" -lt "$destsynctime" ] && [ "$FORCE" ]; then
    show "Destination is newer than the source."
    show "Force will now overwrite it. This will downgrade the destination backup."
    log "src-dest downgrade forced"
fi

case "${SERVICE}" in
    bitcoind)
        cp -u anchors.dat banlist.json debug*.log fee_estimates.dat mempool.dat peers.dat ${DESTDIR}/ 2>/dev/null || true
        cp -u bitcoin.conf ${DESTDIR}/bitcoin.conf.$THIS_HOST
        cp -u settings.json ${DESTDIR}/settings.json.$THIS_HOST
        folder[1]="blocks"
        folder[2]="chainstate"
        #  coinstats is EOL, only up to Bitcoin core v1.0.30       #
        #  if [[ -f "${SRCDIR}/indexes/coinstats/db/CURRENT" || \  #
        if [[ -f "${SRCDIR}/indexes/coinstatsindex/db/CURRENT" ]]; then
            folder[3]="indexes"
        else
            folder[3]="indexes/blockfilter"
            folder[4]="indexes/txindex"
        fi
    ;;
    monerod)
        cp -u bitmonero*.log p2pstate.* rpc_ssl.* ${DESTDIR}/
        folder[1]="lmdb"
    ;;
    chia)
        folder[1]=".chia"
        folder[2]=".chia_keys"
        folder[3]="plots"
    ;;
esac
    cp -u "h[0-9]*" ${DESTDIR}/ 2>/dev/null || true

i=1
while [ "${folder[i]}" != "" ]; do
    show "------------------------------------------------------------"
    show "Start backup job: ${SERVICE}/${folder[i]}"
    log "start task backup main"
    ionice -c 2 \
    rsync \
        ${RSYNC_OPTS} \
        --exclude '.nobakup' \
        ${SRCDIR}/${folder[i]}/ ${DESTDIR}/${folder[i]}/
    [ $? -ne 0 ] && warn "Errors during backup ${DESTDIR}/${folder[i]}." && vlog "task backup ${folder[i]} fail"
    sync
    ((i++))
done
reset_folders_array    # Array leeren
show "------------------------------------------------------------"
log "Main task ended at $(date +%H:%M:%S)"
}


# --- postbackup tasks
postbackup(){
if [[ "$RESTORE" == false ]]; then
    chown -R apps:apps ${SRCDIR}
else
    chown -R apps ${DESTDIR}
    show "Restore task finished. Check the result in ${DESTDIR}."
fi

show "Script ended at $(date +%H:%M:%S)"
show "End."
show "------------------------------------------------------------"
log "script end"
}


# --- main logic

# not args given
[ $# -eq 0 ] && { show "Arguments needed: btc|xmr|xch|electrs|mempool|<servicename> <height>|restore|verbose|debug|force|mount|umount"; exit 1; }

# Enhanced argument parsing with getopts
usage() {
    show "Usage: $0 [OPTIONS] [COMMAND] [ARGS]"
    show ""
    show "COMMANDS:"
    show "  btc|bitcoin|xmr|monero|xch|chia         Backup specific blockchain"
    show "  bitcoind|monerod|chia|electrs|mempool   Backup specific service"
    show "  restore                    Restore blockchain data"
    show "  mount                      Mount backup destination"
    show "  umount                     Unmount backup destination"
    show ""
    show "OPTIONS:"
    show "  -b,  --blockchain NAME     Set blockchain"
    show "  -s,  --service NAME        Set specific service"
    show "  -bh, --height N            Set blockchain height (numeric)"
    show "  -f,  --force               Force operation (bypass safety checks)"
    show "  -v,  --verbose             Enable verbose output"
    show "  -x,  --debug               Enable shell debugging"
    show "       --usb DEVICE          Use USB device, instead local or network"
    show "  -h,  --help                Show this help message"
    show ""
    show "EXAMPLES:"
    show "  $0 btc 936125              # Backup Bitcoin at height 936125"
    show "  $0 --service monerod -v    # Backup Monero with verbose output"
    show "  $0 restore -b chia --force # Restore Chia blockchain data"
    show ""
}

# Parse arguments with proper getopts-style parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        # Commands (without arguments)
        btc|bitcoin|xmr|monero|xch|chia)
            # Map blockchain to service
            case "$1" in
                btc|bitcoin) BLOCKCHAIN=btc SERVICE="bitcoind" ;;
                xmr|monero)  BLOCKCHAIN=xmr SERVICE="monerod" ;;
                xch|chia)    BLOCKCHAIN=xch SERVICE="chia" ;;
            esac
            shift
            ;;
        bitcoind|monerod|chia|electrs|mempool)
            SERVICE="$1"
            shift
            ;;
        restore)
            RESTORE=true
            shift
            ;;
        mount)
            mount_dest
            exit 0
            ;;
        umount)
            unmount_dest
            exit 0
            ;;
        # Options (require arguments)
        -b|--blockchain)
            [[ -z "${2:-}" ]] && { error "--blockchain requires a value"; }
            BLOCKCHAIN="$2"
            shift 2
            ;;
        -s|--service)
            [[ -z "${2:-}" ]] && { error "--service requires a value"; }
            SERVICE="$2"
            shift 2
            ;;
        -bh|--height)
            [[ -z "${2:-}" ]] && { error "--height requires a value"; }
            HEIGHT="$2"
            shift 2
            ;;
        --usb)
            [[ -z "${2:-}" ]] && { error "--usb requires a value, e.g. /dev/sdc1"; }
            use_usb=true
            USB_DEVICE="$2"
            shift 2
            ;;
        # Boolean flags
        -f|--force)
            FORCE=true
            show "force is enabled"
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            show "verbose is enabled"
            shift
            ;;
        -x|--debug)
            set -x
            show "happy troubleshooting: debug is active"
            VERBOSE=true
            shift
            ;;
        # Aliases and special cases
        help|--help|-h)
            usage
            exit 0
            ;;
        ver|version|--version)
            show "$version"
            exit 0
            ;;
        # Legacy/positional argument support
        *)
            # Handle positional arguments for backward compatibility
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                HEIGHT="$1"
                shift
            else
                warn "Error: Unknown option '$1'"
                usage
                exit 1
            fi
            ;;
    esac
done

# --- execute part, based on parsed arguments
if [[ -n "${SERVICE}" ]]; then
    if [[ "$HEIGHT" -gt 0 ]]; then
        validate_height "$HEIGHT" "${SERVICE}" || exit 1
    fi
    [[ "$VERBOSE" == true ]] && show "SERVICE: $SERVICE, HEIGHT: $HEIGHT"
    prepare
    prestop
    prebackup
    snapshot
    backup_blockchain
    postbackup
elif [[ "$RESTORE" == true ]]; then
    [[ "$FORCE" != true ]] && error "Task ignored. Force not given. Exit." && exit 1
    show "------------------------------------------------------------"
    warn "Attention, RESTORE change the direction Source <-> Destination."
    vlog "direction is restore"
    prepare
    prestop
    backup_blockchain
    postbackup
fi

# --- main logic end

log "Script finished successfully"
exit 0

# ------------------------------------------------------------------------
# todos
# TODO: move SERVICE_CONFIGS mapping to pro version
# todo: apply the functional blockheight logfile-parsing to pro version
# ------------------------------------------------------------------------
# errors

