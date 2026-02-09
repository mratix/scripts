#!/bin/bash
# backup blockchain to nas, truenas, zfs-datasets
version="260209-safe by Mr.AtiX"

echo "-------------------------------------------------------------------------------"
echo "Backup blockchain and or services to NAS"

# --- config
LOGGER=/usr/bin/logger
nasuser=rsync
nashost=192.168.178.20
nashostname=cronas
nasshare=blockchain

# --- runtime defaults
today=$(date +%y%m%d)
now=$(date +%y%m%d%H%M%S)
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
rsync_opts="-avz -P --update --stats --delete --info=progress2"


# --- mount destination
mount_dest(){
[ ! -d "$nasmount" ] && mkdir -p $nasmount
if [ "$use_usb" ]; then
    mount_usb
else
    # mount nas share
    mount | grep $nasmount >/dev/null
    [ $? -eq 0 ] || mount -t cifs -o user=$nasuser //$nashost/$nasshare $nasmount
    sleep 2
    [ -f "$nasmount/$nashostname.dummy" ] && [ -f "$nasmount/dir.dummy" ] && echo "Network share $nasmount is mounted and valid backup storage."
        if [ ! -w "$nasmount/" ]; then
            echo "[ ! ] Error: Destination $nasmount on //$nashost/$nasshare is NOT writable! Exit."
            $LOGGER "$(date +%y%m%d%H%M%S) ! share $nasmount write permissions deny"
            destdir=/dev/null
            exit 127
        else
            is_mounted=true
            $LOGGER "$(date +%y%m%d%H%M%S) share $nasmount mounted, validated"
        fi
fi
}


# --- mount usb drive
mount_usb(){
    # nasmount=/mnt/usb/$nasshare # has previous set
    [ ! -d "/mnt/usb" ] && mkdir -p /mnt/usb
    mount | grep /mnt/usb >/dev/null
    [ $? -eq 0 ] || mount /dev/sdf1 /mnt/usb
    sleep 2
    [ ! -f "$nasmount/usb.dummy" ] && { echo "[ ! ] Error: Mounted disk is not valid and or not prepared as backup storage! Exit."; exit 127; }
        if [ ! -w "$nasmount/" ]; then
            echo "[ ! ] Error: Disk $nasmount is NOT writable! Exit."
            $LOGGER "$(date +%y%m%d%H%M%S) ! usb $nasmount write permissions deny"
            destdir=/dev/null
            exit 127
        fi
    is_mounted=true
    echo "USB disk is (now) mounted and valid backup storage."
    $LOGGER "$(date +%y%m%d%H%M%S) usb $nasmount mounted, valid"
}


# --- unmount nas share
unmount_dest(){
        sync
        df -h | grep $nasshare
        mount | grep $nasmount >/dev/null
        [ $? -eq 0 ] && umount $nasmount || is_mounted=false
}


# --- evaluate environment
prepare(){
echo "Script started at $(date +%H:%M:%S)"
$LOGGER "$(date +%y%m%d%H%M%S) script started"

# evaluate machines
if [ "$arg1" == "btc" ] && [ "$(hostname -s)" == "deop9020m" ]; then
    is_zfs=true
    service=bitcoind
    is_splitted=false
    pool="tank-deop9020m"
    $LOGGER "$(date +%y%m%d%H%M%S) host:deop9020m service:$service"
elif [ "$arg1" == "btc" ] && [ "$(hostname -s)" == "hpms1" ]; then
    is_zfs=true
    service=bitcoind
    is_splitted=true
    pool="ssd" # todo folder blocks is linked to pool tank
    #pool="tank" # only passed when merged from pool ssd
    $LOGGER "$(date +%y%m%d%H%M%S) host:hpms1 service=$service"
elif [ "$arg1" == "xmr" ] && [ "$(hostname -s)" == "hpms1" ]; then
    is_zfs=true
    service=monerod
    is_splitted=true
    pool="ssd" # folder lmdb is linked from pool tank
    #pool="tank" # only passed when merged from pool ssd
    $LOGGER "$(date +%y%m%d%H%M%S) host:hpms1 service=$service"
else
    echo "[ ! ] Error: Blockchain on this machine not identified. Please define the service(name). Exit."
    $LOGGER "$(date +%y%m%d%H%M%S) ! wrong blockchain $service for this host (not in definition)"
    exit 1
fi
    dataset=$pool/blockchain

# construct paths
    nasmount=/mnt/$nashostname/$nasshare # redefine share, recheck is new $nasshare mounted
    srcdir=/mnt/$dataset/$service
    destdir=$nasmount/$service
    [[ "$restore" == true ]] && srcdir=/mnt/$dataset/$service
# case to usb disk (case restore from network to usb not needed)
    [[ "$use_usb" == true ]] && destdir=/mnt/usb/$nasshare/$service
# pruned service
    [[ "$prune" == true ]] && destdir=${destdir}-prune

# rsync options, attention for monerod: no -z, no --inplace, no --append
    [ "$service" == "bitcoind" ] && rsync_opts="-avihH -P --fsync --mkpath --stats --delete"
    #[ "$service" == "monerod" ] && rsync_opts="-a -P --numeric-ids --delete --info=progress2"
    [ "$service" == "monerod" ] && rsync_opts="-a -P --delete --info=progress2 --no-compress"
    [[ "$restore" == true ]] && rsync_opts="-avz -P --append-verify --info=progress2"

# output results
    echo "------------------------------------------------------------"
    echo "Identified blockchain is $service"
    $LOGGER "$(date +%y%m%d%H%M%S) blockchain/service=$service"

    echo "Source path     : ${srcdir}"
    echo "Destination path: ${destdir}"
    echo "------------------------------------------------------------"
    $LOGGER "$(date +%y%m%d%H%M%S) direction $srcdir > $destdir"

    read -r -p "Please check paths. (Autostart in 5 seconds will go to mount destination)" -t 5 -n 1 -s
mount_dest
}


