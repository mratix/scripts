#!/bin/bash

# Script to backup MySQL databases and directories to a NAS server
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="250101, by Mr.AtiX"
# ============================================================

set -euo pipefail
IFS=$'\n\t' # Zeilenhandling

LOGGER=/usr/bin/logger
MAILCMD=/bin/mail
ADMIN_EMAIL="mratix@localhost"

NAS_USER=rsync
NAS_PASSWD=
NAS_HOST=192.168.178.20
NAS_HOSTNAME=cronas
NAS_SHARE=backups
NAS_MOUNTP=/mnt/$NAS_HOSTNAME/$NAS_SHARE

SQL_USER=rsync
SQL_PASSWD=
SQL_HOST="192.168.178.66"
SQL_HOSTNAME="crodebhassio"

sqlbakpath=${NAS_MOUNTP}/databases/mysql
sqllocalpath=$HOME/Dokumente/machines/${SQL_HOSTNAME}
destbakpath=${NAS_MOUNTP}/pools/rsync/$(hostname -s)
borgbakpath=${NAS_MOUNTP}/pools/borg/$(hostname -s)

SRCDIR1='/etc'
SRCDIR2='/var/www'
SRCDIR3='/root /home'
#SRCDIR3='/home'
#todo define here common garbage excludes

today=$(date +%Y%m%d)
time_format='%H%M'


# --- logger
show() { echo "$*"; }
log() { echo "$(date +'%Y-%m-%d %H:%M:%S') $*"; }
#vlog() { [[ "${VERBOSE:-false}" == true ]] && echo "$(date +'%Y-%m-%d %H:%M:%S') $*" >&2 || true; }
vlog() { $VERBOSE || return 0; log "> $*"; }
warn() { log "WARNING: $*"; }
error() { log "ERROR: $*" >&2; exit 1; }


# Backup file system, create tar-archive
backup_tar(){
        vlog "mybackup: task tar"
        [ ! -d ${destbakpath}/${today} ] && mkdir -p ${destbakpath}/${today}
	# task 1
        vlog "mybackup: task tar1"
        local destfile="${destbakpath}/${today}/rootfs-$(date +"%y%m%d%H%M").tar.gz"
        tar --exclude "*/proc/*" --exclude "*/dev/*" --exclude "*/cache/*" -zcvf ${destfile} ${SRCDIR1}
        [ $? -ne 0 ] && warn "Error: task tar1 $SRCDIR1"
	# task 2
        vlog "mybackup: task tar2"
        local destfile="${destbakpath}/${today}/www-$(date +"%y%m%d%H%M").tar.gz"
        tar --exclude "*/cache/*" -zcvf ${destfile} ${SRCDIR2}
        [ $? -ne 0 ] && warn "Error: task tar2 $SRCDIR2"
	# task 3
        vlog "mybackup: task tar3"
        local destfile="${destbakpath}/${today}/home-$(date +"%y%m%d%H%M").tar.gz"
        tar --exclude ".bash_history " --exclude "*/cache/*" --exclude '.cache/*' --exclude "*/crashes/*" --exclude '*/_*' --exclude '*/cronas?_*' --exclude "datareporting" --exclude "Musik" --exclude "Thumbnails" --exclude "Videos" -zcvf ${destfile} ${SRCDIR3}
        [ $? -ne 0 ] && warn "Error: task tar3 $SRCDIR3"
        vlog "mybackup: task tar Ended at $(date)"
}


# Backup file system with rsync
sync_data(){
    echo "Task not implemented, but included in task 'tar'."

    # daily merge task
	# sync          $HOME/scripts/      smb://$NAS_HOSTNAME/home/scripts/
	# upload,sync   $HOME/Dokumente/    smb://$NAS_HOSTNAME/data/documents/
	# mv            $HOME/Downloads/    smb://$NAS_HOSTNAME/public/downloads/
	# mv            $HOME/Musik/        smb://$NAS_HOSTNAME/home/music/
	# sync          $HOME/Videos/       smb://$NAS_HOSTNAME/home/videos/

}


