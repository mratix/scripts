#!/bin/bash

# Kodi nfo-generator for musicvideos
# skeleton: https://kodi.wiki/view/NFO_files/Music_videos
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="260214, by Mr.AtiX + Codex"
# ============================================================

set -euo pipefail
shopt -s nullglob

trim_and_fold_spaces() {
    local s="$1"
    s=${s//$'\t'/ }
    s=${s//$'\r'/ }
    s=${s//$'\n'/ }
    while [[ "$s" == *"  "* ]]; do
        s=${s//  / }
    done
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

xml_escape() {
    local s="$1"
    s=${s//&/&amp;}
    s=${s//</&lt;}
    s=${s//>/&gt;}
    s=${s//\"/&quot;}
    s=${s//\'/&apos;}
    printf '%s' "$s"
}

conv_mkv(){
# convert mkv to mp4
if [ -z "$infile" ]; then
    for f in *.mkv; do
		ffmpeg -hide_banner -i "$f" -c copy "${f%.mkv}.mp4"
		if [[ $? != 0 ]]; then
			echo "Error during conv_mkv loop."
		else
			echo "Videofile converted to ${f%.mkv}.mp4"
		fi
	done
else
		outfile=${infile%.mkv}.mp4
		ffmpeg -hide_banner -i "${infile}" -c copy "${outfile}"
		if [[ $? != 0 ]]; then
			echo "Error during conv_mkv job."
			return 1
		fi
		return 0
fi
}


conv_mp3(){
# convert audio only videofile
echo ${infile}
echo "Artist: $artist"
echo "Title : $title"
echo "Output base: ${output_base}"

    audio_mode="${AUDIO_ONLY_MODE:-mp3}"
    if [ "$audio_mode" = "copy" ]; then
        audio_out="${output_base}.m4a"
        ffmpeg -hide_banner -y -i "$infile" -vn -c:a copy "$audio_out"
    else
        audio_out="${output_base}.mp3"
        ffmpeg -hide_banner -y -i "$infile" -vn -c:a libmp3lame -q:a 0 "$audio_out"
    fi

    if [[ $? != 0 ]]; then
        echo "Error during conv_mp3 extraction job."
        return 1
    fi

    echo "Videofile converted to $audio_out"
    return 0
}


for infile in *.mp4; do
	# prepare
    echo "Input : ${infile}"
    outfile="$infile"                               # keep original filename unless explicit rename is enabled
    echo "Rename: ${outfile}"
    artist=${infile%% - *}; title=${infile#* - }	# extract artist and title from filename
    artist="$(trim_and_fold_spaces "$artist")"      # clean whitespaces
    title="$(trim_and_fold_spaces "$title")"        # clean whitespaces
    title=${title##*/}                              # cut extension from title
    title=${title%.mp4}                             # cut extension from title
    output_base="$(trim_and_fold_spaces "$artist - $title")"
    nfofile="${output_base}.nfo"
    echo "Artist: $artist"
    echo "Title : $title"

    shopt -s nocasematch
	if [[ "$title" =~ (^|[^[:alnum:]])audio[[:space:]]+only([^[:alnum:]]|$) ]]; then
        conv_mp3
    fi # convert to mp3 and delete videofile

    # construct the .nfo-file
    echo "Create: ${nfofile}"
    created_on="$(date '+%Y-%m-%d %H:%M:%S')"
    {
        echo '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>'
        echo "<!-- created ${created_on} with $(basename "$0") -->"
        echo "<musicvideo>"
    } > "$nfofile"
    if [ -z "$title" ]; then
        safe_title="$(xml_escape "${infile%.mp4}")"
		echo "  <title>${safe_title}</title>" >> "$nfofile" # title of music video, simple filename
    else
        safe_title="$(xml_escape "$title")"
        echo "  <title>${safe_title}</title>" >> "$nfofile"     # title of music video, extracted title
    fi
    {
	    echo "  <userrating></userrating>"               # Personal rating applied by the user
	    echo "  <album></album>"                         # Name of album the song appears on
	    echo "  <plot></plot>"                           # Review / information of music video
	    echo "  <runtime></runtime>"                     # Minutes only. If ommitted, Kodi will add runtime upon scanning
#	echo "  <thumb aspect=\"thumb\" preview=\"\"></thumb>" >> "$nfofile"  # can multiple, Path to artwork
#	echo "  <playcount></playcount>" >> ${nfofile}      # Setting this to 1 or greater will mark the Music Video
#   echo "  <lastplayed></lastplayed>" >> ${nfofile}    # Date last played, Format as yyyy-mm-dd
	    echo "  <genre></genre>"                         # can multiple, Genre
        echo "  <tag>musicvideo</tag>"                  # can multiple, Video tags
        if [[ "$title" =~ (^|[[:space:]])live($|[[:space:]]) ]]; then
            echo "  <tag>live</tag>"
        fi
        if [[ "$title" =~ lyric ]]; then
            echo "  <tag>lyrics</tag>"
        fi
        if [[ "$title" =~ (^|[[:space:]])remix($|[[:space:]]) ]]; then
            echo "  <tag>remix</tag>"
        fi
    } >> "$nfofile"
#   echo "  <director></director>" >> ${nfofile}        # can multiple, Director of the music video
#   echo "  <premiered></premiered>" >> ${nfofile}      # Release date, Format as yyyy-mm-dd
#   echo "  <year></year>" >> ${nfofile}                # Release Year, Note: Kodi v20: Use <premiered> tag only
#   echo "  <studio></studio>" >> ${nfofile}            # can multiple, Production studio
#   echo "  <actor><name>Taylor Swift</name><role></role><order>0</order><thumb></thumb></actor>" >> ${nfofile} # can multiple, The artist of the song
#   echo "  <dateadded></dateadded>" >> ${nfofile}      # mTime of the playable video file
    if [ -z "$artist" ]; then
		echo "  <artist></artist>" >> "$nfofile"         # unidentified delimiter "-", write valueless
    else
        artists_xml=$(awk -v artist="$artist" -v title="$title" '
            BEGIN {
                artists_raw = artist
                title_tail = title
                IGNORECASE = 1

                while (match(title_tail, /\([^)]*\)/)) {
                    outer_rstart = RSTART
                    outer_rlength = RLENGTH

                    paren = substr(title_tail, outer_rstart + 1, outer_rlength - 2)
                    if (match(paren, /(^|[[:space:]])(feat\.?|ft\.?)[[:space:]]+/)) {
                        artists_raw = artists_raw "," substr(paren, RSTART + RLENGTH)
                    }

                    title_tail = substr(title_tail, outer_rstart + outer_rlength)
                }

                gsub(/[[:space:]]+/, " ", artists_raw)
                gsub(/[[:space:]]*&[[:space:]]*/, "\n", artists_raw)
                gsub(/[[:space:]]*,[[:space:]]*/, "\n", artists_raw)
                gsub(/[[:space:]]+(ft\.?|feat\.?|pres\.?|vs\.?|and)[[:space:]]+/, "\n", artists_raw)

                count = split(artists_raw, arr, /\n/)
                for (i = 1; i <= count; i++) {
                    item = arr[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", item)
                    if (item == "") continue
                    key = tolower(item)
                    if (!seen[key]++) print item
                }
            }
        ')
        if [ -n "$artists_xml" ]; then
            while IFS= read -r artist_name; do
                artist_name="$(xml_escape "$artist_name")"
                echo "  <artist>${artist_name}</artist>" >> "$nfofile"
            done <<< "$artists_xml"
        else
            echo "  <artist></artist>" >> "$nfofile"
        fi
    fi
    shopt -u nocasematch
    echo "</musicvideo>" >> "$nfofile"                  # close top level parent tag
    echo "-------"
done

exit

# todo check filename for "A|audio only" -> call conv_mp3
