#!/bin/bash
set -euo pipefail
# ============================================================
# backup_blockchain_truenas-safe.sh
# Backup & restore script for blockchain on TrueNAS Scale (safe version)
#
# Supported services:
#   - bitcoind
#   - monerod
#   - chia
#   - electrs
#   - mempool
#
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="260212-safe"
# ============================================================

echo "-------------------------------------------------------------------------------"
echo "Backup blockchain and or services to NAS/USB (safe version)"

# --- config
LOGGER=/usr/bin/logger
nasuser=your_username
nashost=192.168.1.100
nashostname=cronas
nasshare=blockchain

# Load external configuration if available
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CONFIG_FILE="${SCRIPT_DIR}/backup_blockchain_truenas-safe.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# --- runtime defaults
today=$(date +%y%m%d)
now=$(date +%y%m%d%H%M%S)
nasmount=/mnt/$nashostname/$nasshare
service=""
restore=false
is_mounted=false
use_usb=false
force=false
verbose=false
debug=false
height=0
is_zfs=false
pool=""
dataset=""
srcdir=""
destdir=""
folder[1]="" folder[2]="" folder[3]="" folder[4]="" folder[5]=""
usbdev="/dev/sdf1"
rsync_opts="-avz -P --update --stats --delete --info=progress2"
full_mode=false
target_service=""
target_host=""

# Validate height input
validate_height() {
    local input_height="$1"
    local service_name="$2"

    case "$service_name" in
        bitcoind)
            # Bitcoin height should be 6-8 digits (current ~800k)
            if ! [[ "$input_height" =~ ^[0-9]{6,8}$ ]]; then
                log_error "Invalid Bitcoin height: $input_height (should be 6-8 digits)"
                return 1
            fi
            ;;
        monerod)
            # Monero height should be 6-7 digits (current ~3M)
            if ! [[ "$input_height" =~ ^[0-9]{6,7}$ ]]; then
                log_error "Invalid Monero height: $input_height (should be 6-7 digits)"
                return 1
            fi
            ;;
        chia)
            # Chia height can vary, use reasonable range
            if ! [[ "$input_height" =~ ^[0-9]{1,8}$ ]]; then
                log_error "Invalid Chia height: $input_height (should be 1-8 digits)"
                return 1
            fi
            ;;
        *)
            # undefined case, exit with error
            echo "Error: Invalid argument '$1'"
            echo "Usage: $0 btc|xmr|xch|electrs|<servicename> <height>|config|all|restore|verbose|force|mount|umount"
            exit 1
        ;;
    esac

    log_debug "Validated height: $input_height for service: $service_name"
    return 0
}

# --- logger
log_info() { echo "$(date +'%Y-%m-%d %H:%M:%S') [INFO] $*"; }
log_warn() { echo "$(date +'%Y-%m-%d %H:%M:%S') [WARN] $*"; }
log_error() { echo "$(date +'%Y-%m-%d %H:%M:%S') [ERROR] $*" >&2; }
log_debug() { [[ "${verbose:-false}" == true ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') [DEBUG] $*"; }
log() { log_info "$1"; }


# --- mount destination
mount_dest(){
[ ! -d "$nasmount" ] && mkdir -p $nasmount
if [[ "$use_usb" == true ]]; then
    mount_usb
else
    # mount nas share
    mount | grep $nasmount >/dev/null
    [ $? -eq 0 ] || mount -t cifs -o user=$nasuser //$nashost/$nasshare $nasmount
    sleep 2
    [ -f "$nasmount/$nashostname.dummy" ] && [ -f "$nasmount/dir.dummy" ] && echo "Network share $nasmount is mounted and valid backup storage."
        if [ ! -w "$nasmount/" ]; then
            echo "[ ! ] Error: Destination $nasmount on //$nashost/$nasshare is NOT writable! Exit."
            log "$(date +%y%m%d%H%M%S) ! share $nasmount write permissions deny"
            destdir=/dev/null
            exit 127
        else
            is_mounted=true
            log "$(date +%y%m%d%H%M%S) share $nasmount mounted, validated"
        fi
fi
}


# --- mount usb device
mount_usb(){
    # nasmount=/mnt/usb/$nasshare # was set before
    [ ! -d "/mnt/usb" ] && mkdir -p /mnt/usb
    mount | grep /mnt/usb >/dev/null
    [ $? -eq 0 ] || mount $usbdev /mnt/usb
    sleep 2
    [ ! -f "$nasmount/usb.dummy" ] && { echo "[ ! ] Error: Mounted disk is not valid and or not prepared as backup storage! Exit."; exit 127; }
        if [ ! -w "$nasmount/" ]; then
            echo "[ ! ] Error: Disk $nasmount is NOT writable! Exit."
            log "$(date +%y%m%d%H%M%S) ! usb $nasmount write permissions deny"
            destdir=/dev/null
            exit 127
        fi
    is_mounted=true
    echo "USB disk is (now) mounted and valid backup storage."
    log "$(date +%y%m%d%H%M%S) usb $nasmount mounted, valid"
}


# --- unmount destination
unmount_dest(){
        sync
        df -h | grep $nasshare
        mount | grep $nasmount >/dev/null
        [ $? -eq 0 ] && umount $nasmount || is_mounted=false
}


# --- evaluate environment
prepare(){
echo "Script started at $(date +%H:%M:%S)"
log "$(date +%y%m%d%H%M%S) script started"

# host|arg|service|pool|splitted
#MAP="
#deop9020m|btc|bitcoind|tank-deop9020m|false
#hpms1|btc|bitcoind|ssd|true
#hpms1|xmr|monerod|ssd|true
#hpms1|xch|chia|ssd|true
#"

# Enhanced prepare function for single service or full mode
prepare_single_service() {
    local blockchain_type="${1:-$target_service}"
    local hostname_override="${target_host:-$(hostname -s)}"
    
    # Map blockchain type to service if needed
    case "$blockchain_type" in
        btc) service="bitcoind" ;;
        xmr) service="monerod" ;;
        xch) service="chia" ;;
        *) service="$blockchain_type" ;;
    esac
    
    local host_service_key="${hostname_override}_${blockchain_type}"
    if [[ -n "${SERVICE_CONFIGS[$host_service_key]:-}" ]]; then
        IFS=':' read -r svc_name pool_name <<< "${SERVICE_CONFIGS[$host_service_key]}"
        is_zfs=true
        service="$svc_name"
        pool="$pool_name"
        log "$(date +%y%m%d%H%M%S) host:${hostname_override} service:$service"
    else
        echo "[ ! ] Error: Service $blockchain_type not configured for host $hostname_override. Exit."
        log "$(date +%y%m%d%H%M%S) ! wrong blockchain $service for this host (not in definition)"
        exit 1
    fi
    dataset=$pool/blockchain
}

