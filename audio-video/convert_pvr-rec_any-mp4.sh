#!/bin/bash
# convert pvr-rec_any to mp4
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="250101, by Mr.AtiX"
# ============================================================

set -euo pipefail
IFS=$'\n\t' # Zeilenhandling


# argument verzeichnisse
if [[ $# == 0 ]]; then
	srcdir=$(pwd)
	destdir=$(pwd)
	echo "No directories provided. Using current directory."
else
	srcdir=$1
	destdir=$(pwd)
	if [[ ! -d ${srcdir} ]]; then
		echo "Error: Source directory ${srcdir} doesn't exist or not mounted."
		exit 127
	fi
	if [[ ! -d ${destdir} ]]; then
		echo "Warning: Destination directory ${destdir} doesn't exist or not mounted."
		destdir=$(pwd)
	fi
	echo "Using ${srcdir} as source/working directory."
	echo "Using ${destdir} as destination/archive."
fi


# todo: argument ffmpeg optionen
optenc="-c:v copy -c:a copy -sn -dn -movflags +faststart"
opts="" # zus. options aus argument $2/$3 auswerten und übernehmen
echo "Encoder options ${opts} given."

# todo: argument force re-encode
#optenc="-c:v libx264 -preset medium -crf 22 -c:a aac -b:a 128k -vf format=yuv420p -dn -movflags +faststart"
#optenc="-c:v libx264 -b:v 2600k -pass 2 -vf format=yuv420p -c:a aac -b:a 160k -dn -movflags +faststart"
#optenc="-c:v libx265 -preset medium -crf 22 -c:a aac -b:a 160k -vf format=yuv420p -dn -movflags +faststart"
# 	echo "Re-encoding forced."


#if [[ -f *.mpg ]]; then # wildcard.extension kann so nicht ausgewertet werden
for item in ${srcdir}/*; do
	ext="${file##*.}"

#if [[ $ext == mpg ]]; then # ok
if [[ ${item: -4} == ".mpg" ]]; then
	for name in ${srcdir}/*.${ext}; do
	echo "------------------------------------------------------------"
    echo "[=] Input:  ${srcdir}/${name}   Item: "${item}"
	echo "[=] Temp:   ${srcdir}/${name}.${ext}"
	echo "[=] Output: ${srcdir}/${name} \"${srcdir}/${item}\"
	ffmpeg -hide_banner -nostats -loglevel error -fflags +genpts+igndts -i "${srcdir}/${name}" "${optenc}" "${opts}" "${destdir}/${name%.*}.mp4" && rm -i ${srcdir}/${name}.${ext} || false; exit 127;
	echo .
	done

else
	# checking last character of the path (missing tailing slash)
	if [[ ${srcdir: -1} != '/' ]]; then
		srcdir+='/'
	elif [ -f ${srcdir}/*.mp4 ]; then
		echo "[ ] No additional videofiles (only mp4) in source directory."; # nur mp4 files vorhanden
	else
		echo "[!] No videofiles in source = clean directory."; false;
	fi
fi
done
#fi
if [ $? -eq 0 ]; then echo "[Done]" || echo "[Exit]"; fi




exit
# -----------------------------------------------------------------------------


elif [[ $ext == avi ]]; then
	for name in *.avi; do
	ffmpeg -hide_banner -nostats -loglevel error -fflags +genpts+igndts -i "${name}" "${optenc}" "${opts}" "${name%.*}.mp4" && rm -i ${name}.${ext} || exit 127;
	done

elif [[ $ext == m4v ]]; then
	for name in *.m4v; do
	ffmpeg -hide_banner -nostats -loglevel error -fflags +genpts+igndts -i "${name}" "${optenc}" "${opts}" "${name%.*}.mp4" && rm -i ${name}.${ext} || exit 127;
	done

elif [[ $ext == mkv ]]; then
	for name in *.mkv; do
	ffmpeg -hide_banner -nostats -loglevel errorr -fflags +genpts+igndts -i "${name}" "${optenc}" "${opts}" "${name%.*}.mp4" && rm -i ${name}.${ext} || exit 127;
	done

elif [[ $ext == mp4 ]]; then
	#for name in *.mp4; do
	echo "[!] Use argument: force or encode, to re-encode ${name}.${ext}";
	done

elif [[ $ext == mpg ]]; then
    #  for i in *.mpg; do ffmpeg -i "$i" -vcodec copy -acodec copy -b:a 32k -aspect 16:9 "${i%.*}-neu.mpg"; done
	for name in *.mpg; do
	ffmpeg -hide_banner -nostats -loglevel error -fflags +genpts+igndts -i "${name}" "${optenc}" "${opts}" "${name%.*}.mp4" && rm -i ${name}.${ext} || exit 127;
	done

elif [[ $ext == wmv ]]; then
	for name in *.wmv; do
	echo "Error: Unsupported EOL videocodec for ${name}.${ext}";
	exit 1;
	done

# -----------------------------------------------------------------------------
# ffplay -ss 15:00 -t 0:15  -i in.mp4 -vf "cropdetect=24:16:0" # Werte ermitteln

# 750x576 (typische 16:9 DVD als 4:3 mit Balken -> 720x432 2,35:1)
ffmpeg -loglevel error -fflags +genpts+igndts -i in.mp4 -vf "crop=720:432:0:72" out.mp4

#
# 480p mpeg4 aac avi
#
"${FFMPEG}" -y -i "${INPUT}" -hide_banner -stats -loglevel error ${TEST} -map 0:v:0 -map 0:a:$AUDIO -f avi -vf "${CROP},scale=854:-2" -vcodec mpeg4 -vtag xvid -qscale:v 8 -mbd rd -flags +mv4+aic -trellis 2 -cmp 2 -subcmp 2 -g 300 -acodec aac -ab 128k -ac 2 -ar 44100 -threads 1 -map_metadata -1 -metadata title="${TITLE}" -metadata:s:a:0 language=eng -map_chapters -1 -sn "${OUTPUT}"

#
# 720p x264 ac3 mp4
#
"${FFMPEG}" -y -i "${INPUT}" -hide_banner -stats -loglevel error ${TEST} -map 0:v:0 -map 0:a:$AUDIO -f mp4 -vf "${CROP},scale=1280:-2" -vcodec libx264 -crf 23 -preset veryslow -tune "${X264TUNE}" -profile:v high -level 4.1 -acodec ac3 -ab 384k -ac 6 -map_metadata -1 -metadata title="${TITLE}" -metadata:s:a:0 language=eng -map_chapters -1 -sn "${OUTPUT}"

#
# 1080p x265 dts mkv
#
"${FFMPEG}" -y -i "${INPUT}" -hide_banner -stats -loglevel error ${TEST} -map 0:v:0 -map 0:a:$AUDIO -f matroska -vf "${CROP},scale=1920:-2" -vcodec libx265 -crf 26 -preset slow -x265-params log-level=quiet -acodec dca -ab 1509k -map_metadata -1 -metadata title="${TITLE}" -metadata:s:a:0 language=eng -map_chapters -1 -sn -strict -2 "${OUTPUT}"

# Screen Resolutions
# 'hd480' = 852x480
# 'hd720' = 1280x720
# 'hd1080' = 1920x1080
# 'uhd2160' = 3840x2160
ffmpeg -s hd720 ...

# 16:9 = 1.78:1 aspect ratio resolutions: 640×360, 720x404, 852×480, 1024×576, 1152×648, 1280×720, 1366×768, 1600×900, 1920×1080, 2560×1440 and 3840×2160.

# -----------------------------------------------------------------------------

