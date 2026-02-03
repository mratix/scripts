#!/bin/bash

# --- Backup Blockchain Script ---
# Backup and restore script for blockchain nodes running on TrueNAS
# Currently supports Bitcoin (bitcoind), Monero (monerod), and Chia (farmer)
version="260203-alpha, *incomplete, broken during complete rewrite*, by Mr.AtiX + AI rewrite"

# Configuration variables
SERVICE=""
POOL=""
DATASET=""
DESTDIR=""
SRCDIR=""
DEBUG=false
FORCE=false
LOGFILE="/var/log/blockchain_backup.log"

# Prepare environment
prepare() {
    local service="$1"
    local destdir="$2"
    echo "Preparing backup for $service to $destdir"
    # Ensure source directory exists
    if [ ! -d "$SRCDIR" ]; then
        echo "Error: Source directory $SRCDIR does not exist!" >> $LOGFILE
        exit 1
    fi
    # Ensure destination directory exists
    mkdir -p "$destdir"
}

# Take snapshot
take_snapshot() {
    local snapshot_name="snapshot-$(date +%Y-%m-%d_%H-%M)"
    echo "Creating snapshot: $snapshot_name" >> $LOGFILE
    zfs snapshot -r $POOL/$DATASET@$snapshot_name
    if [ $? -eq 0 ]; then
        echo "Snapshot created successfully: $snapshot_name" >> $LOGFILE
    else
        echo "Error: Snapshot creation failed!" >> $LOGFILE
        exit 1
    fi
}

# Rsync for backup
backup_blockchain() {
    echo "Starting backup for $SERVICE" >> $LOGFILE
    rsync -avz --progress $SRCDIR/ $DESTDIR/
    if [ $? -eq 0 ]; then
        echo "Backup completed successfully for $SERVICE" >> $LOGFILE
    else
        echo "Error: Backup failed for $SERVICE" >> $LOGFILE
        exit 1
    fi
}

# Restore from backup
restore_blockchain() {
    echo "Starting restore for $SERVICE from $DESTDIR" >> $LOGFILE
    rsync -avz --progress $DESTDIR/ $SRCDIR/
    if [ $? -eq 0 ]; then
        echo "Restore completed successfully for $SERVICE" >> $LOGFILE
    else
        echo "Error: Restore failed for $SERVICE" >> $LOGFILE
        exit 1
    fi
}

# Main execution flow
if [ "$MODE" == "backup" ]; then
    prepare "$SERVICE" "$DESTDIR"
    take_snapshot
    backup_blockchain
elif [ "$MODE" == "restore" ]; then
    restore_blockchain
else
    echo "Error: Invalid mode specified" >> $LOGFILE
    exit 1
fi

*incomplete, broken during complete rewrite*