prepare() {
echo "Script started at $(date +%H:%M:%S)"
log "$(date +%y%m%d%H%M%S) script started"

if [[ "$full_mode" == true ]]; then
    echo "=== FULL MODE: Backup all configured services ==="
    return
fi

prepare_single_service

# construct paths
    nasmount=/mnt/$nashostname/$nasshare # redefine share, recheck is new $nasshare mounted
    srcdir=/mnt/$dataset/$service
    destdir=$nasmount/$service
    [[ "$restore" == true ]] && srcdir=/mnt/$dataset/$service
# case to usb disk (case restore from network to usb not needed)
    [[ "$use_usb" == true ]] && destdir=/mnt/usb/$nasshare/$service

    # Use rsync options from config
    if [[ "$restore" == true ]]; then
        rsync_opts="${RSYNC_CONFIGS[restore]}"
    elif [[ -n "${RSYNC_CONFIGS[$service]:-}" ]]; then
        rsync_opts="${RSYNC_CONFIGS[$service]}"
    else
        rsync_opts="-avz -P --update --stats --delete --info=progress2"  # fallback
    fi

# output results
    echo "------------------------------------------------------------"
    echo "Identified blockchain is $service"
    log "$(date +%y%m%d%H%M%S) blockchain/service=$service"

    echo "Source path     : ${srcdir}"
    echo "Destination path: ${destdir}"
    echo "------------------------------------------------------------"
    log "$(date +%y%m%d%H%M%S) direction $srcdir > $destdir"

    read -r -p "Please check paths. (Autostart in 5 seconds will go to mount destination)" -t 5 -n 1 -s
mount_dest
}
    dataset=$pool/blockchain

# construct paths
    nasmount=/mnt/$nashostname/$nasshare # redefine share, recheck is the new $nasshare mounted
    srcdir=/mnt/$dataset/$service
    destdir=$nasmount/$service
    [[ "$restore" == true ]] && srcdir=/mnt/$dataset/$service
# case to usb disk (case restore from network to usb not needed)
    [[ "$use_usb" == true ]] && destdir=/mnt/usb/$nasshare/$service

    # Use rsync options from config
    if [[ "$restore" == true ]]; then
        rsync_opts="${RSYNC_CONFIGS[restore]}"
    elif [[ -n "${RSYNC_CONFIGS[$service]:-}" ]]; then
        rsync_opts="${RSYNC_CONFIGS[$service]}"
    else
        rsync_opts="-avz -P --update --stats --delete --info=progress2"  # fallback
    fi

# output results
    echo "------------------------------------------------------------"
    echo "Identified blockchain is $service"
    log "$(date +%y%m%d%H%M%S) blockchain/service=$service"

    echo "Source path     : ${srcdir}"
    echo "Destination path: ${destdir}"
    echo "------------------------------------------------------------"
    log "$(date +%y%m%d%H%M%S) direction $srcdir > $destdir"

    read -r -p "Please check paths. (Autostart in 5 seconds will go to mount destination)" -t 5 -n 1 -s
mount_dest
}


