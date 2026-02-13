#!/bin/bash
set -euo pipefail
# ============================================================
# backup_blockchain_truenas-safe.sh
# Backup & RESTORE script for blockchain on TrueNAS Scale (safe version)
#
# NOTE: All scripts (gold/enterprise/safe/pacman) and *.conf files
#       live together in $HOME/scripts - keep them compatible!
#
# Supported SERVICEs:
#   - bitcoind
#   - monerod
#   - chia
#   - electrs
#   - memPOOL
#
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="260213-safe"
# ============================================================

echo "-------------------------------------------------------------------------------"
echo "Backup blockchain and or SERVICEs to NAS/USB (safe version)"

# --- config defaults (override via safe.conf)
NAS_USER=""
NAS_HOST=""
NAS_HOSTNAME=""
NAS_SHARE=""

# Load external configuration - see safe.conf.example
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="${SCRIPT_DIR}/safe.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Set lowercase variants for internal use
nasuser="${NAS_USER:-}"
nashost="${NAS_HOST:-}"
nashostname="${NAS_HOSTNAME:-}"
nasshare="${NAS_SHARE:-}"
zfs_POOL="${ZFS_POOL:-}"
zfs_DATASET="${ZFS_DATASET:-blockchain}"

# --- runtime defaults
today=$(date +%y%m%d)
now=$(date +%y%m%d%H%M%S)
NASMOUNT=/mnt/$nashostname/$nasshare
SERVICE=""
RESTORE=false
IS_MOUNTED=false
USE_USB=false
FORCE=false
VERBOSE=false
debug=false
HEIGHT=0
IS_ZFS=false
POOL=""
DATASET=""
SRCDIR=""
DESTDIR=""
folder[1]="" folder[2]="" folder[3]="" folder[4]="" folder[5]=""
USBDEV="/dev/sdf1"
RSYNC_OPTS="-avz -P --update --stats --delete --info=progress2"
full_mode=false
TARGET_SERVICE=""
TARGET_HOST=""

# --- logger
show() { echo "$*"; }
log() { echo "$(date +'%Y-%m-%d %H:%M:%S') $*"; }
vlog() { [[ "${VERBOSE:-false}" == true ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') $*"; }
warn() { echo "$(date +'%Y-%m-%d %H:%M:%S') WARNING: $*"; }
error() { echo "$(date +'%Y-%m-%d %H:%M:%S') ERROR: $*" >&2; exit 1; }


# --- Validate HEIGHT input
validate_HEIGHT() {
    local input_height="$1"
    local service_name="$2"

    case "$SERVICE_name" in
        bitcoind)
            # Bitcoin HEIGHT should be 6-8 digits (current ~800k)
            if ! [[ "$input_HEIGHT" =~ ^[0-9]{6,8}$ ]]; then
                warn "Invalid Bitcoin HEIGHT: $input_HEIGHT (should be 6-8 digits)"
                return 1
            fi
            ;;
        monerod)
            # Monero HEIGHT should be 6-7 digits (current ~3M)
            if ! [[ "$input_HEIGHT" =~ ^[0-9]{6,7}$ ]]; then
                warn "Invalid Monero HEIGHT: $input_HEIGHT (should be 6-7 digits)"
                return 1
            fi
            ;;
        chia)
            # Chia HEIGHT can vary, use reasonable range
            if ! [[ "$input_HEIGHT" =~ ^[0-9]{1,8}$ ]]; then
                warn "Invalid Chia HEIGHT: $input_HEIGHT (should be 1-8 digits)"
                return 1
            fi
            ;;
        *)
            # undefined case, exit
            warn "Error: Invalid argument '$1'"
            show "Usage: $0 btc|xmr|xch|electrs|<SERVICEname> <HEIGHT>|all|RESTORE|VERBOSE|FORCE|mount|umount"
            exit 1
        ;;
    esac

    vlog "Validated HEIGHT: $input_HEIGHT for SERVICE: $SERVICE_name"
    return 0
}


# --- mount destination
mount_dest(){
[ ! -d "$NASMOUNT" ] && mkdir -p $NASMOUNT
if [[ "$USE_USB" == true ]]; then
    mount_usb
else
    # mount nas share
    mount | grep $NASMOUNT >/dev/null
    [ $? -eq 0 ] || mount -t cifs -o user=$nasuser //$nashost/$nasshare $NASMOUNT
    sleep 2
    [ -f "$NASMOUNT/$nashostname.dummy" ] && [ -f "$NASMOUNT/dir.dummy" ] && show "Network share $NASMOUNT is mounted and valid backup storage."
        if [ ! -w "$NASMOUNT/" ]; then
            warn "Error: Destination $NASMOUNT on //$nashost/$nasshare is NOT writable."
            error "$NASMOUNT write permissions deny"
        else
            IS_MOUNTED=true
            log "share $NASMOUNT mounted, validated"
        fi
fi
}


