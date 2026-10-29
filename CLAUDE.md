# CLAUDE.md

## Project
Single bash script (`convert-to-vp9.sh`) for batch video conversion to VP9 via
libvpx-vp9/ffmpeg. A conversion of janroudaut/convert-to-av1 (WTFPL): structure,
options and behaviour are kept; the encoder layer and the savings display changed.

## Commands
```bash
bash -n convert-to-vp9.sh              # Syntax check
shellcheck convert-to-vp9.sh test.sh option-matrix.sh   # Lint (static analysis)
bash convert-to-vp9.sh --help           # Show usage
bash convert-to-vp9.sh --dry-run .      # Test run (no conversion)
bash test.sh                            # Integration suite (94 tests, synthetic files)
                                        # (runs via a wrapper injecting --min-size 0:
                                        #  synthetic clips are below the 128K default)
bash option-matrix.sh [GROUP...|report] # Every CLI option once -> TESTMATRIX.md
```

Syntax + shellcheck run on pre-commit via lefthook (`lefthook.yml`).
CI (GitLab, `.gitlab-ci.yml`) runs lint, the suite and the option matrix.

## Dependencies
ffmpeg (with libvpx-vp9; libopus unless audio is only copied), ffprobe, python3,
awk, bc, numfmt, stat, mktemp (`df` is used opportunistically for the disk-space
guard — its absence never blocks). 10-bit needs libvpx with high bit depth;
without it `check_dependencies` falls back to 8-bit with a warning.

## Architecture
- `convert-to-vp9.sh` — main script (all logic in one file)
- `test.sh` — integration suite; `option-matrix.sh` — per-option matrix/report
- Output is always MKV container

## Gotchas
- Media metadata comes from a single cached probe per file: `probe_load` runs one
  `ffprobe -show_format -show_streams -of json` + one python3 parse, keyed by path
  (`PROBE_*` globals + `PROBE_STREAMS_TSV`). The probe helpers (`is_av1`,
  `is_mpeg_ts`, `get_video_height`, `get_duration_secs`, `get_total_frames`),
  `compute_track_selection` and `print_file_info` all read from it — never spawn a
  fresh ffprobe for a field that's already in the cache (was ~9 spawns/file → 1)
- `PROBE_STREAMS_TSV` columns: index/type/attached_pic/lang/channels/bitrate/codec.
  Empty fields are emitted as `-` by the python side and decoded back to "" in
  bash — tab is IFS *whitespace*, so consecutive tabs collapse and silently shift
  every following column into the wrong variable (bit us: opus codec landed in
  the channels var). Same placeholder scheme on the scalar first line
- Audio bitrate lookup is 3-tier: stream `bit_rate` → mkvmerge `BPS`/`BPS-eng`
  tag → packet-sampling estimate (`estimate_audio_bitrates`: ONE ~20s demux-only
  ffprobe per file covers ALL audio streams at once, cached; triggered for kept
  tracks in auto mode). MKV usually reports NO audio bitrate — without the
  estimate, auto mode saw 0 kb/s and copied everything. Estimated rates show as
  `~256k` in the header table
- `export LC_NUMERIC=C` at the top is load-bearing: printf %.0f / awk floats
  break under comma-decimal locales. Do NOT widen to LC_ALL=C — it kills the
  UTF-8 table symbols the embedded python prints
- HDR10/HLG sources (`PROBE_V0_COLOR_TRC` = smpte2084/arib-std-b67) get their
  colour metadata forwarded explicitly in `append_vp9_video_args` — VP9 codes
  only the matrix in the bitstream, transfer/primaries go to the MKV Colour
  element from these flags; untagged HDR plays back washed-out. The BT.709 tag
  only applies to SDR with invalid/missing metadata
- Encoder layer: `vp9_*` vars, `set_speed_fast`/`set_speed_hq`,
  `apply_content_type` (offsets on CRF, tv floors cpu-used at 5 and drops the
  hq 2-pass, CRF clamped 0..63), `build_vp9_options` -> `vp9_options`.
  `append_vp9_video_args` is shared by the final pass and the 2-pass analysis
  pass (`build_pass1_cmd`) so both see identical video settings; tile columns
  come from the OUTPUT width (`vp9_tile_columns`, needs `PROBE_V0_WIDTH`)
- Film grain: presets still REQUEST `vp9_film_grain`/`vp9_film_grain_denoise`
  with convert-to-av1 semantics; VP9 has no synthesis, so grain maps to
  `-tune-content film` and denoise is not applied. Never drop that silently:
  banner shows the request, `build_vp9_options` warns once (`VP9_GRAIN_WARNED`)
