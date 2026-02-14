#!/bin/bash

# Script to backup MySQL databases and directories to a NAS server
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="250101, by Mr.AtiX"

set -euo pipefail
IFS=$'\n\t'

NAS_HOST=192.168.178.20
NAS_HOSTNAME=cronas
NAS_SHARE=backups
NAS_MOUNTP=/mnt/$NAS_HOSTNAME/$NAS_SHARE

SQL_USER=rsync
SQL_PASSWD=
SQL_HOST="192.168.178.66"
SQL_HOSTNAME="crodebhassio"

sqlbakpath="${NAS_MOUNTP}/databases/mysql"
sqllocalpath="$HOME/Dokumente/machines/${SQL_HOSTNAME}"
destbakpath="${NAS_MOUNTP}/pools/rsync/$(hostname -s)"

SRCDIR1='/etc'
SRCDIR2='/var/www'

COMMON_TAR_EXCLUDES=(
    --exclude='*/cache/*'
    --exclude='.cache/*'
    --exclude='*/crashes/*'
)

today="$(date +%Y%m%d)"

# --- logger
show() { echo "$*"; }
log() { echo "$(date +'%Y-%m-%d %H:%M:%S') $*"; }
vlog() { [[ "${VERBOSE:-false}" == "true" ]] || return 0; log "> $*"; }
warn() { log "WARNING: $*"; }
error() { log "ERROR: $*" >&2; exit 1; }


# Backup file system, create tar-archive
backup_tar() {
    local destfile=""
    local split_limit_bytes="${TAR_SPLIT_LIMIT_BYTES:-1073741824}" # 1 GiB

    split_archive_if_large() {
        local archive="$1"
        local size_bytes=""

        size_bytes="$(stat -c %s "$archive")"
        if [ "$size_bytes" -le "$split_limit_bytes" ]; then
            return 0
        fi

        if split -b "$split_limit_bytes" -d -a 4 "$archive" "${archive}.part-"; then
            rm -f "$archive"
            vlog "mybackup: task tar split archive $archive into ${archive}.part-*"
        else
            warn "Error: task tar split $archive"
        fi
    }

    vlog "mybackup: task tar"
    mkdir -p "${destbakpath}/${today}"

    # task 1
    vlog "mybackup: task tar1"
    destfile="${destbakpath}/${today}/rootfs-$(date +"%y%m%d%H%M").tar.gz"
    if ! tar --warning=no-file-changed --exclude="*/proc/*" --exclude="*/dev/*" "${COMMON_TAR_EXCLUDES[@]}" -zcvf "$destfile" "$SRCDIR1"; then
        warn "Error: task tar1 $SRCDIR1"
    else
        split_archive_if_large "$destfile"
    fi

    # task 2
    vlog "mybackup: task tar2"
    destfile="${destbakpath}/${today}/www-$(date +"%y%m%d%H%M").tar.gz"
    if ! tar --warning=no-file-changed "${COMMON_TAR_EXCLUDES[@]}" -zcvf "$destfile" "$SRCDIR2"; then
        warn "Error: task tar2 $SRCDIR2"
    else
        split_archive_if_large "$destfile"
    fi

    # task 3
    vlog "mybackup: task tar3"
    destfile="${destbakpath}/${today}/home-$(date +"%y%m%d%H%M").tar.gz"
    if ! tar \
        --warning=no-file-changed \
        --exclude ".bash_history " \
        "${COMMON_TAR_EXCLUDES[@]}" \
        --exclude '*/_*' \
        --exclude '*/cronas?_*' \
        --exclude "datareporting" \
        --exclude "Musik" \
        --exclude "Thumbnails" \
        --exclude "Videos" \
        -zcvf "$destfile" \
        /root /home; then
        warn "Error: task tar3 /root /home"
    else
        split_archive_if_large "$destfile"
    fi

    vlog "mybackup: task tar Ended at $(date)"
}