# --- mount usb device
mount_usb(){
    # NASMOUNT=/mnt/usb/$nasshare # was set before
    [ ! -d "/mnt/usb" ] && mkdir -p /mnt/usb
    mount | grep /mnt/usb >/dev/null
    [ $? -eq 0 ] || mount $USBDEV /mnt/usb
    sleep 2
    [ ! -f "$NASMOUNT/usb.dummy" ] && { show "Mounted disk is not valid and or not prepared as backup storage! Exit."; exit 1; }
        if [ ! -w "$NASMOUNT/" ]; then
            warn "Error: Disk $NASMOUNT is NOT writable! Exit."
            error "usb $NASMOUNT write permissions deny"
        fi
    IS_MOUNTED=true
    show "USB disk is (now) mounted and valid backup storage."
    log "usb $NASMOUNT mounted, valid"
}


# --- unmount destination
unmount_dest(){
        sync
        df -h | grep $nasshare
        mount | grep $NASMOUNT >/dev/null
        [ $? -eq 0 ] && umount $NASMOUNT || IS_MOUNTED=false
}


# --- evaluate environment
prepare(){
show "Script started at $(date +%H:%M:%S)"
log "script started"

# TODO: move SERVICE_CONFIGS mapping to gold/enterprise version
# TODO: implement host/SERVICE auto-detection from SERVICE_CONFIGS
}

# Enhanced prepare function for single SERVICE or full mode
prepare_single_SERVICE() {
    local blockchain_type="${1:-$TARGET_SERVICE}"
    # local hostname_override="${TARGET_HOST:-$(hostname -s)}"  # TODO: for gold/enterprise

    # Map blockchain type to SERVICE if needed
    case "$blockchain_type" in
        btc) SERVICE="bitcoind" ;;
        xmr) SERVICE="monerod" ;;
        xch) SERVICE="chia" ;;
        electrs) SERVICE="electrs" ;;
        memPOOL) SERVICE="memPOOL" ;;
        *) SERVICE="$blockchain_type" ;;
    esac

    # ZFS POOL/DATASET from config (required for safe version)
    if [[ -z "$zfs_POOL" ]]; then
        error "ZFS_POOL not configured in safe.conf"
    fi

    POOL="$zfs_POOL"
    DATASET="$POOL/$zfs_DATASET"
    IS_ZFS=true

    log "SERVICE:$SERVICE POOL:$POOL DATASET:$DATASET"
}

prepare() {
show "Script started at $(date +%H:%M:%S)"
log "script started"

if [[ "$full_mode" == true ]]; then
    show "=== FULL MODE: Backup all configured SERVICEs ==="
    return
fi

prepare_single_SERVICE

# construct paths
    NASMOUNT=/mnt/$nashostname/$nasshare # redefine share, recheck is new $nasshare mounted
    SRCDIR=/mnt/$DATASET/$SERVICE
    DESTDIR=$NASMOUNT/$SERVICE
    [[ "$RESTORE" == true ]] && SRCDIR=/mnt/$DATASET/$SERVICE
# case to usb disk (case RESTORE from network to usb not needed)
    [[ "$USE_USB" == true ]] && DESTDIR=/mnt/usb/$nasshare/$SERVICE

    # Use rsync options from config
    if [[ "$RESTORE" == true ]]; then
        RSYNC_OPTS="${RSYNC_CONFIGS[RESTORE]}"
    elif [[ -n "${RSYNC_CONFIGS[$SERVICE]:-}" ]]; then
        RSYNC_OPTS="${RSYNC_CONFIGS[$SERVICE]}"
    else
        RSYNC_OPTS="-avz -P --update --stats --delete --info=progress2"  # fallback
    fi

# output results
    show "------------------------------------------------------------"
    show "Identified blockchain is $SERVICE"
    log "blockchain/SERVICE=$SERVICE"

    show "Source path     : ${SRCDIR}"
    show "Destination path: ${DESTDIR}"
    show "------------------------------------------------------------"
    log "direction $SRCDIR > $DESTDIR"

    read -r -p "Please check paths. (Autostart in 5 seconds will go to mount destination)" -t 5 -n 1 -s
mount_dest
}


# --- pre-tasks, stop SERVICE
prestop(){
log "try stop $SERVICE"

show "Attempting to stop $SERVICE via TrueNAS API..."

# Try to stop SERVICE using TrueNAS API
if command -v midclt >/dev/null 2>&1; then
    case "$SERVICE" in
        bitcoind)
            # Try different naming conventions
            release_names=("${SERVICE}-knots" "bitcoin-knots" "bitcoind" "bitcoin")
            for release_name in "${release_names[@]}"; do
                if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                    show "Found release: $release_name, stopping..."
                    if midclt call chart.release.scale "$release_name" '{"replica_count":0}' 2>/dev/null; then
                        show "Service $release_name scaling down via API."
                        log "$release_name stopped via API"
                        break
                    fi
                fi
            done
            ;;
        monerod)
            release_names=("${SERVICE}" "monero" "monerod-knots")
            for release_name in "${release_names[@]}"; do
                if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                    show "Found release: $release_name, stopping..."
                    if midclt call chart.release.scale "$release_name" '{"replica_count":0}' 2>/dev/null; then
                        show "Service $release_name scaling down via API."
                        log "$release_name stopped via API"
                        break
                    fi
                fi
            done
            ;;
        chia)
            release_names=("${SERVICE}" "chia-blockchain" "chia-mainnet")
            for release_name in "${release_names[@]}"; do
                if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                    show "Found release: $release_name, stopping..."
                    if midclt call chart.release.scale "$release_name" '{"replica_count":0}' 2>/dev/null; then
                        show "Service $release_name scaling down via API."
                        log "$release_name stopped via API"
                        break
                    fi
                fi
            done
            ;;
    esac