# --- pre-tasks, stop service
prestop(){
$LOGGER "$(date +%y%m%d%H%M%S) try stop $service"
    [ "$service" == "bitcoind" ] && cli -c 'app chart_release scale release_name='\"${service}-knots\"\ 'scale_options={"replica_count": 0}'
# error: Namespace chart_release not found
    [ "$service" == "bitcoind" ] && midclt call chart.release.scale "${service}-knots" {"replica_count":0}
# error: Method does not exist

    [ "$service" == "monerod" ] && cli -c 'app chart_release scale release_name='\"${service}\"\ 'scale_options={"replica_count": 0}'
# error: Namespace chart_release not found
    [ "$service" == "monerod" ] && midclt call chart.release.scale '${service}' '{"replica_count":0}'
# error: Method does not exist

echo "Check active service..."
if [ "$service" == "monerod" ]; then
    # todo parse tail -f bitmonero.log
    # 2026-02-06 18:59:11.821	[SRV_MAIN]	INFO	global	src/daemon/protocol.h:79Cryptonote protocol stopped successfully
    echo "No way to check a living $service service."
    echo "Please ensure that the App is or going down."
    echo "The $service service shutdown and flushing cache takes long time."
    read -r -p "(Wait 20 seconds, or press any key to continue immediately)" -t 20 -n 1 -s
    sync
fi

if [ -f "${srcdir}/$service.pid" ]; then
    echo "[ ! ] Attention: To ensure a clean start next time, need to STOP the App."
    while true; do
        [ -f "${srcdir}/$service.pid" ] && echo "Wait for process $service to going down..." || { echo "Great, service is now down."; break; }
        echo "loop"
        sleep 5
    done
fi

# --- service check, last (app hanging bug)
[ ! -f "${srcdir}/$service.pid" ] && echo "[ OK ] Service $service is down." || { echo "[ ! ] Shutdown incomplete - Process is still alive! Exit."; exit 127; }
[ -f "${srcdir}/.cookie" ] && echo "       Cookie is present." || echo "       Cookie is gone."
[ -f "${srcdir}/anchors.dat" ] && echo "[ OK ] Safe anchors found." || echo "[ ! ] Safe anchors are lost in the deep."
echo "------------------------------------------------------------"
}


# --- compare src dest times, %y=readable, %Y=unix timestamp
compare(){
if [ "$service" == "bitcoind" ]; then
    srcsynctime=$(stat -c %Y ${srcdir}/chainstate/MANIFEST-*)
    destsynctime=$(stat -c %Y ${destdir}/chainstate/MANIFEST-*)
elif [ "$service" == "monerod" ]; then
    srcsynctime=$(stat -c %Y ${srcdir}/lmdb/data.mdb)
    destsynctime=$(stat -c %Y ${destdir}/lmdb/data.mdb)
fi
    echo "------------------------------------------------------------"
    echo "Last backup on remote is from     : $destsynctime unix time"
    echo "Last working on local is from     : $srcsynctime unix time"
}