# Backup file system with rsync
sync_data() {
    local old_share="$NAS_SHARE"
    local old_mountp="$NAS_MOUNTP"

    rsync_twoway() {
        local src="$1"
        local dst="$2"

        [ -d "$src" ] || return 0
        mkdir -p "$dst"
        if ! rsync -au "$src" "$dst"; then
            warn "Error: task data twoway push $src -> $dst"
        fi
        if ! rsync -au "$dst" "$src"; then
            warn "Error: task data twoway pull $dst -> $src"
        fi
    }

    rsync_move() {
        local src="$1"
        local dst="$2"

        [ -d "$src" ] || return 0
        mkdir -p "$dst"
        if ! rsync -au --remove-source-files "$src" "$dst"; then
            warn "Error: task data move $src -> $dst"
            return 0
        fi
        find "$src" -type d -empty -delete || true
    }

    vlog "mybackup: task data"

    NAS_SHARE="home"
    NAS_MOUNTP="/mnt/$NAS_HOSTNAME/$NAS_SHARE"
    mount_nas
    rsync_twoway "$HOME/scripts/" "$NAS_MOUNTP/scripts/"
    rsync_move "$HOME/Musik/" "$NAS_MOUNTP/music/"
    rsync_twoway "$HOME/Videos/" "$NAS_MOUNTP/videos/"
    umount_nas

    NAS_SHARE="data"
    NAS_MOUNTP="/mnt/$NAS_HOSTNAME/$NAS_SHARE"
    mount_nas
    rsync_twoway "$HOME/Dokumente/" "$NAS_MOUNTP/documents/"
    umount_nas

    NAS_SHARE="public"
    NAS_MOUNTP="/mnt/$NAS_HOSTNAME/$NAS_SHARE"
    mount_nas
    rsync_move "$HOME/Downloads/" "$NAS_MOUNTP/downloads/"
    umount_nas

    NAS_SHARE="$old_share"
    NAS_MOUNTP="$old_mountp"
    vlog "mybackup: task data Ended at $(date)"
}


# Backup with Borg
backup_borg() {
    vlog "mybackup: task borg"
    if ! env BORG_PASSCOMMAND="cat $HOME/.borg-passphrase" sudo "$HOME/scripts/borgbackup.sh"; then
        warn "Error: task borg"
    fi
    vlog "mybackup: task borg Ended at $(date)"
}


# Backup blockchain
backup_blockchain() {
    vlog "mybackup: task blockchain"
    if ! env BORG_PASSCOMMAND="cat $HOME/.borg" sudo "$HOME/scripts/backup_blockchain_umbrel.sh"; then
        warn "Error: task blockchain"
    fi
    vlog "mybackup: task blockchain Ended at $(date)"
}


# Backup websites
backup_www() {
    local web_user="${WWW_RSYNC_USER:-rsync}"
    local ssh_key=""
    local src_dir="${SRCDIR2}/html/"
    local dst_dir="/volume2/storage/www/html/"

    if [ -n "${WWW_RSYNC_SSH_KEY:-}" ]; then
        ssh_key="$WWW_RSYNC_SSH_KEY"
    elif [ -r "$HOME/.ssh/id_ed25519_backup_www" ]; then
        ssh_key="$HOME/.ssh/id_ed25519_backup_www"
    elif [ -r "/home/rsync/.ssh/id_ed25519_backup_www" ]; then
        ssh_key="/home/rsync/.ssh/id_ed25519_backup_www"
    elif [ -r "/home/mratix/.ssh/id_ed25519_backup_www" ]; then
        ssh_key="/home/mratix/.ssh/id_ed25519_backup_www"
    else
        ssh_key="$HOME/.ssh/id_ed25519_backup_www"
    fi

    local -a rsync_opts=(
        -avzsh
        -e "ssh -i $ssh_key -o BatchMode=yes"
        --no-o
        --no-g
        --no-perms
        --omit-dir-times
        --delete-during
        --exclude=.bin
        --exclude=sess_*
    )

    if [ "$(hostname -s)" = "$SQL_HOSTNAME" ]; then
        log "mybackup: task www -> rsync Ziel: $web_user@$NAS_HOST:$dst_dir (lokal als $(id -un), key: $ssh_key)"
        if ! rsync "${rsync_opts[@]}" "$src_dir" "$web_user@$NAS_HOST:$dst_dir"; then
            warn "Error: task www"
        fi
        vlog "mybackup: task www Ended at $(date)"
    else
        vlog "mybackup: task www is only possible on $SQL_HOSTNAME."
    fi
}