else
    show "midclt command not found, falling back to manual intervention"
fi

show "Checking active SERVICE..."

    show "The $SERVICE SERVICE shutdown and flushing cache takes long time."
    show "Waiting for graceful shutdown..."

    # Wait for SERVICE to stop with timeout
    local timeout=300  # 5 minutes max wait
    local elapsed=0
    local check_interval=10

    while [ $elapsed -lt $timeout ]; do
        if [ -f "${SRCDIR}/$SERVICE.pid" ]; then
            show "Wait for process $SERVICE to stop... (${elapsed}s elapsed)"
            sleep $check_interval
            ((elapsed += check_interval))
        else
            show "Great, SERVICE is now down."
            break
        fi
    done

# --- SERVICE check, final verification
if [ -f "${SRCDIR}/$SERVICE.pid" ]; then
    show "Warning: Service may still be running after $timeout seconds."
    show "Please verify manually that ${SERVICE} is stopped before proceeding."
    read -r -p "Continue anyway? (y/N): " -t 30 confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        show "Aborting due to potentially running SERVICE."
        log "! abort: SERVICE still running"
        exit 1
    fi
else
    show "Service $SERVICE is down."
fi

show "------------------------------------------------------------"
}


latest_manifest() {
    # Take only the latest MANIFEST file
    ls -1t "$1"/chainstate/MANIFEST-* 2>/dev/null | head -n1
}

# --- compare src-dest times
compare() {
    if [ "$SERVICE" = "bitcoind" ]; then
        srcfile=$(latest_manifest "$SRCDIR")
        destfile=$(latest_manifest "$DESTDIR")
    elif [ "$SERVICE" = "monerod" ]; then
        srcfile="$SRCDIR/lmdb/data.mdb"
        destfile="$DESTDIR/lmdb/data.mdb"
    elif [ "$SERVICE" = "chia" ]; then
        srcfile="$SRCDIR/.chia/mainnet/db/blockchain_v2_mainnet.sqlite"
        destfile="$DESTDIR/.chia/mainnet/db/blockchain_v2_mainnet.sqlite"
    fi

    srcsynctime=$(stat -c %Y "$srcfile")
    destsynctime=$(stat -c %Y "$destfile")

    show "------------------------------------------------------------"
    show "Remote backup : $(date -d "@$destsynctime")"
    show "Local data    : $(date -d "@$srcsynctime")"
    if (( destsynctime > srcsynctime )); then
        show "Attention: Remote backup is newer than local data."
    fi
    if [ "$destfile" -nt "$srcfile" ]; then
        return 1    # backup newer
    else
        return 0    # local newer or equal
    fi
}