# --- pre-tasks, update stamps
prebackup(){
cd $srcdir

if [ "$height" -lt 111111 ]; then
    # bitcoind
    [ -f ${srcdir}/debug.log ] && tail -n20 debug.log | grep UpdateTip
    # todo parse height from log

    # monerod
    [ -f ${srcdir}/bitmonero.log ] && tail -n20 bitmonero.log | grep Synced
    # todo parse height from log
    # Synced 3372528/3604263 (93%, 231735 left, 0% of total synced, estimated 5.9 days left)

    # electrs
    [ -f ${srcdir}/db/bitcoin/LOG ] && tail -n20 ${srcdir}/db/bitcoin/LOG
    # todo parse height from log

    compare
    echo "Remote backuped heights found     : $(ls -m ${destdir}/h* | sed -e 's/\..*$//')"
    echo "Local working height is           : $(ls -m ${srcdir}/h* | sed -e 's/\..*$//')"
    echo "------------------------------------------------------------"
    read -p "[ ? ] Set new Blockchain height   : h" height
fi
    echo "Blockchain height is now          : $height"

echo ""
echo "Rotate log file started at $(date +%H:%M:%S)"
    cd $srcdir
    mv -u ${srcdir}/h* ${srcdir}/h$height
    [ -f ${srcdir}/debug.log ] && mv -u debug.log debug_h$height.log
    [ -f ${srcdir}/bitmonero.log ] && mv -u bitmonero.log bitmonero_h$height.log
    [ -f ${srcdir}/db/bitcoin/LOG ] && mv -u ${srcdir}/electrs_h$height.log
    [ -f ${srcdir}/db/bitcoin/LOG.old* ] && rm ${srcdir}/db/bitcoin/LOG.old*
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
    $LOGGER "$(date +%y%m%d%H%M%S) snapshot $snapname taken"

    # replicate snapshot, send task to background
    #echo "Snapshot replication $snapname to hpms1 scheduled."
    #snapreparch="tank/backups/replica/$HOSTNAME/$nasshare/$service"
    # local or remote archive
    #[ "$(hostname -s)" == "hpms1" ] && snaprepcmd='"zfs receive $snapreparch"' || snaprepcmd='ssh hpms1 "zfs receive $snapreparch"'
    #$LOGGER "$(date +%y%m%d%H%M%S) snapshot send replica hpms1"
    # zfs send -I ${dataset}@previous ${dataset}@latest | ${snaprepcmd} &&
    # todo include recursive datasets
fi
}


# --- main rsync job
backup_blockchain(){
cd $srcdir

echo ""
echo "Main task started at $(date +%H:%M:%S)"
$LOGGER "$(date +%y%m%d%H%M%S) start task backup pre"

# prevent overwrite newer destination
if [ "$srcsynctime" -lt "$destsynctime" ] && [ ! "$force" ]; then
# error [: : integer expression expected
    echo "[ ! ] Destination is newer (and maybe higher) as the source."
    echo "      Better use restore. A force will ignore this situation. End."
    $LOGGER "$(date +%y%m%d%H%M%S) ! src-dest comparing triggers abort"
    exit 1
elif [ "$srcsynctime" -lt "$destsynctime" ] && [ "$force" ]; then
    echo "[ ! ] Destination is newer as the source."
    echo "      Force will now overwrite it. This will downgrade the destination."
    $LOGGER "$(date +%y%m%d%H%M%S) src-dest downgrade forced"
fi

    # machine deop9020m/hpms1
    [ "$service" == "bitcoind" ] && cp -u anchors.dat banlist.json debug*.log fee_estimates.dat h* mempool.dat peers.dat ${destdir}/
    [ "$service" == "bitcoind" ] && cp -u bitcoin.conf ${destdir}/bitcoin.conf.$HOSTNAME
    [ "$service" == "bitcoind" ] && cp -u settings.json ${destdir}/settings.json.$HOSTNAME
    [ "$service" == "bitcoind" ] && { folder[1]="blocks"; folder[2]="chainstate"; }
    [ "$service" == "bitcoind" ] && [ -f "${srcdir}/indexes/coinstats/db/CURRENT" ] && { folder[3]="indexes"; } || { folder[3]="indexes/blockfilter"; folder[4]="indexes/txindex"; }

    # machine hpms1
    [ "$service" == "monerod" ] && cp -u bitmonero*.log h* p2pstate.* rpc_ssl.* ${destdir}/
    [ "$service" == "monerod" ] && folder[1]="lmdb"

i=1
while [ "${folder[i]}" != "" ]; do
    echo "------------------------------------------------------------"
    echo "Start backup job: $service/${folder[i]}"
    $LOGGER "$(date +%y%m%d%H%M%S) start task backup main"
    ionice -c 2 \
    rsync \
        ${rsync_opts} \
        --exclude '.nobakup' \
        ${srcdir}/${folder[i]}/ ${destdir}/${folder[i]}/
    [ $? -ne 0 ] && echo "[ ! ] Errors during backup ${destdir}/${folder[i]}." && $LOGGER "$(date +%y%m%d%H%M%S) ! task backup ${folder[i]} fail"
    sync
    ((i++))
done
echo "------------------------------------------------------------"
$LOGGER "$(date +%y%m%d%H%M%S) end task backup main"
}