# Mount NAS share
mount_nas() {
    [ ! -d "$NAS_MOUNTP" ] && sudo mkdir -p "$NAS_MOUNTP"

    if ! mount | grep -qs -- "$NAS_MOUNTP"; then
        # sudo mount -t cifs //$NAS_HOST/backups -o user=$NAS_USER "$NAS_MOUNTP"
        sudo mount "$NAS_MOUNTP"
    fi
}


# Unmount NAS share
umount_nas() {
    sync
    if mount | grep -qs -- "$NAS_MOUNTP"; then
        sudo umount "$NAS_MOUNTP"
    fi
}


# Backup mysql databases
backup_mysql() {
    local DBS=""
    local db=""
    local linkname=""
    local dumpfile=""

    vlog "mybackup: task mysqldump"
    DBS="$(mysql -h "$SQL_HOST" -u "$SQL_USER" --password="${SQL_PASSWD}" -Bse 'show databases')"

    mkdir -p "$sqlbakpath" "$sqllocalpath"

    for db in $DBS; do
        # skip databases
        [ "$db" = "information_schema" ] && continue
        [ "$db" = "mysql" ] && continue
        [ "$db" = "performance_schema" ] && continue
        [ "$db" = "phpmyadmin" ] && continue
        [ "$db" = "sys" ] && continue
        [ "$db" = "zabbix" ] && continue

        dumpfile="/tmp/${db}.sql"

        if ! mysqldump -h "$SQL_HOST" -u "$SQL_USER" --password="${SQL_PASSWD}" -B "$db" > "$dumpfile"; then
            warn "Error: task mysqldump for $db"
            continue
        fi

        # check filesize (don't overwrite last good dump with an empty file)
        if [ -s "$dumpfile" ]; then
            cp -u "$dumpfile" "${sqlbakpath}/${db}_$(date +"%y%m%d%H%M").sql"
            mv -u "$dumpfile" "${sqllocalpath}/$(date +%y%m%d)_${db}.sql"

            # link dump as latest
            linkname="${sqllocalpath}/${db}_last.sql"
            [ -L "$linkname" ] && rm "$linkname"
            ln -s "${sqllocalpath}/$(date +%y%m%d)_${db}.sql" "$linkname"
        else
            warn "Error: dump for $db does not exist or is zero size."
            rm -f "$dumpfile"
        fi
    done

    vlog "mybackup: task mysqldump Ended at $(date)"
}


# Backup mysql databases, all in one
backup_mysqlaio() {
    local db="all_databases"
    local dumpfile="/tmp/${db}.sql"

    vlog "mybackup: task mysqlaio"

    if ! mysqldump -h "$SQL_HOST" -u "$SQL_USER" --password="${SQL_PASSWD}" \
        --single-transaction --routines --triggers --all-databases > "$dumpfile"; then
        warn "Error: task mysqlaio"
    fi

    # check filesize (don't copy an empty file and destroy last good one)
    if [ -s "$dumpfile" ]; then
        [ ! -d "$sqlbakpath" ] && mkdir -p "$sqlbakpath"
        cp -u "$dumpfile" "${sqlbakpath}/${db}_$(date +"%y%m%d%H%M").sql"
        [ ! -d "$sqllocalpath" ] && mkdir -p "$sqllocalpath"
        mv -u "$dumpfile" "${sqllocalpath}/$(date +%y%m%d)_${db}.sql"
    else
        warn "Error: dump does not exist or is zero length."
        rm -f "$dumpfile"
    fi

    vlog "mybackup: task mysqlaio Ended at $(date)"
}


# Main script, logic starts here
cmd="${1:-}"
case "$cmd" in
    blockchain)
        NAS_MOUNTP="/mnt/$NAS_HOSTNAME/blockchain"
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
    borg)
        mount_nas
        backup_mysqlaio
        backup_borg
        umount_nas
        ;;
    web|www)
        mount_nas
        backup_www
        umount_nas
        ;;
    all)
        mount_nas
        backup_www
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
        echo "mybackup.sh version: $version"
        echo "Usage: $0 {borg|tar|mysql|web|data|blockchain|all|mount|umount}"
        exit 1
        ;;
esac