# --- pre-tasks, stop service
prestop(){
log "$(date +%y%m%d%H%M%S) try stop $service"

echo "Attempting to stop $service via TrueNAS API..."

# Try to stop service using TrueNAS API
if command -v midclt >/dev/null 2>&1; then
    case "$service" in
        bitcoind)
            # Try different naming conventions
            release_names=("${service}-knots" "bitcoin-knots" "bitcoind" "bitcoin")
            for release_name in "${release_names[@]}"; do
                if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                    echo "Found release: $release_name, stopping..."
                    if midclt call chart.release.scale "$release_name" '{"replica_count":0}' 2>/dev/null; then
                        echo "[ OK] Service $release_name scaling down via API."
                        log "$(date +%y%m%d%H%M%S) $release_name stopped via API"
                        break
                    fi
                fi
            done
            ;;
        monerod)
            release_names=("${service}" "monero" "monerod-knots")
            for release_name in "${release_names[@]}"; do
                if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                    echo "Found release: $release_name, stopping..."
                    if midclt call chart.release.scale "$release_name" '{"replica_count":0}' 2>/dev/null; then
                        echo "[ OK] Service $release_name scaling down via API."
                        log "$(date +%y%m%d%H%M%S) $release_name stopped via API"
                        break
                    fi
                fi
            done
            ;;
        chia)
            release_names=("${service}" "chia-blockchain" "chia-mainnet")
            for release_name in "${release_names[@]}"; do
                if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                    echo "Found release: $release_name, stopping..."
                    if midclt call chart.release.scale "$release_name" '{"replica_count":0}' 2>/dev/null; then
                        echo "[ OK] Service $release_name scaling down via API."
                        log "$(date +%y%m%d%H%M%S) $release_name stopped via API"
                        break
                    fi
                fi
            done
            ;;
    esac
else
    echo "[ ! ] midclt command not found, falling back to manual intervention"
fi

echo "Checking active service..."

    echo "The $service service shutdown and flushing cache takes long time."
    echo "Waiting for graceful shutdown..."

    # Wait for service to stop with timeout
    local timeout=300  # 5 minutes max wait
    local elapsed=0
    local check_interval=10

    while [ $elapsed -lt $timeout ]; do
        if [ -f "${srcdir}/$service.pid" ]; then
            echo "Wait for process $service to stop... (${elapsed}s elapsed)"
            sleep $check_interval
            ((elapsed += check_interval))
        else
            echo "Great, service is now down."
            break
        fi
    done

# --- service check, final verification
if [ -f "${srcdir}/$service.pid" ]; then
    echo "[ ! ] Warning: Service may still be running after $timeout seconds."
    echo "[ ! ] Please verify manually that ${service} is stopped before proceeding."
    read -r -p "Continue anyway? (y/N): " -t 30 confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "[ ! ] Aborting due to potentially running service."
        log "$(date +%y%m%d%H%M%S) ! abort: service still running"
        exit 1
    fi
else
    echo "[ OK ] Service $service is down."
fi

echo "------------------------------------------------------------"
}


latest_manifest() {
    # Take only the latest MANIFEST file
    ls -1t "$1"/chainstate/MANIFEST-* 2>/dev/null | head -n1
}

# --- compare src-dest times
compare() {
    if [ "$service" = "bitcoind" ]; then
        srcfile=$(latest_manifest "$srcdir")
        destfile=$(latest_manifest "$destdir")
    elif [ "$service" = "monerod" ]; then
        srcfile="$srcdir/lmdb/data.mdb"
        destfile="$destdir/lmdb/data.mdb"
    elif [ "$service" = "chia" ]; then
        srcfile="$srcdir/.chia/mainnet/db/blockchain_v2_mainnet.sqlite"
        destfile="$destdir/.chia/mainnet/db/blockchain_v2_mainnet.sqlite"
    fi

    srcsynctime=$(stat -c %Y "$srcfile")
    destsynctime=$(stat -c %Y "$destfile")

    echo "------------------------------------------------------------"
    echo "Remote backup : $(date -d "@$destsynctime")"
    echo "Local data    : $(date -d "@$srcsynctime")"
    if (( destsynctime > srcsynctime )); then
        echo "Attention: Remote backup is newer than local data."
    fi
    if [ "$destfile" -nt "$srcfile" ]; then
        return 1    # backup newer
    else
        return 0    # local newer or equal
    fi
}