# --- get blockchain HEIGHT from logs
get_block_HEIGHT() {
    local parsed_height=0

    case "$SERVICE" in
        bitcoind)
            if [ -f "${SRCDIR}/debug.log" ]; then
                # Parse HEIGHT from UpdateTip line: HEIGHT=936124
                local update_tip_line=$(tail -n20 "${SRCDIR}/debug.log" | grep UpdateTip | tail -1)
                if [[ "$update_tip_line" =~ HEIGHT=([0-9]+) ]]; then
                    parsed_HEIGHT="${BASH_REMATCH[1]}"
                    log_debug "Parsed Bitcoin HEIGHT: $parsed_HEIGHT from debug.log"
                fi
            fi
            ;;
        monerod)
            if [ -f "${SRCDIR}/bitmonero.log" ]; then
                # Parse HEIGHT from Synced line: Synced 3495136/3608034
                local synced_line=$(tail -n20 "${SRCDIR}/bitmonero.log" | grep "Synced" | tail -1)
                if [[ "$synced_line" =~ Synced\ ([0-9]+)/[0-9]+ ]]; then
                    parsed_HEIGHT="${BASH_REMATCH[1]}"
                    log_debug "Parsed Monero HEIGHT: $parsed_HEIGHT from bitmonero.log"
                fi
            fi
            ;;
        chia)
            # Chia HEIGHT parsing - check multiple log locations
            local chia_log_files=(
                "${SRCDIR}/.chia/mainnet/log/debug.log"
                "${SRCDIR}/.chia/mainnet/log/wallet.log"
                "${SRCDIR}/log/debug.log"
            )

            for log_file in "${chia_log_files[@]}"; do
                if [ -f "$log_file" ]; then
                    # Try to parse HEIGHT from various chia log patterns
                    local height_line=$(tail -n50 "$log_file" | grep -E "(height|Height|block|Block)" | tail -1)
                    if [[ "$HEIGHT_line" =~ (HEIGHT|Height)[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                        parsed_HEIGHT="${BASH_REMATCH[2]}"
                        log_debug "Parsed Chia HEIGHT: $parsed_HEIGHT from $log_file"
                        break
                    elif [[ "$HEIGHT_line" =~ (block|Block)[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                        parsed_HEIGHT="${BASH_REMATCH[2]}"
                        log_debug "Parsed Chia block HEIGHT: $parsed_HEIGHT from $log_file"
                        break
                    fi
                fi
            done
            ;;
        electrs)
            # electrs doesn't have direct HEIGHT in logs, use bitcoind HEIGHT if available
            if [ -f "${SRCDIR}/../bitcoind/debug.log" ]; then
                local update_tip_line=$(tail -n20 "${SRCDIR}/../bitcoind/debug.log" | grep UpdateTip | tail -1)
                if [[ "$update_tip_line" =~ HEIGHT=([0-9]+) ]]; then
                    parsed_HEIGHT="${BASH_REMATCH[1]}"
                    log_debug "Parsed electrs HEIGHT: $parsed_HEIGHT from bitcoind debug.log"
                fi
            fi
            ;;
    esac

    # Validate parsed HEIGHT is numeric and greater than 0
    if [[ "$parsed_HEIGHT" =~ ^[0-9]+$ ]] && [ "$parsed_HEIGHT" -gt 0 ]; then
        echo "$parsed_HEIGHT"
    else
        echo "0"
    fi
}

# --- pre-tasks, update stamps
prebackup(){
cd $SRCDIR

compare
rc=$?
if [ "$rc" -ne 0 ]; then
    show "Remote holds newer data. Prevent overwrite, stopping."
    exit 1
fi

    # Service-specific minimum reasonable HEIGHTs
    local min_HEIGHT=0
    case "$SERVICE" in
        bitcoind) min_HEIGHT=700000 ;;   # Bitcoin ~800k, min ~700k
        monerod)  min_HEIGHT=3000000 ;;  # Monero ~3.5M, min ~3M
        chia)     min_HEIGHT=800000 ;;   # Chia ~834k, min ~800k
        electrs)   min_HEIGHT=700000 ;;   # Electrs follows Bitcoin
        *)         min_HEIGHT=100000 ;;   # Default fallback
    esac

    # Check if HEIGHT needs to be set (either too low or zero)
    if [[ "$HEIGHT" -lt "$min_HEIGHT" ]]; then
        # Try to auto-detect HEIGHT from logs
        local detected_HEIGHT=$(get_block_HEIGHT)
        if [[ "$detected_HEIGHT" -gt 0 ]]; then
            show "Detected blockchain HEIGHT: $detected_HEIGHT"
            show "Minimum reasonable HEIGHT for $SERVICE: $min_HEIGHT"
            read -p "Use detected HEIGHT? (Y/n): " confirm
            if [[ "$confirm" != "n" && "$confirm" != "N" ]]; then
                HEIGHT="$detected_HEIGHT"
            fi
        else
            # Show log snippets for manual reference
            show "Height too low for $SERVICE (minimum: $min_HEIGHT)"
            show "Showing recent log entries for manual HEIGHT setting:"
            # bitcoind
            [ -f ${SRCDIR}/debug.log ] && tail -n20 debug.log | grep UpdateTip
            # example line: 2026-02-11T23:43:57Z UpdateTip: new best=000000000000000000015ca4e4a3fa112840d412315e42c4e89ec22dfdcf158f HEIGHT=936124 version=0x2478c000 log2_work=96.079058 tx=1308589657 date='2026-02-11T23:43:48Z' progress=1.000000 cache=5.1MiB(37068txo)

            # monerod
            [ -f ${SRCDIR}/bitmonero.log ] && tail -n20 bitmonero.log | grep Synced
            # example line: 2026-02-11 23:52:18.824	[P2P7]	INFO	global	src/cryptonote_protocol/cryptonote_protocol_handler.inl:1618	Synced 3495136/3608034 (96%, 112898 left, 1% of total synced, estimated 14.1 days left)

            # chia
            # no parsable HEIGHT in log file
            #[ -f ${SRCDIR}/.chia/mainnet/log/debug.log ] && tail -n20 ${SRCDIR}/.chia/mainnet/log/debug.log | grep ...

            # electrs
            [ -f ${SRCDIR}/db/bitcoin/LOG ] && tail -n20 ${SRCDIR}/db/bitcoin/LOG
        fi

        # Enhanced HEIGHT file listing with better pattern matching
        show "Remote backuped HEIGHTs found     : $(find ${DESTDIR} -maxdepth 1 -name "h[0-9]*" 2>/dev/null | xargs -n 1 basename 2>/dev/null | sed -e 's/\..*$//' || show "None")"
        show "Local working HEIGHT is           : $(find ${SRCDIR} -maxdepth 1 -name "h[0-9]*" 2>/dev/null | xargs -n 1 basename 2>/dev/null | sed -e 's/\..*$//' || show "None")"
        show "Current configured HEIGHT          : $HEIGHT"
        show "Minimum reasonable HEIGHT for $SERVICE: $min_HEIGHT"
        show "------------------------------------------------------------"
        read -p "Set new Blockchain HEIGHT   : h" HEIGHT
    fi

    # Validate HEIGHT before proceeding
    if [[ ! "$HEIGHT" =~ ^[0-9]+$ ]] || [ "$HEIGHT" -le 0 ]; then
        warn "Error: Invalid HEIGHT value '$HEIGHT'. Must be a positive number."
        error "invalid HEIGHT $HEIGHT"
    fi

    show "Blockchain HEIGHT is now          : $HEIGHT"

