# Changelog (audio-video)

## 2026-02-15

### Added
- New canonical converter: `convert_video_archive_any-mp4.sh`.
- Optional audio-only extraction modes in converter:
  - `audioonly` / `audioonly-mp3`
  - `audioonly-copy`
- `audio-video/README.md` and this `CHANGELOG.md`.

### Changed
- `convert_pvr-rec_any-mp4.sh` converted into backward-compatible wrapper to the new canonical converter.
- `kodi_nfo-generator_musicvideos.sh` enhanced with:
  - case-insensitive `audio only` detection robust to punctuation
  - cleaned output base name usage
  - optional `AUDIO_ONLY_MODE` (`mp3` / `copy`)
  - safer parsing/loop handling and clearer conditionals

### Fixed
- Prevented hang in artist parsing logic in NFO generator (AWK outer match position handling).
- Improved converter counter increments for safer behavior with `set -e`.
