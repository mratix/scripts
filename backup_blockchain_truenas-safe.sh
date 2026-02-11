#!/bin/bash
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
version="260211-safe"
# ============================================================

echo "-------------------------------------------------------------------------------"
echo "Backup blockchain and or services to NAS/USB (safe version)"
echo "version: $version"

# --- config
nasuser=rsync
nashost=192.168.178.20
nashostname=cronas
nasshare=blockchain

# --- runtime defaults
today=$(date +%y%m%d)
nasmount=/mnt/$nashostname/$nasshare
service=""
restore=false
is_mounted=false
use_usb=false
prune=false
force=false
debug=false
height=0
is_zfs=false
is_splitted=false
pool=""
dataset=""
srcdir=""
destdir=""
folder[1]="" folder[2]="" folder[3]="" folder[4]="" folder[5]="" # reset
usbdev="/dev/sdf1"
rsync_opts="-avz -P --update --stats --delete --info=progress2"

# --- logger
log(){ echo "$(date +%y%m%d% H%M%S) $1"; echo "$1"; }


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
    [ -f "$nasmount/$nashostname.dummy" ] && [ -f "$nasmount/dir.dummy" ] && log "Network share $nasmount is mounted and valid backup storage."
        if [ ! -w "$nasmount/" ]; then
            log "[ ! ] Error: Destination $nasmount on //$nashost/$nasshare is NOT writable! Exit."
            destdir=/dev/null
            exit 127
        else
            is_mounted=true
            log "share $nasmount mounted, validated"
        fi
fi
}


# --- mount usb device
mount_usb(){
    # nasmount=/mnt/usb/$nasshare # was set before
    [ ! -d "/mnt/usb" ] && mkdir -p /mnt/usb
    mount | grep /mnt/usb >/dev/null
    [ $? -eq 0 ] || mount $usbdev /mnt/usb
    sleep 1
    [ ! -f "$nasmount/usb.dummy" ] && { log "[ ! ] Error: Mounted disk is not valid and or not prepared as backup storage! Exit."; exit 1; }
        if [ ! -w "$nasmount/" ]; then
            log "[ ! ] Error: Disk $nasmount is NOT writable! Exit."
            destdir=/dev/null
            exit 1
        fi
    is_mounted=true
    log "USB disk is (now) mounted. A valid backup storage."
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
log "Script started"

# machine-dependent
if [ "$arg1" == "btc" ] && [ "$(hostname -s)" == "deop9020m" ]; then
    is_zfs=true
    service=bitcoind
    is_splitted=false
    pool="tank-deop9020m"
    log "host:deop9020m service:$service"
elif [ "$arg1" == "btc" ] && [ "$(hostname -s)" == "hpms1" ]; then
    is_zfs=true
    service=bitcoind
    is_splitted=true
    pool="ssd" # todo folder blocks is linked to pool tank
    log "host:hpms1 service=$service"
elif [ "$arg1" == "xmr" ] && [ "$(hostname -s)" == "hpms1" ]; then
    is_zfs=true
    service=monerod
    is_splitted=true
    pool="ssd" # folder lmdb is linked from pool tank
    log "host:hpms1 service=$service"
elif [ "$arg1" == "xch" ] && [ "$(hostname -s)" == "hpms1" ]; then
    is_zfs=true
    service=chia
    is_splitted=true
    pool="ssd" # folder plots is linked to pool tank
    log "host:hpms1 service=$service"
else
    log "[ ! ] Error: Blockchain on this machine not identified. Please define the service(name). Exit."
    exit 1
fi
    dataset=$pool/blockchain

# construct paths
    nasmount=/mnt/$nashostname/$nasshare # redefine share
    srcdir=/mnt/$dataset/$service
    destdir=$nasmount/$service
    [[ "$restore" == true ]] && srcdir=/mnt/$dataset/$service
# case to usb disk (case restore from network to usb not needed)
    [[ "$use_usb" == true ]] && destdir=/mnt/usb/$nasshare/$service
# pruned service
    [[ "$prune" == true ]] && destdir=${destdir}-prune

    [ "$service" == "bitcoind" ] && rsync_opts="-avihH -P --fsync --mkpath --stats --delete"
    [ "$service" == "monerod" ] && rsync_opts="-a -P --numeric-ids --delete --info=progress2 --no-compress"
    [[ "$restore" == true ]] && rsync_opts="-avz -P --append-verify --info=progress2"

# output results
    echo "------------------------------------------------------------"
    log "Identified blockchain is $service"
    log "Source path     : ${srcdir}"
    log "Destination path: ${destdir}"
    echo "------------------------------------------------------------"

    read -r -p "Please check the paths. (Autostart in 5s will go to mount destination)" -t 5 -n 1 -s
mount_dest
}


