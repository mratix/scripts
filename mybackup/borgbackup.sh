#!/bin/bash

# Updated: 2026-02-14 (maintained by mratix, refined with Codex)
version="260214, by Mr.AtiX + Codex"

set -euo pipefail
IFS=$'\n\t'

export LANG=de_DE.UTF-8
export BORG_PASSCOMMAND="${BORG_PASSCOMMAND:-cat $HOME/.borg-passphrase}"

NAS_MOUNTP="${NAS_MOUNTP:-/mnt/cronas/backups}"
BORG_PATH="$NAS_MOUNTP/pools/borg"
BORG_REPO="$(hostname -s)"
REPO_LOCATION="$BORG_PATH/$BORG_REPO"

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

ROOTFS_EXCLUDES=(
    --exclude-caches
    --exclude /dev
    --exclude /home
    --exclude /lost+found
    --exclude /mnt
    --exclude /proc
    --exclude /root
    --exclude /run
    --exclude /sys
    --exclude /tmp
    --exclude /var/cache
    --exclude /var/crash
    --exclude /var/lib/docker
    --exclude /var/lib/mysql
    --exclude /var/lock
    --exclude /var/run
    --exclude /var/metrics
    --exclude /var/tmp
    --exclude /var/www
    --exclude '.cache/*'
    --exclude '*.dummy'
    --exclude '*.log.{3-9}.gz'
    --exclude '*.pyc'
    --exclude '.nobackup/*'
    --exclude '.recycle'
    --exclude '.snapshots/*'
    --exclude '*.tmp'
)

WWW_EXCLUDES=(
    --exclude .bin
    --exclude 'sess_*'
)

HOME_EXCLUDES=(
    --exclude-caches
    --exclude lost+found
    --exclude '*/.cache'
    --exclude cache
    --exclude '.deletedByTMM'
    --exclude '*.dummy'
    --exclude '*/.mozilla/firefox/Crash Reports'
    --exclude '*/.mozilla/firefox/*/datareporting'
    --exclude .recycle
    --exclude Thumbnails
    --exclude '.Trash-100?'
    --exclude '*/cronas_*'
    --exclude '*/cronas?_*'
)


# --- logger
show() { echo "$*"; }
view() { show "$*"; }
log() { echo "$(date +'%Y-%m-%d %H:%M:%S') $*"; }
vlog() { [[ "${VERBOSE:-false}" == "true" ]] || return 0; log "> $*"; }
warn() { log "WARNING: $*"; }
error() { log "ERROR: $*" >&2; exit 1; }

command -v borg >/dev/null || error "Borg ist nicht verfügbar."
[ -d "$BORG_PATH" ] || error "Backup-Pfad nicht gefunden: $BORG_PATH"
[ -d "$REPO_LOCATION" ] || error "Repository nicht gefunden: $REPO_LOCATION"
[ -w "$REPO_LOCATION" ] || error "Repository nicht beschreibbar: $REPO_LOCATION"
borg info "$REPO_LOCATION" >/dev/null || error "Repository-Check fehlgeschlagen: $REPO_LOCATION"
log "Repository $BORG_REPO gefunden."

# backup, first job
SECONDS=0
view ""
view "Starte Sicherung von /"
borg create "${BORG_OPTS[@]}" \
    "${ROOTFS_EXCLUDES[@]}" \
    "${REPO_LOCATION}::{hostname}-{now:%Y%m%d%H%M}" /
sync

# backup, second job
if [ -d "/var/www" ]; then
    view ""
    view "Starte Sicherung von /var/www"
    borg create "${BORG_OPTS[@]}" \
        "${WWW_EXCLUDES[@]}" \
        "${REPO_LOCATION}::{hostname}-www-{now:%Y%m%d%H%M}" /var/www
    sync
fi

# backup, third job
view ""
view "Starte Sicherung von /home /root"
borg create "${BORG_OPTS[@]}" \
    "${HOME_EXCLUDES[@]}" \
    "${REPO_LOCATION}::{hostname}-home-{now:%Y%m%d%H%M}" /home /root
sync
log "Sicherung(en) abgeschlossen in $SECONDS sek."

view ""
view "Starte Repository-Bereinigung: Abgelaufene Sicherungen werden entfernt..."
borg prune -v --list "${PRUNE_OPTS[@]}" "$REPO_LOCATION"
sync

view ""
view "End. (Version: $version)"