- 2-pass: pass-log prefix is `$TMPDIR/convert-$$-2pass-*` so `cleanup()`'s
  `convert-$$-*` glob removes it on every exit. Pass 1 runs through the same
  progress monitor with an EMPTY temp_file (no size estimate, no early abort)
- Ctrl-C: ffmpeg traps SIGINT and exits 255 "normally", so bash never runs the
  INT trap and convert-to-av1 just failed the file and went on. `convert_file`
  greps the stderr log for "received signal 2" and `exit 130`s. Early abort and
  the `>` key kill ffmpeg with SIGTERM (signal 15) — keep it that way, or the
  check would mistake them for the user
- Never `cmd | head -1` inside `$(...)` assignments: under pipefail + errexit
  the writer's SIGPIPE (141) kills the script (`--check` flaked on
  `bc --version | head -1`). Use `sed -n 1p` (reads all input)
- SSIM: both inputs go through `setpts=PTS-STARTPTS` (MP4/AAC priming shifts
  the MKV video by ~23 ms -> neighbouring frames were compared, ~0.92 for a
  ~0.996 encode). Sampled seeks shift the output by the difference of the two
  `video_lead`s (container start -> first frame). MPEG-TS has no index: each
  sample snaps to the first source keyframe at/after its point (`spos`; `pos`
  stays an integer for `format_duration`)
- Subtitles Matroska cannot store (`mkv_sub_target`: mov_text -> srt) get a
  per-output-stream `-c:s:N` override (`append_sub_codec_fixes`, also in remux
  mode). Output subtitle order == `TRACKSEL_SUB_IDX` order; sidecars come after
- Savings accounting: `post_process` -> `space_state` ("freed" when the source
  is gone or the output replaced it at the same path, else "pending"),
  `account_savings` (BATCH_* exact bytes, OK rows only — same basis as
  `print_summary`), `report_savings`/`report_space` (per-file lines).
  `freed + pending == saved` must hold; tests compare against `stat`
- `profile_speed`: a profile's --hq/--fast must not reset CLI-explicit crf /
  cpu-used / 2-pass (convert-to-av1 lost them). Outputs take the source's
  permissions via `chmod --reference` on the ts_ref file (mktemp makes 0600)
- Skip rules: VP9 always, AV1 unless `--convert-av1` (`is_vp9`/`is_av1`);
  `--copy-streams` bypasses both
- `audio_tracks` (`--audio-tracks`) is an EXPLICIT list, never a heuristic. Deciding
  what counts as a redundant track belongs to the caller: from inside the converter an
  untitled commentary and a stereo downmix are the same two numbers. An unmatched
  selector falls back to keeping every track — a silent film is the worse failure.
- `PROBE_STREAMS_TSV` is unpacked positionally by `read`, which dumps every leftover
  field into the LAST variable. Adding a column silently corrupts `codec_name`.
- `min_bitrate` (0 = off, `--min-bitrate`) filters on bit/s, **decimal** units —
  reusing `parse_size` there would inflate every threshold by 2.4 %. It costs one
  ffprobe per candidate, unlike `--min-size` which only stats; both `--min-bitrate`
  and `--sort-by-bitrate` are opt-in for that reason.
- `min_size` (128K default, `--min-size`, 0 disables) is ONLY the input filter
  ("don't bother converting"). Output sanity is on the fixed `SANITY_SIZE`
  (128K) constant: corrupt-output floor (`min(SANITY_SIZE, input/10)`, hard
  floor 1K) and forced-verify trigger — raising/zeroing `--min-size` must
  never loosen those guardrails (deliberate split, 2026-07-20)
- `--verify` full-decodes the temp output (with `-xerror`) after SSIM and
  before the atomic mv; forced automatically on outputs below `SANITY_SIZE`
  (near-free at that size, and the size tripwire alone cannot tell a legit
  tiny clip from garbage). `--stats FILE` (print_log_stats) is a standalone
  mode like `--check`; `--stats-live` wraps it in a mtime-poll redraw loop
  (print_log_stats_live, `trap 'exit 0' INT` so Ctrl-C leaves silently). Disk-space guard: skip when df free < input size
  (unknown free space never blocks)
- The per-track opus/copy decision lives in ONE place: `audio_stream_action`
  (used by both `stream_dispositions` and `build_ffmpeg_cmd`, so display ==
  reality). Already-opus tracks are never re-encoded, even with `--opus`