show ""
show "Rotate log file started at $(date +%H:%M:%S)"
    cd ${SRCDIR}

    # Validate source directory exists and is writable
    if [[ ! -w "$SRCDIR" ]]; then
        warn "Error: Source directory $SRCDIR is not writable."
        error "SRCDIR not writable $SRCDIR"
    fi

    # Move existing HEIGHT stamp files more safely
    log_debug "Moving HEIGHT stamp files to h$HEIGHT"
    find ${SRCDIR} -maxdepth 1 -name "h[0-9]*" -type f -exec mv -u {} ${SRCDIR}/h$HEIGHT \; 2>/dev/null || true

    # Rotate SERVICE-specific log files with validation
    if [ -f ${SRCDIR}/debug.log ]; then
        log_debug "Rotating Bitcoin debug log with HEIGHT $HEIGHT"
        mv -u ${SRCDIR}/debug.log ${SRCDIR}/debug_h$HEIGHT.log
    fi

    if [ -f ${SRCDIR}/bitmonero.log ]; then
        log_debug "Rotating Monero log with HEIGHT $HEIGHT"
        mv -u ${SRCDIR}/bitmonero.log ${SRCDIR}/bitmonero_h$HEIGHT.log
    fi

    if [ -f ${SRCDIR}/.chia/mainnet/log/debug.log ]; then
        log_debug "Rotating Chia debug log with HEIGHT $HEIGHT"
        mv -u ${SRCDIR}/.chia/mainnet/log/debug.log ${SRCDIR}/.chia/mainnet/log/debug_h$HEIGHT.log
    fi

    if [ -f ${SRCDIR}/db/bitcoin/LOG ]; then
        log_debug "Rotating Electrum log with HEIGHT $HEIGHT"
        mv -u ${SRCDIR}/db/bitcoin/LOG ${SRCDIR}/electrs_h$HEIGHT.log
    fi

    # Clean up old log files safely
    find ${SRCDIR}/db/bitcoin/LOG.old* -type f -exec rm {} \; 2>/dev/null || true
}


# --- snapshot
snapshot(){
show "Hint: Best time to take a snapshot is now."
# snapshot zfs DATASET
if [ "$IS_ZFS" ]; then
    show "Prepare DATASET $DATASET for a snapshot..."
    sync
    sleep 1
    snapname="script-$(date +%Y-%m-%d_%H-%M)"
    zfs snapshot -r ${DATASET}@${snapname}
    show "Snapshot '$snapname' was taken."
    log "snapshot $snapname taken"
fi
}


# --- main rsync job
backup_blockchain(){
cd $SRCDIR

show ""
show "Main task started at $(date +%H:%M:%S)"
log "start task backup pre"

# Ensure both timestamps are valid numbers
if [ -z "$srcsynctime" ] || [ -z "$destsynctime" ]; then
    warn "Error: One of the timestamps is missing or invalid."
    error "Exit"
fi

# Prevent overwrite if destination is newer (and no FORCE flag set)
if [ "$srcsynctime" -lt "$destsynctime" ] && [ ! "$FORCE" ]; then
    show "Destination is newer (and maybe higher) than the source."
    show "      Better use RESTORE. A FORCE will ignore this situation. End."
    log "! src-dest comparing triggers abort"
    exit 1
elif [ "$srcsynctime" -lt "$destsynctime" ] && [ "$FORCE" ]; then
    show "Destination is newer than the source."
    show "      Force will now overwrite it. This will downgrade the destination."
    log "src-dest downgrade FORCEd"
fi

    # machine deop9020m/hpms1
    [ "$SERVICE" == "bitcoind" ] && cp -u "anchors.dat banlist.json debug*.log fee_estimates.dat h[0-9]* memPOOL.dat peers.dat" ${DESTDIR}/
    [ "$SERVICE" == "bitcoind" ] && cp -u bitcoin.conf ${DESTDIR}/bitcoin.conf.$HOSTNAME
    [ "$SERVICE" == "bitcoind" ] && cp -u settings.json ${DESTDIR}/settings.json.$HOSTNAME
    [ "$SERVICE" == "bitcoind" ] && { folder[1]="blocks"; folder[2]="chainstate"; }
    [ "$SERVICE" == "bitcoind" ] && [ -f "${SRCDIR}/indexes/coinstats/db/CURRENT" ] && { folder[3]="indexes"; } || { folder[3]="indexes/blockfilter"; folder[4]="indexes/txindex"; }

    # machine hpms1
    [ "$SERVICE" == "monerod" ] && cp -u "bitmonero*.log h[0-9]* p2pstate.* rpc_ssl.*" ${DESTDIR}/
    [ "$SERVICE" == "monerod" ] && folder[1]="lmdb"
    [ "$SERVICE" == "chia" ] && { folder[1]=".chia"; folder[2]=".chia_keys"; folder[3]="plots"; }

i=1
while [ "${folder[i]}" != "" ]; do
    show "------------------------------------------------------------"
    show "Start backup job: $SERVICE/${folder[i]}"
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
show "------------------------------------------------------------"
log "end task backup main"
}


