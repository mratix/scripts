#!/bin/bash

# BorgBackup for machines on local network
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="250101, by Mr.AtiX"

set -euo pipefail
IFS=$'\n\t'

export LANG=de_DE.UTF-8
export BORG_PASSCOMMAND="cat $HOME/.borg-passphrase"
# export BORG_LIBLZ4_PREFIX=/usr/bin/lz4
# export BORG_LIBXXHASH_PREFIX

NAS_HOSTNAME=cronas
NAS_SHARE=backups
NAS_MOUNTP=/mnt/$NAS_HOSTNAME/$NAS_SHARE
is_mounted=false
mounted_by_script=false
BORG_PATH="$NAS_MOUNTP/pools/borg"
BORG_REPO="$(hostname -s)"
REPO_LOCATION="$BORG_PATH/$BORG_REPO"
BORG_ENC="repokey" # Verschlüsselung

BORG_OPTS=(
    --stats
    --one-file-system
    --compression lz4
    --lock-wait 120
    --checkpoint-interval 86400
)

PRUNE_OPTS=(
    --keep-within=1d
    --keep-daily=7
    --keep-weekly=4
    --keep-monthly=2
)


# --- logger
show() { echo "$*"; }
view() { show "$*"; }
log() { echo "$(date +'%Y-%m-%d %H:%M:%S') $*"; }
vlog() { [[ "${VERBOSE:-false}" == "true" ]] || return 0; log "> $*"; }
warn() { log "WARNING: $*"; }
error() { log "ERROR: $*" >&2; exit 1; }

cleanup() {
    local rc=$?
    if [[ "$mounted_by_script" == true ]] && grep -qs -- "$NAS_MOUNTP" /proc/mounts; then
        if ! umount "$NAS_MOUNTP"; then
            warn "Unmount von $NAS_MOUNTP fehlgeschlagen."
        fi
    fi
    exit "$rc"
}

trap cleanup EXIT INT TERM

# check rights
if [ "$(id -u)" -ne 0 ]; then
    warn "$0 muss als root oder mit sudo -E ausgeführt werden."
    view "Ende."
    exit 1
fi

# mount the backup-share
if grep -qs -- "$NAS_MOUNTP" /proc/mounts; then
    log "Freigabe backups ist eingehängt."
    is_mounted=true
else
    view "NAS wird geweckt..."
    mount "$NAS_MOUNTP"
    mounted_by_script=true
    read -r -p "(Wait 15 seconds or press any key to continue immediately)" -t 15 -n 1 -s || true
fi

# recheck mounted backup-share
if [ -d "$BORG_PATH" ]; then
    is_mounted=true
else
    warn "Freigabe backups wurde nicht eingehängt. Exit."
    exit 1
fi

# init a new borg-repo if absent
if [[ "$is_mounted" == true ]] && [ ! -d "$REPO_LOCATION" ]; then
    log "Neues Host-Repository für $BORG_REPO wird unter $BORG_PATH angelegt."
    view "Bitte neues Passwort für die Verschlüsselung $BORG_ENC setzen:"
    borg init --encryption="$BORG_ENC" "$REPO_LOCATION"
    # borg key export
elif [[ "$is_mounted" == true ]] && [ ! -w "$REPO_LOCATION" ]; then
    warn "Repository unter $REPO_LOCATION ist nicht beschreibbar."
    view "Bitte Rechte prüfen. Exit."
    exit 1
else
    log "Repository $BORG_REPO gefunden."
fi

# quick preflight checks for clearer headless failures
if ! borg --version >/dev/null; then
    error "Borg ist nicht verfügbar."
fi
if ! borg info "$REPO_LOCATION" >/dev/null; then
    error "Repository-Check fehlgeschlagen: $REPO_LOCATION"
fi

# backup, first job
SECONDS=0
view ""
view "Starte Sicherung von /"
borg create "${BORG_OPTS[@]}" \
    --exclude-caches \
    --exclude /dev \
    --exclude /home \
    --exclude /lost+found \
    --exclude /mnt \
    --exclude /proc \
    --exclude /root \
    --exclude /run \
    --exclude /sys \
    --exclude /tmp \
    --exclude /var/cache \
    --exclude /var/crash \
    --exclude /var/lib/docker \
    --exclude /var/lib/mysql \
    --exclude /var/lock \
    --exclude /var/run \
    --exclude /var/metrics \
    --exclude /var/tmp \
    --exclude /var/www \
    --exclude '.cache/*' \
    --exclude '*.dummy' \
    --exclude '*.log.{3-9}.gz' \
    --exclude '*.pyc' \
    --exclude '.nobackup/*' \
    --exclude '.recycle' \
    --exclude '.snapshots/*' \
    --exclude '*.tmp' \
    "${REPO_LOCATION}::{hostname}-{now:%Y%m%d%H%M}" /
sync

# backup, second job
if [ -d "/var/www" ]; then
    view ""
    view "Starte Sicherung von /var/www"
    borg create "${BORG_OPTS[@]}" \
        --exclude .bin \
        --exclude 'sess_*' \
        "${REPO_LOCATION}::{hostname}-www-{now:%Y%m%d%H%M}" /var/www
    sync
fi

# backup, third job
view ""
view "Starte Sicherung von /home /root"
borg create "${BORG_OPTS[@]}" \
    --exclude-caches \
    --exclude lost+found \
    --exclude '*/.cache' \
    --exclude cache \
    --exclude '.deletedByTMM' \
    --exclude '*.dummy' \
    --exclude '*/.mozilla/firefox/Crash Reports' \
    --exclude '*/.mozilla/firefox/*/datareporting' \
    --exclude .recycle \
    --exclude Thumbnails \
    --exclude '.Trash-100?' \
    --exclude '*/cronas_*' \
    --exclude '*/cronas?_*' \
    "${REPO_LOCATION}::{hostname}-home-{now:%Y%m%d%H%M}" /home /root
sync
log "Sicherung(en) abgeschlossen in $SECONDS sek."

# prune outdated
view ""
view "Starte Repository-Bereinigung: Abgelaufene Sicherungen werden entfernt..."
borg prune -v --list "${PRUNE_OPTS[@]}" "$REPO_LOCATION"
sync

# fixes
# borg --max-lock-wait 3600
# borg break-lock -v --show-rc "$REPO_LOCATION"

view ""
view "End. (Version: $version)"
