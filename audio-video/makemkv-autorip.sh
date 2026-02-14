#!/bin/bash

version="260214, by Mr.AtiX"
# ============================================================

# Define variables (optional read settings.cfg)
SCRIPTROOT="$(dirname "$(realpath "$0")")"
cfgfile"$SCRIPTROOT/settings.cfg"
CACHE="$(awk '/^drive/{print $1}' "$cfgfile" | cut -d '=' -f2)"
SOURCEDRIVE="${1:-/dev/sr0}"
CACHE="$(awk '/^cache/{print $1}' "$cfgfile" | cut -d '=' -f2)"
CACHE="${CACHE:-1}"
DEBUG="$(awk '/^debug/{print $1}' "$cfgfile" | cut -d '=' -f2)"
DEBUG="${DEBUG:-true}"
MINLENGTH="$(awk '/^minlength/{print $1}' "$cfgfile" | cut -d '=' -f2)"
MINLENGTH="${MINLENGTH:-600}"
OUTPUTDIR="$(awk '/^outputdir/' "$cfgfile" | cut -d '=' -f2 | cut -f1 -d"#" | xargs)" # default /home/arm/arm/raw
OUTPUTDIR="${OUTPUTDIR:-$HOME/Videos/_pvr/arm/raw}"
ARGS=""

# source drive not set
#if [ -z "$SOURCEDRIVE" ]; then
#	echo "Source Drive is not defined."
#	echo "Make sure to pass the device as: $0 /dev/sr0"
#	exit 1
#fi
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
	echo "Log directory under $SCRIPTROOT/logs is missing. Trying to create it..."
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
NOW=$(date +"%F_%H-%M-%S")
DISKTITLE="${DISKTITLERAW}_-_$NOW"

mkdir -p "$OUTPUTDIR/$DISKTITLE"
makemkvcon mkv --messages="${LOGDIR}/${NOW}_$DISKTITLERAW.log" --noscan --robot $ARGS disc:"$SOURCEMMKVDRIVE" all "${OUTPUTDIR}/${DISKTITLE}"
rc=$?
if [ "$rc" -le 1 ]; then
	echo "[Info] $SOURCEDRIVE: Ripping finished (exit code $rc), ejecting"
else
	echo "[ERROR] $SOURCEDRIVE: Ripping failed (exit code $rc), ejecting. Please check the log ${LOGDIR}/${NOW}_${DISKTITLERAW}.log"
fi
eject "$SOURCEDRIVE"

exit