# --- postbackup tasks, restart SERVICE
postbackup(){
if [[ "$RESTORE" == false ]]; then
    chown -R apps:apps ${SRCDIR}
    show ""

    # Try to restart SERVICE using TrueNAS API
    if command -v midclt >/dev/null 2>&1; then
        show "Attempting to restart $SERVICE via TrueNAS API..."
        case "$SERVICE" in
            bitcoind)
                release_names=("${SERVICE}-knots" "bitcoin-knots" "bitcoind" "bitcoin")
                for release_name in "${release_names[@]}"; do
                    if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                        show "Found release: $release_name, restarting..."
                        if midclt call chart.release.scale "$release_name" '{"replica_count":1}' 2>/dev/null; then
                            show "Service $release_name scaling up via API."
                            log "$release_name restarted via API"
                            break
                        fi
                    fi
                done
                ;;
            monerod)
                release_names=("${SERVICE}" "monero" "monerod-knots")
                for release_name in "${release_names[@]}"; do
                    if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                        show "Found release: $release_name, restarting..."
                        if midclt call chart.release.scale "$release_name" '{"replica_count":1}' 2>/dev/null; then
                            show "Service $release_name scaling up via API."
                            log "$release_name restarted via API"
                            break
                        fi
                    fi
                done
                ;;
            chia)
                release_names=("${SERVICE}" "chia-blockchain" "chia-mainnet")
                for release_name in "${release_names[@]}"; do
                    if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                        show "Found release: $release_name, restarting..."
                        if midclt call chart.release.scale "$release_name" '{"replica_count":1}' 2>/dev/null; then
                            show "Service $release_name scaling up via API."
                            log "$release_name restarted via API"
                            break
                        fi
                    fi
                done
                ;;
        esac
    else
        show "midclt command not found, please restart $SERVICE manually"
    fi
else
    chown -R apps ${DESTDIR}
        # no SERVICE start after RESTORE
    show "Restore task finished. Check the result in ${DESTDIR}."
    show "Service $SERVICE will not automatically restarted."
fi

show "Script ended at $(date +%H:%M:%S)"
show "End."
show "------------------------------------------------------------"
log "script end"
}


# --- main logic

