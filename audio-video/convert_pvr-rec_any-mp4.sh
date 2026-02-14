#!/bin/bash
# convert pvr-rec_any to mp4
# Draft notes integrated:
# - optional profiles via args: 480p, 720p, 1080p
# - optional reencode via args: force|encode|reencode
# - crop-detect helper:
#   ffplay -ss 15:00 -t 0:15 -i in.mp4 -vf "cropdetect=24:16:0"
# - supported input extensions:
#   mpg, mpeg, vob, avi, m4v, mkv, mov, qt, ts, mts, m2ts, wmv, asf, flv, webm, ogv, 3gp, 3g2, mp4

# Author: mratix, 1644259+mratix@users.noreply.github.com
version="260214, by Mr.AtiX"
# ============================================================

set -euo pipefail
IFS=$'\n\t'
shopt -s nullglob

SUPPORTED_EXT_REGEX='^(mpg|mpeg|vob|avi|m4v|mkv|mov|qt|ts|mts|m2ts|wmv|asf|flv|webm|ogv|3gp|3g2|mp4)$'

srcdir="${1:-$PWD}"
destdir="$PWD"

if [[ ! -d "$srcdir" ]]; then
    echo "Error: Source directory $srcdir doesn't exist or is not mounted."
    exit 1
fi
if [[ ! -d "$destdir" ]]; then
    echo "Error: Destination directory $destdir doesn't exist."
    exit 1
fi

echo "Using $srcdir as source/working directory."
echo "Using $destdir as destination/archive."

optenc=(-c:v copy -c:a copy -sn -dn -movflags +faststart)
opts=()
if (( $# > 1 )); then
    opts=("${@:2}")
fi

reencode=false
profile=""
if (( ${#opts[@]} > 0 )); then
    for i in "${!opts[@]}"; do
        case "${opts[$i]}" in
            force|encode|reencode)
                optenc=(-c:v libx264 -preset veryfast -crf 23 -c:a aac -b:a 128k -vf format=yuv420p -sn -dn -movflags +faststart)
                reencode=true
                unset 'opts[i]'
                echo "Re-encoding forced."
                ;;
            480p|profile480)
                profile="480p"
                reencode=true
                unset 'opts[i]'
                ;;
            720p|profile720)
                profile="720p"
                reencode=true
                unset 'opts[i]'
                ;;
            1080p|profile1080)
                profile="1080p"
                reencode=true
                unset 'opts[i]'
                ;;
        esac
    done
    opts=("${opts[@]}")
fi

case "$profile" in
    480p)
        # 480p mpeg4+aac
        optenc=(-c:v mpeg4 -qscale:v 8 -c:a aac -b:a 128k -vf "scale=854:-2,format=yuv420p" -sn -dn -movflags +faststart)
        echo "Profile selected: 480p"
        ;;
    720p)
        # 720p x264+aac
        optenc=(-c:v libx264 -crf 23 -preset veryfast -profile:v high -level 4.1 -c:a aac -b:a 192k -vf "scale=1280:-2,format=yuv420p" -sn -dn -movflags +faststart)
        echo "Profile selected: 720p"
        ;;
    1080p)
        # 1080p x265+aac
        optenc=(-c:v libx265 -crf 26 -preset slow -x265-params log-level=quiet -c:a aac -b:a 192k -vf "scale=1920:-2,format=yuv420p" -sn -dn -movflags +faststart)
        echo "Profile selected: 1080p"
        ;;
esac

echo "Encoder options ${opts[*]:-<none>} given."

converted=0
skipped=0
errors=0

for item in "$srcdir"/*; do
    [[ -f "$item" ]] || continue

    name="${item##*/}"
    ext="${name##*.}"
    ext="${ext,,}"

    if [[ ! "$ext" =~ $SUPPORTED_EXT_REGEX ]]; then
        ((skipped++))
        continue
    fi

    if [[ "$ext" == "mp4" && "$reencode" != true ]]; then
        ((skipped++))
        continue
    fi

    outfile="$destdir/${name%.*}.mp4"
    if [[ "$ext" == "mp4" ]]; then
        outfile="$destdir/${name%.*}.reencoded.mp4"
    fi

    echo "------------------------------------------------------------"
    echo "Input : $item"
    echo "Output: $outfile"

    if ffmpeg -hide_banner -nostats -loglevel error -fflags +genpts+igndts -i "$item" "${optenc[@]}" "${opts[@]}" "$outfile"; then
        ((converted++))
        if [[ "$ext" != "mp4" ]]; then
            rm -i -- "$item"
        fi
    else
        ((errors++))
        echo "Error: ffmpeg failed: $item"
    fi
done

if (( converted == 0 && skipped == 0 )); then
    echo "Error: No matching videofiles in source directory."
fi

echo "Done. converted=$converted skipped=$skipped errors=$errors"
(( errors == 0 ))

exit
