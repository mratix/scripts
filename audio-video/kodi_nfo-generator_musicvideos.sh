#!/bin/bash

# Kodi nfo-generator for musicvideos
# skeleton: https://kodi.wiki/view/NFO_files/Music_videos
# Author: mratix, 1644259+mratix@users.noreply.github.com
version="250101, by Mr.AtiX"
# ============================================================

set -euo pipefail

conv_mkv(){
# convert mkv to mp4
if [ -z "$infile" ]; then
    for f in *.mkv; do
		ffmpeg -hide_banner -i "$f" -c copy "${f%.mkv}.mp4"
		[[ $? != 0 ]] && echo "Error during conv_mkv loop." || echo "Videofile converted to ${f%.mkv}.mp4"
	done
else
		outfile=${infile%.mkv}.mp4
		ffmpeg -hide_banner -i "${infile}" -c copy "${outfile}"
		[[ $? != 0 ]] && echo "Error during conv_mkv job." || return $?
fi
}


conv_mp3(){
# convert audio only videofile to mp3
echo ${infile}
echo "artist: $artist"
echo "title : $title"
echo ${outfile}
	# ...
	[[ $? != 0 ]] && echo "Error during conv_mp3 extraction job." || echo "Videofile converted or Audiofile exists."
return $?
}


for infile in *.mp4; do
	# prepare
    echo "input : "${infile}
    outfile=$(echo ${infile} | xargs -0)			# clean whitespaces and misc chars in filename
    echo "rename: "${outfile}
#	mv -u ${infile} ${outfile} && infile=${outfile}	# rename file
		#input :  Eisbrecher - Volle Kraft voraus (Live, Circus Krone) .mp4
		#        ^                                                    ^	<---
		#rename: Eisbrecher - Volle Kraft voraus (Live, Circus Krone) .mp4
		#                                                            ^	<--- error on trailing space
		#mv: das angegebene Ziel '.mp4' ist kein Verzeichnis
		#mv: target 'Remix).mp4' is not a directory
    nfofile=${infile%.*}.nfo
    artist=${infile%% - *}; title=${infile#* - }	# extract artist and title from filename
    artist=$(echo $artist | xargs -0)               # clean whitespaces
    title=$(echo $title | xargs -0)                 # clean whitespaces
    title=${title##*/}                              # cut extension from title
    title=${title%.mp4}                             # cut extension from title
    echo "artist: $artist"
    echo "title : $title"

	if (echo "$title" | grep -iw "Audio only"); then conv_mp3; fi # convert to mp3 and delete videofile

    # construct the .nfo-file
    echo "create:" ${nfofile}
    echo '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>' > ${nfofile}    # header
    echo "<!-- created $(date +"%Y-%m-%d %H:%M:%S") with $(basename $0) -->" >> ${nfofile}  # comment
    echo "<musicvideo>" >> ${nfofile}                   # The top level parent tag, class of media
    if [ -z "$title" ]; then
		echo "  <title>${infile%.mp4}</title>" >> ${nfofile} # title of music video, simple filename
    else
        echo "  <title>${title}</title>" | sed -r 's/[[:blank:]]+/ /g' >> ${nfofile}  # title of music video, extracted title
    fi
	echo "  <userrating></userrating>" >> ${nfofile}    # Personal rating applied by the user
	echo "  <album></album>" >> ${nfofile}              # Name of album the song appears on
	echo "  <plot></plot>" >> ${nfofile}                # Review / information of music video
	echo "  <runtime></runtime>" >> ${nfofile}          # Minutes only. If ommitted, Kodi will add runtime upon scanning
#	echo         title=(echo -n) $title"  <thumb aspect="thumb" preview=""></thumb>"  # can multiple, Path to TV Show and Season artwork
#	echo "  <playcount></playcount>" >> ${nfofile}      # Setting this to 1 or greater will mark the Music Video
#   echo "  <lastplayed></lastplayed>" >> ${nfofile}    # Date last played, Format as yyyy-mm-dd
	echo "  <genre></genre>" >> ${nfofile}              # can multiple, Genre
    echo "  <tag>musicvideo</tag>" >> ${nfofile}        # can multiple, Video tags
    if (echo "$title" | grep -iw "Live"); then echo "  <tag>live</tag>" >> ${nfofile}; fi
    if (echo "$title" | grep -iq "Lyric"); then echo "  <tag>lyrics</tag>" >> ${nfofile}; fi
    if (echo "$title" | grep -iw "Remix"); then echo "  <tag>remix</tag>" >> ${nfofile}; fi
#   echo "  <director></director>" >> ${nfofile}        # can multiple, Director of the music video
#   echo "  <premiered></premiered>" >> ${nfofile}      # Release date, Format as yyyy-mm-dd
#   echo "  <year></year>" >> ${nfofile}                # Release Year, Note: Kodi v20: Use <premiered> tag only
#   echo "  <studio></studio>" >> ${nfofile}            # can multiple, Production studio
#   echo "  <actor><name>Taylor Swift</name><role></role><order>0</order><thumb></thumb></actor>" >> ${nfofile} # can multiple, The artist of the song
#   echo "  <dateadded></dateadded>" >> ${nfofile}      # mTime of the playable video file
    if [ -z "$artist" ]; then
		echo "  <artist></artist>" >> ${nfofile}        # unidentified delimiter "-", write valueless
    else
        echo "  <artist>${artist}</artist>" | sed -r 's/[[:blank:]]+/ /g' >> ${nfofile} # can multiple, The artists/actors in the music video

		# todo: split multiple artists/actors
		# (separators: & and , ft. feat. pres. vs.), cut leading/tailing space, write multiple artist lines
		# $title can have "(feat. artistname)"
    fi
    echo "</musicvideo>" >> ${nfofile}                  # close top level parent tag
    echo "-------"
done