# not args given
[ $# -eq 0 ] && { show "Arguments needed: btc|xmr|xch|electrs|memPOOL|<SERVICEname> <HEIGHT>|all|RESTORE|VERBOSE|debug|FORCE|mount|umount"; exit 1; }

# Enhanced argument parsing with getopts
usage() {
    show "Usage: $0 [OPTIONS] [COMMAND] [ARGS]"
    show ""
    show "COMMANDS:"
    show "  btc|xmr|xch              Backup specific blockchain"
    show "  bitcoind|monerod|chia  Backup specific SERVICE"
    show "  RESTORE                   Restore blockchain data"
    show "  mount                     Mount backup destination"
    show "  umount                    Unmount backup destination"
    show "  full|--full              Backup all configured SERVICEs"
    show ""
    show "OPTIONS:"
    show "  -bh, --HEIGHT N         Set blockchain HEIGHT (numeric)"
    show "  -f, --FORCE              Force operation (bypass safety checks)"
    show "  -v, --VERBOSE            Enable VERBOSE output"
    show "  -x, --debug              Enable shell debugging"
    show "      --usb                 Use USB device instead of network"
    show "      --SERVICE SERVICE     Target specific SERVICE"
    show "      --host HOSTNAME      Target specific host (for --full)"
    show "  -h, --help               Show this help message"
    show ""
    show "EXAMPLES:"
    show "  $0 btc -bh 936125         # Backup Bitcoin at HEIGHT 936125"
    show "  $0 --SERVICE monerod -v     # Backup Monero with VERBOSE output"
    show "  $0 RESTORE --FORCE         # Force RESTORE operation"
    show "  $0 --full --host hpms1    # Backup all SERVICEs on hpms1"
    show ""
}

# Parse arguments with proper getopts-style parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        # Commands (no arguments)
        btc|xmr|xch)
            [[ -n "$TARGET_SERVICE" ]] && { error "Multiple blockchain types specified"; }
            TARGET_SERVICE="$1"
            case "$1" in
                btc) SERVICE="bitcoind" ;;
                xmr) SERVICE="monerod" ;;
                xch) SERVICE="chia" ;;
            esac
            shift
            ;;
        bitcoind|monerod|chia|electrs|memPOOL)
            [[ -n "$TARGET_SERVICE" ]] && { error "Multiple SERVICEs specified"; }
            TARGET_SERVICE="$1"
            SERVICE="$1"
            shift
            ;;
        RESTORE)
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
        --usb)
            USE_USB=true
            shift
            ;;
        # Options (require arguments)
        -bh|--HEIGHT)
            [[ -z "${2:-}" ]] && { error "--HEIGHT requires a value"; }
            HEIGHT="$2"
            shift 2
            ;;
        --SERVICE)
            [[ -z "${2:-}" ]] && { error "--SERVICE requires a value"; }
            SERVICE="$2"
            TARGET_SERVICE="$2"
            shift 2
            ;;
        --host)
            [[ -z "${2:-}" ]] && { error "--host requires a value"; }
            TARGET_HOST="$2"
            shift 2
            ;;
        # Boolean flags
        -f|--FORCE)
            FORCE=true
            shift
            ;;
        -v|--VERBOSE)
            VERBOSE=true
            log "VERBOSE now enabled"
            shift
            ;;
        -x|--debug)
            set -x
            shift
            ;;
        # Aliases and special cases
        full|-a|--full)
            full_mode=true
            shift
            ;;
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
            if [[ -z "$TARGET_SERVICE" ]] && [[ "$1" =~ ^(btc|xmr|xch|bitcoind|monerod|chia)$ ]]; then
                TARGET_SERVICE="$1"
                case "$1" in
                    btc) SERVICE="bitcoind" ;;
                    xmr) SERVICE="monerod" ;;
                    xch) SERVICE="chia" ;;
                    *) SERVICE="$1" ;;
                esac
                shift
            elif [[ "$1" =~ ^[0-9]+$ ]]; then
                HEIGHT="$1"
                shift
            elif [[ "$1" == "FORCE" ]]; then
                FORCE=true
                shift
            elif [[ "$1" == "VERBOSE" ]]; then
                VERBOSE=true
                show "VERBOSE now enabled"
                shift
            elif [[ "$1" == "usb" ]]; then
                USE_USB=true
                shift
            else
                warn "Error: Unknown option '$1'"
                usage
                exit 1
            fi
            ;;
    esac
done

# Validate and execute based on parsed arguments
if [[ -n "$SERVICE" ]]; then
    if [[ "$HEIGHT" -gt 0 ]]; then
        validate_HEIGHT "$HEIGHT" "$SERVICE" || exit 1
    fi
    [[ "$USE_USB" == true ]] && NASMOUNT=/mnt/usb/$nasshare
    [[ "$VERBOSE" == true ]] && show "SERVICE: $SERVICE, HEIGHT: $HEIGHT"
    prepare
    prestop
    prebackup
    snapshot
    backup_blockchain
    postbackup
elif [[ "$RESTORE" == true ]]; then
    [[ "$FORCE" != true ]] && show "Task ignored. Force not given. Exit." && exit 1
    show "------------------------------------------------------------"
    show "RESTORE: Attention, the direction Source <-> Destination is now changed."
    log "direction is RESTORE"
    prepare
    prestop
    backup_blockchain
    postbackup
fi