# --- get blockchain height from logs
get_block_height() {
    local parsed_height=0

    case "$service" in
        bitcoind)
            if [ -f "${srcdir}/debug.log" ]; then
                # Parse height from UpdateTip line: height=936124
                local update_tip_line=$(tail -n20 "${srcdir}/debug.log" | grep UpdateTip | tail -1)
                if [[ "$update_tip_line" =~ height=([0-9]+) ]]; then
                    parsed_height="${BASH_REMATCH[1]}"
                    log_debug "Parsed Bitcoin height: $parsed_height from debug.log"
                fi
            fi
            ;;
        monerod)
            if [ -f "${srcdir}/bitmonero.log" ]; then
                # Parse height from Synced line: Synced 3495136/3608034
                local synced_line=$(tail -n20 "${srcdir}/bitmonero.log" | grep "Synced" | tail -1)
                if [[ "$synced_line" =~ Synced\ ([0-9]+)/[0-9]+ ]]; then
                    parsed_height="${BASH_REMATCH[1]}"
                    log_debug "Parsed Monero height: $parsed_height from bitmonero.log"
                fi
            fi
            ;;
        chia)
            # Chia height parsing - check multiple log locations
            local chia_log_files=(
                "${srcdir}/.chia/mainnet/log/debug.log"
                "${srcdir}/.chia/mainnet/log/wallet.log"
                "${srcdir}/log/debug.log"
            )

            for log_file in "${chia_log_files[@]}"; do
                if [ -f "$log_file" ]; then
                    # Try to parse height from various chia log patterns
                    local height_line=$(tail -n50 "$log_file" | grep -E "(height|Height|block|Block)" | tail -1)
                    if [[ "$height_line" =~ (height|Height)[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                        parsed_height="${BASH_REMATCH[2]}"
                        log_debug "Parsed Chia height: $parsed_height from $log_file"
                        break
                    elif [[ "$height_line" =~ (block|Block)[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
                        parsed_height="${BASH_REMATCH[2]}"
                        log_debug "Parsed Chia block height: $parsed_height from $log_file"
                        break
                    fi
                fi
            done
            ;;
        electrs)
            # electrs doesn't have direct height in logs, use bitcoind height if available
            if [ -f "${srcdir}/../bitcoind/debug.log" ]; then
                local update_tip_line=$(tail -n20 "${srcdir}/../bitcoind/debug.log" | grep UpdateTip | tail -1)
                if [[ "$update_tip_line" =~ height=([0-9]+) ]]; then
                    parsed_height="${BASH_REMATCH[1]}"
                    log_debug "Parsed electrs height: $parsed_height from bitcoind debug.log"
                fi
            fi
            ;;
    esac

    # Validate parsed height is numeric and greater than 0
    if [[ "$parsed_height" =~ ^[0-9]+$ ]] && [ "$parsed_height" -gt 0 ]; then
        echo "$parsed_height"
    else
        echo "0"
    fi
}

# --- pre-tasks, update stamps
prebackup(){
cd $srcdir

compare
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "Remote holds newer data. Prevent overwrite, stopping."
    exit 1
fi

    # Service-specific minimum reasonable heights
    local min_height=0
    case "$service" in
        bitcoind) min_height=700000 ;;   # Bitcoin ~800k, min ~700k
        monerod)  min_height=3000000 ;;  # Monero ~3.5M, min ~3M
        chia)     min_height=800000 ;;   # Chia ~834k, min ~800k
        electrs)   min_height=700000 ;;   # Electrs follows Bitcoin
        *)         min_height=100000 ;;   # Default fallback
    esac

    # Check if height needs to be set (either too low or zero)
    if [[ "$height" -lt "$min_height" ]]; then
        # Try to auto-detect height from logs
        local detected_height=$(get_block_height)
        if [[ "$detected_height" -gt 0 ]]; then
            echo "Detected blockchain height: $detected_height"
            echo "Minimum reasonable height for $service: $min_height"
            read -p "[ ? ] Use detected height? (Y/n): " confirm
            if [[ "$confirm" != "n" && "$confirm" != "N" ]]; then
                height="$detected_height"
            fi
        else
            # Show log snippets for manual reference
            echo "Height too low for $service (minimum: $min_height)"
            echo "Showing recent log entries for manual height setting:"
            # bitcoind
            [ -f ${srcdir}/debug.log ] && tail -n20 debug.log | grep UpdateTip
            # example line: 2026-02-11T23:43:57Z UpdateTip: new best=000000000000000000015ca4e4a3fa112840d412315e42c4e89ec22dfdcf158f height=936124 version=0x2478c000 log2_work=96.079058 tx=1308589657 date='2026-02-11T23:43:48Z' progress=1.000000 cache=5.1MiB(37068txo)

            # monerod
            [ -f ${srcdir}/bitmonero.log ] && tail -n20 bitmonero.log | grep Synced
            # example line: 2026-02-11 23:52:18.824	[P2P7]	INFO	global	src/cryptonote_protocol/cryptonote_protocol_handler.inl:1618	Synced 3495136/3608034 (96%, 112898 left, 1% of total synced, estimated 14.1 days left)

            # chia
            # no parsable height in log file
            #[ -f ${srcdir}/.chia/mainnet/log/debug.log ] && tail -n20 ${srcdir}/.chia/mainnet/log/debug.log | grep ...

            # electrs
            [ -f ${srcdir}/db/bitcoin/LOG ] && tail -n20 ${srcdir}/db/bitcoin/LOG
        fi

        # Enhanced height file listing with better pattern matching
        echo "Remote backuped heights found     : $(find ${destdir} -maxdepth 1 -name "h[0-9]*" 2>/dev/null | xargs -n 1 basename 2>/dev/null | sed -e 's/\..*$//' || echo "None")"
        echo "Local working height is           : $(find ${srcdir} -maxdepth 1 -name "h[0-9]*" 2>/dev/null | xargs -n 1 basename 2>/dev/null | sed -e 's/\..*$//' || echo "None")"
        echo "Current configured height          : $height"
        echo "Minimum reasonable height for $service: $min_height"
        echo "------------------------------------------------------------"
        read -p "[ ? ] Set new Blockchain height   : h" height
    fi

    # Validate height before proceeding
    if [[ ! "$height" =~ ^[0-9]+$ ]] || [ "$height" -le 0 ]; then
        echo "[ ! ] Error: Invalid height value '$height'. Must be a positive number."
        log "$(date +%y%m%d%H%M%S) ! invalid height $height"
        exit 1
    fi

    echo "Blockchain height is now          : $height"