# Backup windows file system with rsync
backup_windows(){
if [ $(hostname -s) == "hped800g2" ]; then
    vlog "mybackup: task windows"

WINSRC_MP="/mnt/localhost"
# dualboot, custom partition layout
WINSRC_P1="${WINSRC_MP}/sda1"
WINSRC_P3="${WINSRC_MP}/sda3"
WINSRC_P4="${WINSRC_MP}/sda4"
WINSRC_P7="${WINSRC_MP}/sda7"

[ ! -d ${WINSRC_P1} ] && sudo mkdir -p ${WINSRC_P1}
[ ! -d ${WINSRC_P3} ] && sudo mkdir -p ${WINSRC_P3}
[ ! -d ${WINSRC_P4} ] && sudo mkdir -p ${WINSRC_P4}
[ ! -d ${WINSRC_P7} ] && sudo mkdir -p ${WINSRC_P7}

sudo mount /dev/sda1 ${WINSRC_P1}
sudo mount /dev/sda3 ${WINSRC_P3}
sudo mount /dev/sda4 ${WINSRC_P4}
sudo mount /dev/sda7 ${WINSRC_P7}

[ ! -d ${destbakpath}/sda4_boot ] && mkdir -p ${destbakpath}/sda4_boot
    rsync -auv --delete --exclude=lost+found ${WINSRC_P4}/ ${destbakpath}/sda4_boot/
    [ $? -ne 0 ] && warn "Error: task windows sda4"

[ ! -d ${destbakpath}/sda1_efi ] && mkdir -p ${destbakpath}/sda1_efi
    rsync -auv ${WINSRC_P1}/ ${destbakpath}/sda1_efi/
    [ $? -ne 0 ] && warn "Error: task windows sda1"

#[ ! -d ${destbakpath}/sda2_msftres ] && mkdir -p ${destbakpath}/sda2_msftres
#    rsync -auv ${WINSRC_P2}/ ${destbakpath}/sda2_msftres/
#    [ $? -ne 0 ] && warn "Error: task windows sda2"

[ ! -d ${destbakpath}/sda7_diag ] && mkdir -p ${destbakpath}/sda7_diag
    rsync -auv ${WINSRC_P7}/ ${destbakpath}/sda7_diag/
    [ $? -ne 0 ] && warn "Error: task windows sda7"

[ ! -d ${destbakpath}/sda3_win10 ] && mkdir -p ${destbakpath}/sda3_win10
    rsync -rtuv \
    --exclude=Users \
    --exclude=node_modules --exclude=cache --exclude=temp --exclude=tmp --exclude=*Temp* --exclude=*Cache* --exclude=Logs --exclude='$Recycle.Bin' \
    --exclude=*.tmp --exclude=*.log --exclude=*.log.* --exclude=NTUSER.DAT \
    ${WINSRC_P3}/ ${destbakpath}/sda3_win10/
    [ $? -ne 0 ] &&warn "Error: task windows sda3"
    vlog "mybackup: task windows Ended at $(date)"

# Backup windows profiles
    vlog "mybackup: task winprofiles"
    NAS_MOUNTP=/mnt/$NAS_HOSTNAME/profiles
        mount_nas
    destbakpath=$NAS_MOUNTP
    if [ -d ${destbakpath}/Users/mratix/Desktop ]; then
        rsync -rtuv \
            --exclude=node_modules --exclude=cache --exclude=temp --exclude=tmp --exclude=*Temp* --exclude=*Cache* --exclude=Logs --exclude='$Recycle.Bin' \
            --exclude=*.tmp --exclude=*.log --exclude=*.log.* --exclude=NTUSER.DAT \
            ${WINSRC_P3}/Users/ ${destbakpath}/Users/
        [ $? -ne 0 ] && warn "Error: task windows profiles"
        vlog "mybackup: task winprofiles Ended at $(date)"
    else
        error "Share profiles not mounted or unwritable."
        vlog "mybackup: Backup Windows user profiles failed."
    fi

    sync && sudo umount /mnt/localhost/sda*
else
    vlog "mybackup: task windows The Partition layout is only defined for hped800g2. Abort."
fi
}


# Backup with Borg
backup_borg(){
        vlog "mybackup: task borg"
        # [ ! -d ${borgbakpath} ] && mkdir -p ${borgbakpath}
        export BORG_PASSCOMMAND="cat $HOME/.borg-passphrase" && sudo exec $HOME/scripts/borgbackup.sh
        [ $? -ne 0 ] && warn "Error: task borg"
        vlog "mybackup: Ended at $(date)"
}


# Backup blockchain
backup_blockchain(){
        vlog "mybackup: task blockchain"
        # [ ! -d ${borgbakpath} ] && mkdir -p ${borgbakpath}
        export BORG_PASSCOMMAND="cat $HOME/.borg" && sudo exec $HOME/scripts/backup_blockchain_umbrel.sh
        [ $? -ne 0 ] && warn "Error: task blockchain"
        vlog "mybackup: task blockchain Ended at $(date)"
}


# Backup websites
backup_www(){
NAS_USER=mratix
#NAS_USER=rsync # remount to become permissions on /volume2/storage/www/
# todo umstellen auf mount, or try sudo -u www-data <cmd>
if [ $(hostname -s) == "$SQL_HOSTNAME" ]; then
    rsync -avzsh --no-o --no-g --no-perms --omit-dir-times --delete-during \
    --exclude=.bin --exclude=sess_* \
    ${SRCDIR2}/html/ $NAS_USER@$NAS_HOST:/volume2/storage/www/html/
    [ $? -ne 0 ] && warn "Error: task www"
    vlog "mybackup: task www Ended at $(date)"
else
    vlog "mybackup: task www is only possible on $SQL_HOSTNAME."
fi
}


# Mount NAS share
mount_nas(){
        [ ! -d $NAS_MOUNTP ] && sudo mkdir -p $NAS_MOUNTP
        mount | grep $NAS_MOUNTP >/dev/null
        # [ $? -eq 0 ] || sudo mount -t cifs //$NAS_HOST/backups -o user=$NAS_USER $NAS_MOUNTP
        [ $? -eq 0 ] || sudo mount $NAS_MOUNTP
}