# --- pre-tasks, stop service
prestop(){
    log "Please ensure that the App is or going down."
    read -r -p "(Wait 15s, or press any key to continue immediately)" -t 15 -n 1 -s
    sync

if [ -f "${srcdir}/$service.pid" ]; then
    log "[ ! ] Attention: To ensure a clean start next time, you need to STOP the $service-App."
    while true; do
        [ -f "${srcdir}/$service.pid" ] && log "Wait for process $service to going down..." || { log "Great, service is now down."; break; }
        echo "loop"
        sleep 5
    done
fi

# --- service check, last (App hanging bug)
[ ! -f "${srcdir}/$service.pid" ] && log "[ OK ] Service $service is down." || { log "[ ! ] Shutdown incomplete - Process is still alive! Abort."; exit 1; }
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
    log "Remote backup: $(date -d "@$destsynctime")"
    log "Local data   : $(date -d "@$srcsynctime")"
    if (( destsynctime > srcsynctime )); then
        log "Attention, Remote backup is newer than local data."
    fi
    if [ "$destfile" -nt "$srcfile" ]; then
        return 1    # dest is newer
    else
        return 0    # local newer or equal
    fi
}


# --- pre-tasks, update stamps
prebackup(){
cd $srcdir

compare
rc=$?
if [ "$rc" -ne 0 ]; then
    log "Remote holds newer data. Prevent overwrite, stopping."
    exit 1
fi

if [[ "$height" -lt 111111 ]]; then
    # bitcoind
    [ -f ${srcdir}/debug.log ] && { tail -n30 debug.log | grep "UpdateTip"; }

    # monerod
    [ -f ${srcdir}/bitmonero.log ] && { tail -n30 bitmonero.log | grep Synced; }

    # chia
    [ -f ${srcdir}/.chia/mainnet/log/debug.log ] && { tail -n30 ${srcdir}/.chia/mainnet/log/debug.log; echo "Chia: no height in log file"; }

    # electrs
    [ -f ${srcdir}/db/bitcoin/LOG ] && { tail -n30 ${srcdir}/db/bitcoin/LOG; echo "Electrs: no height in log file, use height from bitcoind."; }

    log "Remote backuped heights found: $(ls ${destdir}/h* | xargs -n 1 basename | sed -e 's/\..*$//')"
    log "Local data height is         : $(ls ${srcdir}/h* | xargs -n 1 basename | sed -e 's/\..*$//')"
    echo "------------------------------------------------------------"
    read -p "[ ? ] Set new height: h" height
fi
    log "Blockchain height is now: $height"

echo ""
log "Rotating log file"
    cd ${srcdir}
    mv -u ${srcdir}/h* ${srcdir}/h$height
    [ -f ${srcdir}/debug.log ] && mv -u ${srcdir}/debug.log ${srcdir}/debug_h$height.log
    [ -f ${srcdir}/bitmonero.log ] && mv -u ${srcdir}/bitmonero.log ${srcdir}/bitmonero_h$height.log
    [ -f ${srcdir}/.chia/mainnet/log/debug.log ] && cp -u ${srcdir}/.chia/mainnet/log/debug.log ${srcdir}/.chia/mainnet/log/debug_h$height.log
    [ -f ${srcdir}/.chia/mainnet/log/debug.log ] && mv -u ${srcdir}/.chia/mainnet/log/debug.log ${srcdir}/chia/mainnet/log/debug_h$height.log
    [ -f ${srcdir}/db/bitcoin/LOG ] && mv -u ${srcdir}/electrs_h$height.log
    find ${srcdir}/db/bitcoin/LOG.old* -type f -exec rm {} \; # remove older
}