echo ""
echo "Rotate log file started at $(date +%H:%M:%S)"
    cd ${srcdir}

    # Validate source directory exists and is writable
    if [[ ! -w "$srcdir" ]]; then
        echo "[ ! ] Error: Source directory $srcdir is not writable."
        log "$(date +%y%m%d%H%M%S) ! srcdir not writable $srcdir"
        exit 1
    fi

    # Move existing height stamp files more safely
    log_debug "Moving height stamp files to h$height"
    find ${srcdir} -maxdepth 1 -name "h[0-9]*" -type f -exec mv -u {} ${srcdir}/h$height \; 2>/dev/null || true

    # Rotate service-specific log files with validation
    if [ -f ${srcdir}/debug.log ]; then
        log_debug "Rotating Bitcoin debug log with height $height"
        mv -u ${srcdir}/debug.log ${srcdir}/debug_h$height.log
    fi

    if [ -f ${srcdir}/bitmonero.log ]; then
        log_debug "Rotating Monero log with height $height"
        mv -u ${srcdir}/bitmonero.log ${srcdir}/bitmonero_h$height.log
    fi

    if [ -f ${srcdir}/.chia/mainnet/log/debug.log ]; then
        log_debug "Rotating Chia debug log with height $height"
        mv -u ${srcdir}/.chia/mainnet/log/debug.log ${srcdir}/.chia/mainnet/log/debug_h$height.log
    fi

    if [ -f ${srcdir}/db/bitcoin/LOG ]; then
        log_debug "Rotating Electrum log with height $height"
        mv -u ${srcdir}/db/bitcoin/LOG ${srcdir}/electrs_h$height.log
    fi

    # Clean up old log files safely
    find ${srcdir}/db/bitcoin/LOG.old* -type f -exec rm {} \; 2>/dev/null || true
}


# --- snapshot
snapshot(){
echo "Hint: Best time to take a snapshot is now."
# snapshot zfs dataset
if [ "$is_zfs" ]; then
    echo "Prepare dataset $dataset for a snapshot..."
    sync
    sleep 1
    snapname="script-$(date +%Y-%m-%d_%H-%M)"
    zfs snapshot -r ${dataset}@${snapname}
    echo "[ OK] Snapshot '$snapname' was taken."
    log "$(date +%y%m%d%H%M%S) snapshot $snapname taken"
fi
}


# --- main rsync job
backup_blockchain(){
cd $srcdir

echo ""
echo "Main task started at $(date +%H:%M:%S)"
log "$(date +%y%m%d%H%M%S) start task backup pre"

# Ensure both timestamps are valid numbers
if [ -z "$srcsynctime" ] || [ -z "$destsynctime" ]; then
    echo "[ ! ] Error: One of the timestamps is missing or invalid."
    exit 1
fi

# Prevent overwrite if destination is newer (and no force flag set)
if [ "$srcsynctime" -lt "$destsynctime" ] && [ ! "$force" ]; then
    echo "[ ! ] Destination is newer (and maybe higher) than the source."
    echo "      Better use restore. A force will ignore this situation. End."
    log "$(date +%y%m%d%H%M%S) ! src-dest comparing triggers abort"
    exit 1
elif [ "$srcsynctime" -lt "$destsynctime" ] && [ "$force" ]; then
    echo "[ ! ] Destination is newer than the source."
    echo "      Force will now overwrite it. This will downgrade the destination."
    log "$(date +%y%m%d%H%M%S) src-dest downgrade forced"
fi

    # machine deop9020m/hpms1
    [ "$service" == "bitcoind" ] && cp -u "anchors.dat banlist.json debug*.log fee_estimates.dat h[0-9]* mempool.dat peers.dat" ${destdir}/
    [ "$service" == "bitcoind" ] && cp -u bitcoin.conf ${destdir}/bitcoin.conf.$HOSTNAME
    [ "$service" == "bitcoind" ] && cp -u settings.json ${destdir}/settings.json.$HOSTNAME
    [ "$service" == "bitcoind" ] && { folder[1]="blocks"; folder[2]="chainstate"; }
    [ "$service" == "bitcoind" ] && [ -f "${srcdir}/indexes/coinstats/db/CURRENT" ] && { folder[3]="indexes"; } || { folder[3]="indexes/blockfilter"; folder[4]="indexes/txindex"; }

    # machine hpms1
    [ "$service" == "monerod" ] && cp -u "bitmonero*.log h[0-9]* p2pstate.* rpc_ssl.*" ${destdir}/
    [ "$service" == "monerod" ] && folder[1]="lmdb"
    [ "$service" == "chia" ] && { folder[1]=".chia"; folder[2]=".chia_keys"; folder[3]="plots"; }

i=1
while [ "${folder[i]}" != "" ]; do
    echo "------------------------------------------------------------"
    echo "Start backup job: $service/${folder[i]}"
    log "$(date +%y%m%d%H%M%S) start task backup main"
    ionice -c 2 \
    rsync \
        ${rsync_opts} \
        --exclude '.nobakup' \
        ${srcdir}/${folder[i]}/ ${destdir}/${folder[i]}/
    [ $? -ne 0 ] && echo "[ ! ] Errors during backup ${destdir}/${folder[i]}." && log "$(date +%y%m%d%H%M%S) ! task backup ${folder[i]} fail"
    sync
    ((i++))
done
echo "------------------------------------------------------------"
log "$(date +%y%m%d%H%M%S) end task backup main"
}