# --- postbackup tasks, restart service
postbackup(){
if [[ "$restore" == false ]]; then
    chown -R apps:apps ${srcdir}
    echo ""
    echo "Restart service $service..."
    [ "$service" == "bitcoind" ] && midclt call chart.release.scale '${service}-knots' '{"replica_count":1}'
#error: Method does not exist
    [ "$service" == "monerod" ] && midclt call chart.release.scale '${service}' '{"replica_count":1}'
#error: Method does not exist
else
    chown -R apps ${destdir}
        # no service start after restore
    echo "Restore task finished. Check the result in ${destdir}."
    echo "Service $service will not automaticaly restarted."
fi

echo "Script ended at $(date +%H:%M:%S)"
echo "End."
echo "------------------------------------------------------------"
$LOGGER "$(date +%y%m%d%H%M%S) script end"
}


# --- main logic

# not args given
[ $# -eq 0 ] && { echo "Arguments needed: btc|xmr|electrs|<servicename> <height>|config|all|restore|debug|force|mount|umount"; exit 1; }

# parse arguments (not parameters)
if [[ -n $4 ]]; then arg4=$4; fi
if [[ -n $3 ]]; then arg3=$3; fi
if [[ -n $2 ]]; then arg2=$2; fi
if [[ -n $1 ]]; then arg1=$1; fi
# feed variables logic
[ "$arg1" == "force" ] || [ "$arg2" == "force" ] || [ "$arg3" == "force" ] && force=true
[ "$arg1" == "debug" ] || [ "$arg2" == "debug" ] || [ "$arg3" == "debug" ] && debug=true
[ "$arg1" == "btc" ] || [ "$arg2" == "btc" ] || [ "$arg3" == "btc" ] && service=bitcoind
[ "$arg1" == "xmr" ] || [ "$arg2" == "xmr" ] || [ "$arg3" == "xmr" ] && service=monerod
# todo check plausibility: is $arg{1-3} a 6-digit number, then set it as $height for service=bitcoind
# todo check plausibility: is $arg{1-3} a 7-digit number, then set it as $height for service=monerod
[ "$arg2" == "prune" ] || [ "$arg3" == "prune" ] && prune=true
[ "$arg2" == "usb" ] || [ "$arg3" == "usb" ] && use_usb=true

case "$1" in
        btc|bitcoind|xmr|monerod)
            # default case
            [ -z "$height" ] && height=0 # preset
            [ -n "$arg2" ] && height=$2 # todo check for numeric format
            [[ "$use_usb" == true ]] && nasmount=/mnt/usb/$nasshare
            [ "$debug" ] && echo "debug 1:$arg1 2:$arg2 3:$arg3 4:$arg4 s:$service h:$height"
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
            $LOGGER "$(date +%y%m%d%H%M%S) direction is restore"
            prepare
            prestop
            backup_blockchain
            postbackup # service restart
            #unmount_dest
        ;;
        force|--force)
            force=true
            echo "[ i ] Force is set."
            $LOGGER "$(date +%y%m%d%H%M%S) force is set"
        ;;
        debug|--debug)
            debug=true
            LOGGER=/usr/bin/logger
	    set -x
            echo "[ i ] Debug is enabled."
            $LOGGER "$(date +%y%m%d%H%M%S) debug now enabled"
        ;;
        all|-a|full|--full)
            force=false
            debug=false
            restore=false
		# todo schleife loop services
	    prepare
            backup_blockchain
            postbackup # service restart
            #unmount_dest
        ;;
        mount)
            mount_dest
        ;;
        umount)
            unmount_dest
        ;;
        help|--help)
            echo "Usage: $0 btc|xmr|electrs|<servicename> <height>|config|all|restore|debug|force|mount|umount"
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
            debug=true
            #{ echo "Usage: $0 btc|xmr|electrs|<servicename> <height>|config|all|restore|debug|force|mount|umount"; exit 1; }
esac
# --- main logic end
exit

# ------------------------------------------------------------------------
# todos


# ------------------------------------------------------------------------
# errors