# --- snapshot, zfs dataset
snapshot(){
echo "Hint: Best time to take a snapshot is now."
if [ "$is_zfs" ]; then
    log "Prepare dataset $dataset for a snapshot..."
    sync
    sleep 1
    snapname="script-$(date +%Y-%m-%d_%H-%M)"
    zfs snapshot -r ${dataset}@${snapname}
    log "[ OK] Snapshot '$snapname' was taken."
fi
}


# --- main backup task
backup_blockchain(){
cd $srcdir

echo ""
log "Main backup task started"

# Ensure both timestamps are valid numbers
if [ -z "$srcsynctime" ] || [ -z "$destsynctime" ]; then
    log "[ ! ] Error: One of the files (timestamps) missing or invalid."
    exit 1
fi

# Prevent overwrite if destination is newer (and no force flag set)
if [ "$srcsynctime" -lt "$destsynctime" ] && [ ! "$force" ]; then
    log "[ ! ] Destination is newer (and maybe higher) than the source."
    log "      Better use restore. A force will ignore this situation. End."
    exit 1
elif [ "$srcsynctime" -lt "$destsynctime" ] && [ "$force" ]; then
    log "[ ! ] Destination is newer than the source."
    log "      Force will now overwrite it. This will downgrade the destination."
fi

    # config, machine specific
    echo "------------------------------------------------------------"
    log "Start backup job: configuration"
    [ "$service" == "bitcoind" ] && cp -u "anchors.dat banlist.json debug*.log fee_estimates.dat h* mempool.dat peers.dat" ${destdir}/
    [ "$service" == "bitcoind" ] && cp -u bitcoin.conf ${destdir}/bitcoin.conf.$HOSTNAME
    [ "$service" == "bitcoind" ] && cp -u settings.json ${destdir}/settings.json.$HOSTNAME

    # partial, include folder/subfolder
    [ "$service" == "bitcoind" ] && { folder[1]="blocks"; folder[2]="chainstate"; }
    # coinstats/coinstatsindex enabled
    [ "$service" == "bitcoind" ] && [ -f "${srcdir}/indexes/coinstatsindex/db/CURRENT" ] && { folder[3]="indexes"; } || { folder[3]="indexes/blockfilter"; folder[4]="indexes/txindex"; }
    [ "$service" == "monerod" ] && cp -u bitmonero*.log h* p2pstate.* rpc_ssl.* ${destdir}/
    [ "$service" == "monerod" ] && folder[1]="lmdb"
    [ "$service" == "chia" ] && { folder[1]=".chia"; folder[2]=".chia_keys"; folder[3]="plots"; }
    # include [ "$service" == "mempool" ]

# rsync run
i=1
while [ "${folder[i]}" != "" ]; do
    echo "------------------------------------------------------------"
    log "Start backup job: $service/${folder[i]}"
    ionice -c 2 \
    rsync \
        ${rsync_opts} \
        --exclude '.nobakup' \
        ${srcdir}/${folder[i]}/ ${destdir}/${folder[i]}/
    [ $? -ne 0 ] && log "[ ! ] Errors during rsync ${destdir}/${folder[i]}."
    sync
    # todo: retry one time on error
    ((i++))
done
echo "------------------------------------------------------------"
}