# --- full mode implementation
backup_all_SERVICEs() {
    show "=== BACKUP ALL CONFIGURED SERVICES ==="

    # Get all available SERVICE configurations
    local all_SERVICEs=()
    local hostname_target="${TARGET_HOST:-$(hostname -s)}"

    for config_key in "${!SERVICE_CONFIGS[@]}"; do
        # Extract hostname from config key (hostname_SERVICE)
        local config_host="${config_key%_*}"
        if [[ "$config_host" == "$hostname_target" ]]; then
            local service_config="${SERVICE_CONFIGS[$config_key]}"
            IFS=':' read -r svc_name POOL_name <<< "$SERVICE_config"
            all_SERVICEs+=("$svc_name:$POOL_name")
        fi
    done

    if [[ ${#all_SERVICEs[@]} -eq 0 ]]; then
        show "No SERVICEs configured for host: $hostname_target"
        exit 1
    fi

    show "Found SERVICEs to backup:"
    for SERVICE_entry in "${all_SERVICEs[@]}"; do
        IFS=':' read -r svc_name POOL_name <<< "$SERVICE_entry"
        show "  - $svc_name (POOL: $POOL_name)"
    done

    show "------------------------------------------------------------"
    show "Starting full backup of all SERVICEs..."

    # Backup each SERVICE
    for SERVICE_entry in "${all_SERVICEs[@]}"; do
        IFS=':' read -r svc_name POOL_name <<< "$SERVICE_entry"

        show ""
        show "=== Backing up SERVICE: $svc_name ==="

        # Set global variables for this SERVICE
        SERVICE="$svc_name"
        POOL="$POOL_name"
        DATASET="$POOL/blockchain"
        IS_ZFS=true

        # Reset HEIGHT for each SERVICE
        HEIGHT=0

        # Set paths for this SERVICE
        NASMOUNT=/mnt/$nashostname/$nasshare
        SRCDIR=/mnt/$DATASET/$SERVICE
        DESTDIR=$NASMOUNT/$SERVICE
        [[ "$RESTORE" == true ]] && SRCDIR=/mnt/$DATASET/$SERVICE
        [[ "$USE_USB" == true ]] && DESTDIR=/mnt/usb/$nasshare/$SERVICE

        # Set rsync options
        if [[ "$RESTORE" == true ]]; then
            RSYNC_OPTS="${RSYNC_CONFIGS[RESTORE]}"
        elif [[ -n "${RSYNC_CONFIGS[$SERVICE]:-}" ]]; then
            RSYNC_OPTS="${RSYNC_CONFIGS[$SERVICE]}"
        else
            RSYNC_OPTS="-avz -P --update --stats --delete --info=progress2"
        fi

        # Run backup workflow for this SERVICE
        prestop
        prebackup
        snapshot
        backup_blockchain_single
        postbackup

        show "Service $svc_name backup completed."
        show "------------------------------------------------------------"
    done

    show "=== ALL SERVICES BACKUP COMPLETED ==="
}

# Single SERVICE backup function (extracted from backup_blockchain)
backup_blockchain_single() {
    # This is the original backup_blockchain logic for single SERVICE
    cd $SRCDIR

show ""
show "Main task started at $(date +%H:%M:%S)"
log "start task backup pre"

# Ensure both timestamps are valid numbers
if [ -z "$srcsynctime" ] || [ -z "$destsynctime" ]; then
    warn "Error: One of the timestamps is missing or invalid."
    error "Exit"
fi

# Prevent overwrite if destination is newer (and no FORCE flag set)
if [ "$srcsynctime" -lt "$destsynctime" ] && [ ! "$FORCE" ]; then
    show "Destination is newer (and maybe higher) than the source."
    show "      Better use RESTORE. A FORCE will ignore this situation. End."
    log "! src-dest comparing triggers abort"
    exit 1
elif [ "$srcsynctime" -lt "$destsynctime" ] && [ "$FORCE" ]; then
    show "Destination is newer than the source."
    show "      Force will now overwrite it. This will downgrade the destination."
    log "src-dest downgrade FORCEd"
fi

    # Service-specific file copying and folder setup
    if [ "$SERVICE" == "bitcoind" ]; then
        cp -u "anchors.dat banlist.json debug*.log fee_estimates.dat h[0-9]* memPOOL.dat peers.dat" ${DESTDIR}/
        cp -u bitcoin.conf ${DESTDIR}/bitcoin.conf.$HOSTNAME
        cp -u settings.json ${DESTDIR}/settings.json.$HOSTNAME
        folder[1]="blocks"; folder[2]="chainstate"
        [ -f "${SRCDIR}/indexes/coinstats/db/CURRENT" ] && folder[3]="indexes" || { folder[3]="indexes/blockfilter"; folder[4]="indexes/txindex"; }
    elif [ "$SERVICE" == "monerod" ]; then
        cp -u "bitmonero*.log h[0-9]* p2pstate.* rpc_ssl.*" ${DESTDIR}/
        folder[1]="lmdb"
    elif [ "$SERVICE" == "chia" ]; then
        folder[1]=".chia"; folder[2]=".chia_keys"; folder[3]="plots"
    fi

i=1
while [ "${folder[i]}" != "" ]; do
    show "------------------------------------------------------------"
    show "Start backup job: $SERVICE/${folder[i]}"
    log "start task backup main"
    ionice -c 2 \
    rsync \
        ${RSYNC_OPTS} \
        --exclude '.nobakup' \
        ${SRCDIR}/${folder[i]}/ ${DESTDIR}/${folder[i]}/
    [ $? -ne 0 ] && warn "Error: During backup ${DESTDIR}/${folder[i]}." && vlog "task backup ${folder[i]} fail"
    sync
    ((i++))
done
show "------------------------------------------------------------"
log "end task backup main"
}

# --- main execution logic
if [[ "$full_mode" == true ]]; then
    backup_all_SERVICEs
else
    # Single SERVICE mode
    prepare
    prestop
    prebackup
    snapshot
    backup_blockchain_single
    postbackup
fi

# --- main logic end
exit

# ------------------------------------------------------------------------
# todos
TODO: Add host/SERVICE mapping for gold/enterprise version, not for safe version

# ------------------------------------------------------------------------
# errors