# --- postbackup tasks, restart service
postbackup(){
if [[ "$restore" == false ]]; then
    chown -R apps:apps ${srcdir}
    echo ""

    # Try to restart service using TrueNAS API
    if command -v midclt >/dev/null 2>&1; then
        echo "Attempting to restart $service via TrueNAS API..."
        case "$service" in
            bitcoind)
                release_names=("${service}-knots" "bitcoin-knots" "bitcoind" "bitcoin")
                for release_name in "${release_names[@]}"; do
                    if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                        echo "Found release: $release_name, restarting..."
                        if midclt call chart.release.scale "$release_name" '{"replica_count":1}' 2>/dev/null; then
                            echo "[ OK] Service $release_name scaling up via API."
                            log "$(date +%y%m%d%H%M%S) $release_name restarted via API"
                            break
                        fi
                    fi
                done
                ;;
            monerod)
                release_names=("${service}" "monero" "monerod-knots")
                for release_name in "${release_names[@]}"; do
                    if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                        echo "Found release: $release_name, restarting..."
                        if midclt call chart.release.scale "$release_name" '{"replica_count":1}' 2>/dev/null; then
                            echo "[ OK] Service $release_name scaling up via API."
                            log "$(date +%y%m%d%H%M%S) $release_name restarted via API"
                            break
                        fi
                    fi
                done
                ;;
            chia)
                release_names=("${service}" "chia-blockchain" "chia-mainnet")
                for release_name in "${release_names[@]}"; do
                    if midclt call chart.release.query [["release_name", "=", "$release_name"]] 2>/dev/null | grep -q "$release_name"; then
                        echo "Found release: $release_name, restarting..."
                        if midclt call chart.release.scale "$release_name" '{"replica_count":1}' 2>/dev/null; then
                            echo "[ OK] Service $release_name scaling up via API."
                            log "$(date +%y%m%d%H%M%S) $release_name restarted via API"
                            break
                        fi
                    fi
                done
                ;;
        esac
    else
        echo "[ ! ] midclt command not found, please restart $service manually"
    fi
else
    chown -R apps ${destdir}
        # no service start after restore
    echo "Restore task finished. Check the result in ${destdir}."
    echo "Service $service will not automatically restarted."
fi

echo "Script ended at $(date +%H:%M:%S)"
echo "End."
echo "------------------------------------------------------------"
log "$(date +%y%m%d%H%M%S) script end"
}


# --- main logic