- Per-file header (`print_file_header` → `print_file_info`) renders fixed-width,
  truncated, aligned columns (type / disposition / codec / specs / rate /
  lang-title), main video row first regardless of container stream order. The
  disposition column (av1/opus/copy/skip, colour + symbol) comes from
  `stream_dispositions` (needs `compute_track_selection` run first; it also
  exposes `TRACKSEL_SUB_IDX`). Colours/symbols are passed into the python3 block
  as argv — never put apostrophes inside that block, it's wrapped in bash single
  quotes (use double quotes / temp vars). `--dry-run` shares the same header
- End-of-run `print_summary` File column: bash `printf %-Ns` pads by BYTES, so
  accented names (2-byte/1-col) shrank the field and full-width forms
  (`｜｜`/`：`, 1-char/2-col) widened it — every column after shifted. `disp_width`
  computes real terminal columns (combining=0, East-Asian Wide/Fullwidth=2) and
  the file cell is padded manually; needs UTF-8 LC_CTYPE (`${s:i:1}` per char)
- Without `-y`, an existing output is skipped (resume semantics; in-place
  mkv→mkv replacement always allowed — compare against the *canonical* source
  path, "./x.mkv" vs "x.mkv"). `CLAIMED_OUTPUTS` catches two sources mapping to
  the same output name (foo.mp4+foo.avi, or same basename across subdirs with -o)
- Progress/scan lines are erased with `clear_line` (ANSI `\r\033[K`, width-agnostic
  — a fixed `%-80s` blank left the tail of longer bars). `scan_tick`/`scan_done`
  draw the initial file-scan counter on stderr, interactive-only
- `--log FILE` is a synthetic, greppable per-file TSV written by `add_result`
  (time, status, sizes, saved%, took, note, path) — NOT raw ffmpeg stderr. ffmpeg
  errors surface to the terminal on hard failure instead. Wall time comes from
  `LAST_ENCODE_SECS`, the passing SSIM score from `LAST_SSIM` (both reset per
  file in `convert_file`). Each session opens with a `# ...` comment banner
  (`write_log_session_header`, called in `main` before the first encode; never
  in dry-run). Header lines must stay tab-free — `print_log_stats` skips them
  via its `NF >= 8` awk filter
- Batch progress line ("batch: 3/12 done | saved … | ~… left") prints above each
  file header; its ETA is byte-based: `BATCH_TOTAL_BYTES` is snapshotted in
  `main` before the loop (sources may shrink/vanish), `BATCH_DONE_BYTES`
  accumulates `LAST_INPUT_SIZE` exported by each `convert_file` (no re-stat)
- Cleanup only prints "Interrupted…" / kills descendants on signal exits
  (`exit_code >= 128`) — usage errors / failed `--check` exit 1 and clean silently
- Early abort only triggers when `--rm-if-bigger` or `--smart` is active
- MPEG-TS inputs auto-get timestamp fix flags (`+genpts+igndts`)
- Adjacent .srt/.vtt files are muxed in by default; deleted with `--rm-source`
- Adjacent .txt files are embedded as MKV description metadata but never deleted
- Lock files use atomic noclobber; stale locks (dead PID) are auto-cleaned
- `NO_COLOR` env var and non-TTY stdout both disable colors
- Only the first video stream is encoded to VP9; extra video streams (cover art /
  attached_pic, even when the disposition flag is missing) are copied verbatim.
  ffmpeg's MKV muxer drops the attached_pic flag (same in convert-to-av1)
- Audio codec is decided per-stream (`-c:a:N`); no global `-ac`, so multichannel
  layouts (5.1/7.1) keep their native channels. Non-standard layouts like
  `5.1(side)` are normalised via a per-stream `aformat` filter (libopus rejects them)
- `--exclude`/`--ignore` (aliases) glob-match case-insensitively (`${x,,}` both
  sides). `codec:NAME` patterns match the first video codec instead — they
  `probe_load` lazily per candidate at collection time (single-slot cache, so
  that probe is NOT reused at convert time); `x264`/`x265`/`h265` are aliased
  to the ffprobe ids (`codec_alias`)
- `--langs`/`--audio-langs`/`--sub-langs` filter tracks by language (via ffprobe
  index enumeration, since `-map 0:a:m:language:` is unreliable across ffmpeg builds);
  untagged/`und` tracks are always kept; a safety net keeps all audio if none match
- `--copy-streams`/`--remux`: pure remux (`-c copy`), no re-encode; bypasses the
  already-VP9/AV1 skip so those files can still be cleaned. In `-c copy` mode ffmpeg
  reports `out_time=N/A`, so the progress bar falls back to muxed-frame count
  (`get_total_frames`); early-abort stays gated on real timestamps only (encode);
  the SSIM quality check is skipped (copied streams are bit-identical)