# Unmount NAS share
umount_nas(){
        sync
        mount | grep $NAS_MOUNTP >/dev/null
        [ $? -eq 0 ] && sudo umount $NAS_MOUNTP
}


# Backup mysql databases
backup_mysql(){
        vlog "mybackup: task mysqldump"
        local DBS="$(mysql -h $SQL_HOST -u $SQL_USER -p${SQL_PASSWD} -Bse 'show databases')"
        local db=""
        local linkname=""
        # [ ! -d $sqlbakpath/${today} ] && mkdir -p $sqlbakpath/${today}
        [ ! -d ${sqllocalpath} ] && mkdir -p ${sqllocalpath}
        for db in $DBS
        do
            # skip databases
            #[ "$db" == "homeassistant" ] && continue
            [ "$db" == "information_schema" ] && continue
            [ "$db" == "mysql" ] && continue
            [ "$db" == "performance_schema" ] && continue
            [ "$db" == "phpmyadmin" ] && continue
            [ "$db" == "sys" ] && continue
            [ "$db" == "zabbix" ] && continue
            #local FILE="${sqlbakpath}/${db}_$(date +"%y%m%d%H%M").gz"
            #mysqldump -h $SQL_HOST -u $SQL_USER -p${SQL_PASSWD} -B ${db} | gzip -9 > $FILE
	    mysqldump -h $SQL_HOST -u $SQL_USER -p${SQL_PASSWD} -B ${db} > /tmp/${db}.sql
		# 2>/var/log/mysqldump_error.log # rechte zum loggen fehlen
	    [ $? -ne 0 ] && warn "Error: task mysqldump"
	    # check the filesize (don't overwrite the last good with a empty file)
	    if [ -s /tmp/${db}.sql ] ; then
		cp -u /tmp/${db}.sql ${sqlbakpath}/${db}_$(date +"%y%m%d%H%M").sql
		mv -u /tmp/${db}.sql ${sqllocalpath}/$(date +%y%m%d)_${db}.sql
		# link the dump as new latest
		linkname="${sqllocalpath}/${db}_last.sql"
		[ -L $linkname ] && rm $linkname
		/bin/ln -s ${sqllocalpath}/$(date +%y%m%d)_${db}.sql $linkname
	    else
		warn "Error: dump does not exist or is zero size."
		rm /tmp/${db}.sql
	    fi
        done
        vlog "mybackup: task mysqldump Ended at $(date)"
}


# Backup mysql databases, all in one
backup_mysqlaio(){
        vlog "mybackup: task mysqlaio"
	local db=all_databases
	mysqldump -h $SQL_HOST -u $SQL_USER -p${SQL_PASSWD} --single-transaction --routines --triggers --all-databases > /tmp/${db}.sql
		# 2>/var/log/mysqldump_error.log # rechte zum loggen fehlen
        [ $? -ne 0 ] && warn "Error: task mysqlaio"
	# check the filesize (don't copy a empty file and destroy the last good one)
	if [ -s /tmp/${db}.sql ] ; then
	    [ ! -d ${sqlbakpath} ] && mkdir -p ${sqlbakpath}
		cp -u /tmp/${db}.sql ${sqlbakpath}/${db}_$(date +"%y%m%d%H%M").sql
		[ ! -d ${sqllocalpath} ] && mkdir -p ${sqllocalpath}
		mv -u /tmp/${db}.sql ${sqllocalpath}/$(date +%y%m%d)_${db}.sql
	else
		warn "Error: dump does not exist or is zero length."
		rm /tmp/${db}.sql
	fi
        vlog "mybackup: task mysqlaio Ended at $(date)"
}


# Wrapper, to call other functions
wrapper(){
        mount_nas   # call function mount nas share
        mysql	    # call function dump databases
        umount_nas  # call function unmount nas share
}


# Main script, logic starts here
case "$1" in
        blockchain)
            NAS_MOUNTP=/mnt/$NAS_HOSTNAME/blockchain
            mount_nas
            backup_blockchain
            umount_nas
        ;;
        mysql)
            mount_nas
            backup_mysql
    		backup_mysqlaio
    		umount_nas
        ;;
        tar)
            mount_nas
            backup_tar
            backup_mysqlaio
            umount_nas
        ;;
        data)
            mount_nas
            sync_data
            umount_nas
        ;;
        windows)
            mount_nas
            backup_windows
            umount_nas
        ;;
        borg)
            mount_nas
            backup_mysqlaio
            backup_borg
            umount_nas
        ;;
        web|www)
            mount_nas
            backup_www
            #backup_mysqlaio
            umount_nas
        ;;
        all)
            mount_nas
            backup_web
            backup_mysql
            backup_mysqlaio
            backup_tar
            backup_borg
            umount_nas
        ;;
        mount)
            mount_nas
        ;;
        umount)
            umount_nas
        ;;
        *)
            echo "Usage: $0 {borg|tar|mysql|web|data|blockchain|windows|mount|umount}"
esac
