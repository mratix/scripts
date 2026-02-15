#!/bin/bash
# Backward-compatible wrapper.
# New canonical name:
#   convert_video_archive_any-mp4.sh

script_dir="$(cd "$(dirname "$0")" && pwd)"
new_script="$script_dir/convert_video_archive_any-mp4.sh"

if [[ ! -x "$new_script" ]]; then
    echo "Error: Missing target script: $new_script"
    exit 1
fi

echo "Notice: convert_pvr-rec_any-mp4.sh was renamed to convert_video_archive_any-mp4.sh"
exec "$new_script" "$@"