- `--crf`/`--preset`(`--cpu-used`)/`--2pass`/`--1pass` set `vp9_*_explicit`;
  content types (`apply_content_type`) leave explicit values alone; `--sd`/`--hq`
  on the CLI reset the flags (last-wins). All work in `.convert-profile` too (bad
  profile values warn + are ignored — a profile must never kill a batch, see
  `profile_uint`/`profile_str`). Ranges: crf 0-63, cpu-used 0-8
- All numeric CLI args are validated at parse time (`need_arg`/`need_uint`/
  `need_ssim`, `parse_size` supports decimals like `1.5G` and dies on garbage)
- SSIM quality check MUST use explicit `[0:v:0][1:v:0]ssim` pads — a bare `ssim`
  filter mis-selects streams and returns N/A when a cover/attached_pic second
  video stream is present (silently disabling the check). Same N/A trap when
  the output was downscaled (`--max-res`): ssim requires equal dims, so the
  source is scaled down to the output resolution in the filter graph (one
  ffprobe of the temp output's WxH — not in the source probe cache). SSIM is I/O-bound: ~1s
  per 10s sample on ext4 vs 24–105s on WSL `/mnt` (drvfs seeks) — the phase is
  fast unless the files live on a slow mount
- SSIM ffmpeg runs inside a command substitution (deep grandchild), so cleanup
  uses `kill_descendants` (recursive) — `pkill -P $$` alone left it running on Ctrl-C
- `post_process` validates size + runs the SSIM check on the temp output
  *before* the atomic `mv` to the destination — so a rejected encode never
  overwrites the source (in-place `.mkv`) and the check compares against the
  still-intact source, not the output-vs-itself
- `--skip-log[=FILE]`: records files not worth converting (SSIM < min, or output
  larger than source when rejected via `--smart`/`--rm-if-bigger`/early-abort) and
  skips them on later runs (filtered in `collect_and_sort_files`). Default file
  `.convert-skip.list` at the input root; paths stored **relative to the log dir**
  (`skip_key`, portable) with the source size as a safety net (changed file =
  retried). Line format: `size\trelpath\tsource-mtime\treason`. Profiles can
  activate their own list mid-batch, so `SKIP_LOG_SIZES` keys are namespaced
  `abs-list-path\tentry` (`activate_skip_log`: idempotent per list, re-pointed
  per file from `resolve_file_profile`); profile lists are enforced by a second
  `is_skip_logged` check in `convert_file` — collection-time filtering only ever
  sees the CLI list
- Per-directory `.convert-profile`: encoding/quality/audio/track flags applied
  per file by walking up from its dir (`resolve_file_profile`). CLI config is
  snapshotted (`snapshot_base_config`/`BASE_CFG`) and restored per file so
  profiles don't leak between directories. `--no-profile` disables. Auto content
  detection was tried and rejected — grain confounds with detail AND motion
  (Die Hard 1988 scored like clean digital), so profiles are the deliberate,
  reliable alternative. Also allowed: quality-check/verify/early-abort flags and
  `--log`/`--skip-log` (relative paths anchor to the profile's dir via
  `profile_path`; the session banner is written lazily per log file,
  `LOG_HEADER_WRITTEN`). `--exclude` (APPENDS to CLI patterns — array
  snapshotted apart in `BASE_EXCLUDES`) and `--min-size` work per file: the
  collection filter loop resolves each candidate's profile before testing.
  `--sort-by-size`/`--sort-by-date`/`--sort-by-bitrate` come from the FIRST input root's profile
  only (ordering is batch-global). Destructive flags are deliberately NOT
  accepted — a dotfile must never delete files. Precedence: explicit CLI
  flags beat profiles (`CLI_EXPLICIT` groups marked in parse_args, checked
  via `cli_set` in apply_profile_tokens); profiles beat defaults. The
  `cli_set g || { ... }` guards are errexit-safe: a failed inner
  `profile_* && {}` list doesn't propagate (verified empirically), and every
  case arm ends status-0. Profile tokens are normalised at read time
  (`--opt=value` splits, one pair of surrounding quotes stripped — no shell
  in a dotfile); `main` resolves the input root's profile before
  `print_banner` so the banner shows effective values + the root profile line

## Code Style
- All code, comments, CLI output, and docs must be in English
- Bash with `set -euo pipefail`
- Comments: "senior" minimalism — only when necessary/tricky, stating a
  constraint or invariant the code cannot show (1-2 dense lines). Never
  narrate obvious code, paraphrase the condition below, or record change
  history inline (that belongs here in CLAUDE.md)