# not args given
[ $# -eq 0 ] && { echo "Arguments needed: btc|xmr|xch|electrs|<servicename> <height>|config|all|restore|verbose|debug|force|mount|umount"; exit 1; }

# Enhanced argument parsing with getopts
usage() {
    echo "Usage: $0 [OPTIONS] [COMMAND] [ARGS]"
    echo ""
    echo "COMMANDS:"
    echo "  btc|xmr|xch              Backup specific blockchain"
    echo "  bitcoind|monerod|chia  Backup specific service"
    echo "  restore                   Restore blockchain data"
    echo "  mount                     Mount backup destination"
    echo "  umount                    Unmount backup destination"
    echo "  full|--full              Backup all configured services"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --height N           Set blockchain height (numeric)"
    echo "  -f, --force              Force operation (bypass safety checks)"
    echo "  -v, --verbose            Enable verbose output"
    echo "  -x, --debug              Enable shell debugging"
    echo "      --usb                 Use USB device instead of network"
    echo "      --service SERVICE     Target specific service"
    echo "      --host HOSTNAME      Target specific host (for --full)"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 btc -h 936125           # Backup Bitcoin at height 936125"
    echo "  $0 --service monerod -v     # Backup Monero with verbose output"
    echo "  $0 restore --force         # Force restore operation"
    echo "  $0 --full --host hpms1    # Backup all services on hpms1"
    echo ""
}

# Parse arguments with proper getopts-style parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        # Commands (no arguments)
        btc|xmr|xch)
            [[ -n "$target_service" ]] && { echo "Error: Multiple blockchain types specified"; usage; exit 1; }
            target_service="$1"
            case "$1" in
                btc) service="bitcoind" ;;
                xmr) service="monerod" ;;
                xch) service="chia" ;;
            esac
            shift
            ;;
        bitcoind|monerod|chia|electrs|mempool)
            [[ -n "$target_service" ]] && { echo "Error: Multiple services specified"; usage; exit 1; }
            target_service="$1"
            service="$1"
            shift
            ;;
        restore)
            restore=true
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
        -h|--height)
            [[ -z "${2:-}" ]] && { echo "Error: --height requires a value"; usage; exit 1; }
            height="$2"
            shift 2
            ;;
        --service)
            [[ -z "${2:-}" ]] && { echo "Error: --service requires a value"; usage; exit 1; }
            service="$2"
            target_service="$2"
            shift 2
            ;;
        --host)
            [[ -z "${2:-}" ]] && { echo "Error: --host requires a value"; usage; exit 1; }
            target_host="$2"
            shift 2
            ;;
        --usb)
            use_usb=true
            shift
            ;;
        # Boolean flags
        -f|--force)
            force=true
            shift
            ;;
        -v|--verbose)
            verbose=true
            LOGGER=/usr/bin/logger
            log "$(date +%y%m%d%H%M%S) verbose now enabled"
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
            echo "$version"
            exit 0
            ;;
        # Legacy/positional argument support
        *)
            # Handle positional arguments for backward compatibility
            if [[ -z "$target_service" ]] && [[ "$1" =~ ^(btc|xmr|xch|bitcoind|monerod|chia)$ ]]; then
                target_service="$1"
                case "$1" in
                    btc) service="bitcoind" ;;
                    xmr) service="monerod" ;;
                    xch) service="chia" ;;
                    *) service="$1" ;;
                esac
                shift
            elif [[ "$1" =~ ^[0-9]+$ ]]; then
                height="$1"
                shift
            elif [[ "$1" == "force" ]]; then
                force=true
                shift
            elif [[ "$1" == "verbose" ]]; then
                verbose=true
                LOGGER=/usr/bin/logger
                log "$(date +%y%m%d%H%M%S) verbose now enabled"
                shift
            elif [[ "$1" == "usb" ]]; then
                use_usb=true
                shift
            else
                echo "Error: Unknown option '$1'"
                usage
                exit 1
            fi
            ;;
    esac
done

# Validate arguments if service was specified
if [[ -n "$service" ]]; then
    if [[ "$height" -gt 0 ]]; then
        validate_height "$height" "$service" || exit 1
    fi
fi

case "$1" in
        btc|bitcoind|xmr|monerod|xch|chia)
            # default case
            [ -z "$height" ] && height=0 # preset
            [ -n "$arg2" ] && height=$2 # todo check for numeric format
            [[ "$use_usb" == true ]] && nasmount=/mnt/usb/$nasshare
            [ "$verbose" ] && echo "verbose 1:$arg1 2:$arg2 3:$arg3 4:$arg4 s:$service h:$height"
            prepare
            prestop	# service stop
            prebackup
            snapshot
            backup_blockchain	# main task
            postbackup # service restart
            #unmount_dest
        ;;
        restore|--restore)
            [ ! "$force" ] && echo "[ ! ] Task ignored. Force not given. Exit." && exit 1
            echo "------------------------------------------------------------"
            echo "RESTORE: Attention, the direction Source <-> Destination is now changed."
            restore=true
            log "$(date +%y%m%d%H%M%S) direction is restore"
            prepare
            prestop
            backup_blockchain
            postbackup # service restart
            #unmount_dest
        ;;
        force|--force)
            force=true
            echo "[ i ] Force is set."
            log "$(date +%y%m%d%H%M%S) force is set"
        ;;
        verbose|--verbose)
            verbose=true
            LOGGER=/usr/bin/logger
            echo "[ i ] Debug is enabled."
            log "$(date +%y%m%d%H%M%S) verbose now enabled"
        ;;
            --debug|-x)
            set -x
        ;;
        mount)
            mount_dest
            ;;
        umount)
            unmount_dest
            ;;
        help|--help|-h)
            usage
            exit 0
            ;;
        ver|version|--version)
            echo "$version"
            exit 0
            ;;
        *)
            # undefined case, exit with error
            echo "Error: Invalid argument '$1'"
            usage
            exit 1
            ;;
    esac

