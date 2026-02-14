#!/bin/bash

# Define variables
SOURCEDRIVE="$1"
SCRIPTROOT="$(dirname "$(realpath "$0")")"
#CACHE="$(awk '/^cache/{print $1}' "$SCRIPTROOT/settings.cfg" | cut -d '=' -f2)"
CACHE=-1
#DEBUG="$(awk '/^debug/{print $1}' "$SCRIPTROOT/settings.cfg" | cut -d '=' -f2)"
DEBUG=true
#MINLENGTH="$(awk '/^minlength/{print $1}' "$SCRIPTROOT/settings.cfg" | cut -d '=' -f2)"
MINLENGTH=600
#OUTPUTDIR="$(awk '/^outputdir/' "$SCRIPTROOT/settings.cfg" | cut -d '=' -f2 | cut -f1 -d"#" | xargs)"
OUTPUTDIR="/home/mratix/arm/raw"
ARGS=""

# Check if the source drive has actually been set and is available
if [ -z "$SOURCEDRIVE" ]; then
	echo "[ERROR] Source Drive is not defined."
	echo "        Make sure to pass the device as: ./makemkv-autorip.sh /dev/sr0"
	exit 1
fi
setcd -i "$SOURCEDRIVE" | grep --quiet 'Disc found'
if [ $? -ne 0 ]; then
        echo "[ERROR] $SOURCEDRIVE: Source Drive is not available."
        exit 1
fi

# Construct the arguments
if [[ "$OUTPUTDIR" == "~"* ]]; then
	if [[ "$OUTPUTDIR" == "~/"* ]]; then
		OUTPUTDIR="$(echo "$(eval echo ~"${SUDO_USER:-$USER}")/${OUTPUTDIR:2}" | sed 's:/*$::')"
	else
		OUTPUTDIR="$(eval echo ~"${SUDO_USER:-$USER}")"
	fi
fi
if [ -d "$OUTPUTDIR" ]; then
	:
else
	echo "[ERROR] The output directory specified in settings.conf is invalid!"
	exit 1
fi
if [ -d "$SCRIPTROOT/logs" ]; then
    LOGDIR="$SCRIPTROOT/logs"
elif [ "$SCRIPTROOT" = "$HOME/bin" ]; then
    LOGDIR="/tmp"
else
	echo "[Warning] Log directory under $SCRIPTROOT/logs is missing. Trying to create it..."
	mkdir -p "$SCRIPTROOT/logs"
	LOGDIR="$SCRIPTROOT/logs"
fi
if [[ "$CACHE" =~ ^[0-9]+$ ]] && [ "$CACHE" != "-1" ]; then
	ARGS="--cache=$CACHE"
fi
if [ "$DEBUG" = "true" ]; then
	ARGS="$ARGS --debug"
fi
if [[ "$MINLENGTH" =~ ^[0-9]+$ ]]; then
	ARGS="$ARGS --minlength=$MINLENGTH"
else
	ARGS="$ARGS --minlength=0"
fi

# Match unix drive name to MakeMKV-drive number and check it
SOURCEMMKVDRIVE=$(makemkvcon --robot --noscan --cache=1 info disc:9999 | grep "$SOURCEDRIVE" | grep -o -E '[0-9]+' | head -1)
if [ -z "$SOURCEMMKVDRIVE" ]; then
	echo "[ERROR] $SOURCEDRIVE: MakeMKV Source Drive is not defined."
	exit 1
fi

echo "[Info] $SOURCEDRIVE: Started ripping process"

# Extract DVD title
DISKTITLERAW=$(blkid -o value -s LABEL "$SOURCEDRIVE")
DISKTITLERAW=${DISKTITLERAW// /_}
NOWDATE=$(date +"%F_%H-%M-%S")
DISKTITLE="${DISKTITLERAW}_-_$NOWDATE"

mkdir -p "$OUTPUTDIR/$DISKTITLE"
makemkvcon mkv --messages="${LOGDIR}/${NOWDATE}_$DISKTITLERAW.log" --noscan --robot $ARGS disc:"$SOURCEMMKVDRIVE" all "${OUTPUTDIR}/${DISKTITLE}"
rc=$?
if [ "$rc" -le 1 ]; then
	echo "[Info] $SOURCEDRIVE: Ripping finished (exit code $rc), ejecting"
else
	echo "[ERROR] $SOURCEDRIVE: RIPPING FAILED (exit code $rc), ejecting. Please check the log ${LOGDIR}/${NOWDATE}_${DISKTITLERAW}.log"
fi
eject "$SOURCEDRIVE"
