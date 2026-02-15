# audio-video scripts

Utility scripts for media conversion and metadata generation.

## Scripts

### `convert_video_archive_any-mp4.sh`
Canonical converter for archived/video files.

Features:
- Source formats: `mpg|mpeg|vob|avi|m4v|mkv|mov|qt|ts|mts|m2ts|wmv|asf|flv|webm|ogv|3gp|3g2|mp4`
- Default mode: remux/transcode to MP4 depending on input/options
- Re-encode options: `force|encode|reencode`
- Profiles: `480p`, `720p`, `1080p`
- Optional audio-only extraction by filename marker `audio only`:
  - `audioonly` / `audio-only` / `audioonly-mp3` -> extract MP3
  - `audioonly-copy` / `audio-only-copy` -> extract audio stream copy to M4A
- Output filenames are normalized (folded/trimmed spaces).

Examples:
```bash
# default conversion in current folder
./convert_video_archive_any-mp4.sh

# convert files from source dir
./convert_video_archive_any-mp4.sh /path/to/source

# force re-encode to 720p
./convert_video_archive_any-mp4.sh /path/to/source reencode 720p

# extract audio-only-marked files as MP3
./convert_video_archive_any-mp4.sh /path/to/source audioonly

# extract audio-only-marked files with codec copy (no re-encode)
./convert_video_archive_any-mp4.sh /path/to/source audioonly-copy
```

---

### `convert_pvr-rec_any-mp4.sh`
Backward-compatible wrapper.

- Forwards to `convert_video_archive_any-mp4.sh`
- Kept for compatibility with existing aliases/jobs.

---

### `kodi_nfo-generator_musicvideos.sh`
Generates Kodi `.nfo` files for `*.mp4` music videos.

Features:
- Parses `Artist - Title.mp4` naming
- Trims/folds whitespace in parsed artist/title
- Escapes XML entities
- Adds common Kodi `musicvideo` tags
- Detects `audio only` marker and can optionally extract audio (`AUDIO_ONLY_MODE=mp3|copy`)

---

### `makemkv-autorip.sh`
Helper for MakeMKV autorip workflows.

## Notes
- Most scripts assume `bash` and `ffmpeg` availability.
- Test with small samples first before running on large collections.