# --- postbackup tasks, restart service
postbackup(){
if [[ "$restore" == false ]]; then
    chown -R apps:apps ${srcdir}
    echo ""
else
    chown -R apps ${destdir}
    log "Restore task finished. Check the result in ${destdir}."
fi

log "Script end."
echo "------------------------------------------------------------"
}


# --- main logic

# not args given
[ $# -eq 0 ] && { echo "Arguments needed: btc|xmr|xch|electrs|mempool|<servicename> <height>|config|all|restore|verbose|debug|force|mount|umount"; exit 1; }

# parse arguments (not parameters)
if [[ -n $4 ]]; then arg4=$4; fi
if [[ -n $3 ]]; then arg3=$3; fi
if [[ -n $2 ]]; then arg2=$2; fi
if [[ -n $1 ]]; then arg1=$1; fi
# feed variables logic
[ "$arg1" == "force" ] || [ "$arg2" == "force" ] || [ "$arg3" == "force" ] && force=true
[ "$arg1" == "verbose" ] || [ "$arg2" == "verbose" ] || [ "$arg3" == "verbose" ] && verbose=true
[ "$arg1" == "btc" ] || [ "$arg2" == "btc" ] || [ "$arg3" == "btc" ] && service=bitcoind
[ "$arg1" == "xmr" ] || [ "$arg2" == "xmr" ] || [ "$arg3" == "xmr" ] && service=monerod
[ "$arg1" == "xch" ] || [ "$arg2" == "xch" ] || [ "$arg3" == "xch" ] && service=chia
# todo check plausibility: is $arg{1-3} a 6-7-digit number, then set it as $height
[ "$arg2" == "prune" ] || [ "$arg3" == "prune" ] && prune=true
[ "$arg2" == "usb" ] || [ "$arg3" == "usb" ] && use_usb=true

# --- execute part
case "$1" in
        btc|bitcoind|xmr|monerod|xch|chia)
            # default case
            [ -z "$height" ] && height=0 # preset
            [ -n "$arg2" ] && height=$2 # todo check for numeric format
            [[ "$use_usb" == true ]] && nasmount=/mnt/usb/$nasshare
            [ "$verbose" ] && log "1:$arg1 2:$arg2 3:$arg3 4:$arg4 s:$service h:$height"
            prepare
            prestop
            prebackup
            snapshot
            backup_blockchain	# main task
            postbackup
            #unmount_dest
        ;;
        restore|--restore)
            [ ! "$force" ] && log "[ ! ] Task ignored. Force not given. Exit." && exit 1
            echo "------------------------------------------------------------"
            echo "RESTORE: Attention, the direction Source <-> Destination is now changed."
            restore=true
            log "direction is restore"
            prepare
            prestop
            backup_blockchain
            postbackup
            #unmount_dest
        ;;
        force|--force)
            force=true
            echo "[ i ] Force is set."
            log "force is set"
        ;;
        verbose|--verbose)
            #set -x # debug
            verbose=true
            log "verbose now enabled"
        ;;
        all|-a|full|--full)
            force=false
            verbose=false
            restore=false
		    # todo loop over services
	        prepare
            backup_blockchain
            postbackup
            #unmount_dest
        ;;
        mount)
            mount_dest
        ;;
        umount)
            unmount_dest
        ;;
        help|--help)
            echo "Usage: $0 btc|xmr|xch|electrs|<servicename> <height>|config|all|restore|verbose|force|mount|umount"
            exit 1
        ;;
        ver|version|--version)
            echo $version
            exit 1
        ;;
        *)
            # undefinied case, try as service
            echo "Undefinied case. Try '$1' as service..."
            service=$1
            verbose=true
            #{ echo "Usage: $0 btc|xmr|xch|electrs|mempool|<servicename> <height>|config|all|restore|verbose|force|mount|umount"; exit 1; }
esac
# --- main logic end

exit