# --- full mode implementation
backup_all_services() {
    echo "=== BACKUP ALL CONFIGURED SERVICES ==="
    
    # Get all available service configurations
    local all_services=()
    local hostname_target="${target_host:-$(hostname -s)}"
    
    for config_key in "${!SERVICE_CONFIGS[@]}"; do
        # Extract hostname from config key (hostname_service)
        local config_host="${config_key%_*}"
        if [[ "$config_host" == "$hostname_target" ]]; then
            local service_config="${SERVICE_CONFIGS[$config_key]}"
            IFS=':' read -r svc_name pool_name <<< "$service_config"
            all_services+=("$svc_name:$pool_name")
        fi
    done
    
    if [[ ${#all_services[@]} -eq 0 ]]; then
        echo "[ ! ] No services configured for host: $hostname_target"
        exit 1
    fi
    
    echo "Found services to backup:"
    for service_entry in "${all_services[@]}"; do
        IFS=':' read -r svc_name pool_name <<< "$service_entry"
        echo "  - $svc_name (pool: $pool_name)"
    done
    
    echo "------------------------------------------------------------"
    echo "Starting full backup of all services..."
    
    # Backup each service
    for service_entry in "${all_services[@]}"; do
        IFS=':' read -r svc_name pool_name <<< "$service_entry"
        
        echo ""
        echo "=== Backing up service: $svc_name ==="
        
        # Set global variables for this service
        service="$svc_name"
        pool="$pool_name"
        dataset="$pool/blockchain"
        is_zfs=true
        
        # Reset height for each service
        height=0
        
        # Set paths for this service
        nasmount=/mnt/$nashostname/$nasshare
        srcdir=/mnt/$dataset/$service
        destdir=$nasmount/$service
        [[ "$restore" == true ]] && srcdir=/mnt/$dataset/$service
        [[ "$use_usb" == true ]] && destdir=/mnt/usb/$nasshare/$service
        
        # Set rsync options
        if [[ "$restore" == true ]]; then
            rsync_opts="${RSYNC_CONFIGS[restore]}"
        elif [[ -n "${RSYNC_CONFIGS[$service]:-}" ]]; then
            rsync_opts="${RSYNC_CONFIGS[$service]}"
        else
            rsync_opts="-avz -P --update --stats --delete --info=progress2"
        fi
        
        # Run backup workflow for this service
        prestop
        prebackup
        snapshot
        backup_blockchain_single
        postbackup
        
        echo "[ OK] Service $svc_name backup completed."
        echo "------------------------------------------------------------"
    done
    
    echo "=== ALL SERVICES BACKUP COMPLETED ==="
}

# Single service backup function (extracted from backup_blockchain)
backup_blockchain_single() {
    # This is the original backup_blockchain logic for single service
    cd $srcdir

echo ""
echo "Main task started at $(date +%H:%M:%S)"
log "$(date +%y%m%d%H%M%S) start task backup pre"

# Ensure both timestamps are valid numbers
if [ -z "$srcsynctime" ] || [ -z "$destsynctime" ]; then
    echo "[ ! ] Error: One of the timestamps is missing or invalid."
    exit 1
fi

# Prevent overwrite if destination is newer (and no force flag set)
if [ "$srcsynctime" -lt "$destsynctime" ] && [ ! "$force" ]; then
    echo "[ ! ] Destination is newer (and maybe higher) than the source."
    echo "      Better use restore. A force will ignore this situation. End."
    log "$(date +%y%m%d%H%M%S) ! src-dest comparing triggers abort"
    exit 1
elif [ "$srcsynctime" -lt "$destsynctime" ] && [ "$force" ]; then
    echo "[ ! ] Destination is newer than the source."
    echo "      Force will now overwrite it. This will downgrade the destination."
    log "$(date +%y%m%d%H%M%S) src-dest downgrade forced"
fi

    # Service-specific file copying and folder setup
    if [ "$service" == "bitcoind" ]; then
        cp -u "anchors.dat banlist.json debug*.log fee_estimates.dat h[0-9]* mempool.dat peers.dat" ${destdir}/
        cp -u bitcoin.conf ${destdir}/bitcoin.conf.$HOSTNAME
        cp -u settings.json ${destdir}/settings.json.$HOSTNAME
        folder[1]="blocks"; folder[2]="chainstate"
        [ -f "${srcdir}/indexes/coinstats/db/CURRENT" ] && folder[3]="indexes" || { folder[3]="indexes/blockfilter"; folder[4]="indexes/txindex"; }
    elif [ "$service" == "monerod" ]; then
        cp -u "bitmonero*.log h[0-9]* p2pstate.* rpc_ssl.*" ${destdir}/
        folder[1]="lmdb"
    elif [ "$service" == "chia" ]; then
        folder[1]=".chia"; folder[2]=".chia_keys"; folder[3]="plots"
    fi

i=1
while [ "${folder[i]}" != "" ]; do
    echo "------------------------------------------------------------"
    echo "Start backup job: $service/${folder[i]}"
    log "$(date +%y%m%d%H%M%S) start task backup main"
    ionice -c 2 \
    rsync \
        ${rsync_opts} \
        --exclude '.nobakup' \
        ${srcdir}/${folder[i]}/ ${destdir}/${folder[i]}/
    [ $? -ne 0 ] && echo "[ ! ] Errors during backup ${destdir}/${folder[i]}." && log "$(date +%y%m%d%H%M%S) ! task backup ${folder[i]} fail"
    sync
    ((i++))
done
echo "------------------------------------------------------------"
log "$(date +%y%m%d%H%M%S) end task backup main"
}

# --- main execution logic
if [[ "$full_mode" == true ]]; then
    backup_all_services
else
    # Single service mode
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


# ------------------------------------------------------------------------
# errors
