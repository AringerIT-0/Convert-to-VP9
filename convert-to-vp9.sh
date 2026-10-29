#!/usr/bin/env bash
set -euo pipefail

# Locale-proof decimals (printf %.0f, awk/bc floats). LC_NUMERIC only:
# LC_ALL=C would break the UTF-8 symbols printed by the embedded python.
export LC_NUMERIC=C

# ==============================================================================
# convert-to-vp9 v1.0.0 — Batch video conversion to VP9 (libvpx-vp9 via ffmpeg)
# Derived from convert-to-av1 v3.6.0 (janroudaut/convert-to-av1, WTFPL)
# ==============================================================================

VERSION="1.0.0"

# -- Colors (respects the NO_COLOR convention) ---------------------------------
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    RED='' GREEN='' ORANGE='' GRAY='' BOLD='' NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    ORANGE='\033[38;5;214m'
    GRAY='\033[38;5;8m'
    BOLD='\033[1;37m'
    NC='\033[0m'
fi

# -- Defaults ------------------------------------------------------------------
output_dir=""
in_place=false
input_args=()
remove_source=false
remove_if_bigger=false
keep_best_version=false
overwrite=""
max_res=""

# -- libvpx-vp9 encoding parameters (decomposed for content-type presets) ------
vp9_cpu_used=3             # -cpu-used 0-8 (--preset): lower = slower/better
vp9_crf=32                 # -crf 0-63 with -b:v 0 (constant quality)
vp9_cpu_used_explicit=false  # --preset/--cpu-used N given: presets keep hands off
vp9_crf_explicit=false     # --crf N given: content-type presets keep hands off
vp9_two_pass=false         # analysis pass + final pass (--2pass; implied by --hq)
vp9_two_pass_explicit=false  # --2pass/--1pass given: presets keep hands off
# Film-grain synthesis does not exist in VP9. Presets still REQUEST it exactly as
# convert-to-av1 did; build_vp9_options maps the request (tune-content=film) and
# warns, so nothing is dropped silently.
vp9_film_grain=0           # requested grain level (0 = off)
vp9_film_grain_denoise=0   # requested grain denoise (not applicable in VP9)
vp9_tune_content="default" # derived: "film" when grain is requested
vp9_pix_fmt="yuv420p10le"  # 10-bit = VP9 profile 2 (falls back to 8-bit if unsupported)
vp9_auto_alt_ref=1         # alt-ref frames: VP9's main efficiency tool
vp9_lag_in_frames=25       # look-ahead for alt-ref placement (libvpx max 25)
vp9_keyint=240             # -g: libvpx defaults to ~9999, which ruins seeking
content_type=""        # "", "cartoon", "tv", "movie"
speed_preset="default" # "fast", "default", "hq"
vp9_options=""          # assembled by build_vp9_options()
convert_av1=false      # --convert-av1: re-encode AV1 sources (skipped by default)
VP9_GRAIN_WARNED=false # the grain-mapping warning is printed once per batch

log_file=""
verbose=false
dry_run=false
sort_by_size=""
sort_by_date=""     # the three sort keys are mutually exclusive (last one wins)
sort_by_bitrate=""
no_progress=false
early_abort=true
early_abort_threshold=15  # % of progress; early content compresses atypically, estimates firm up past ~10%
merge_subs=true
recursive=false
audio_langs=""  # comma-separated language codes to keep (empty = keep all)
# Explicit audio stream selection (--audio-tracks), e.g. "a:0,a:2" or "1,3".
# Deliberately dumb: which tracks are worth keeping is the caller's call, not a
# heuristic's. An untitled director's commentary looks exactly like a redundant
# stereo downmix from in here, and guessing wrong deletes it for good.
audio_tracks=""
sub_langs=""    # comma-separated language codes to keep (empty = keep all)
copy_streams=false  # remux only (no re-encode), just strip/keep selected tracks
use_profiles=true   # honor per-directory .convert-profile files
audio_mode="auto"  # copy, opus, auto
audio_bitrate_threshold=200  # kb/s — auto mode re-encodes above this
min_size=131072  # bytes — input filter only (--min-size, 0 disables)
# bits/s — input filter (--min-bitrate, 0 disables). Unlike --min-size this one
# costs an ffprobe per candidate, so it stays off unless asked for.
min_bitrate=0
# Output sanity is deliberately NOT tied to --min-size: an output below
# min(SANITY_SIZE, input/10) is corrupt, one below SANITY_SIZE gets a forced
# decode check — raising the input filter must not loosen these guardrails.
readonly SANITY_SIZE=131072
exclude_patterns=()
skip_log_enabled=false  # persist quality-check failures and skip them on re-runs
skip_log_file=""        # path to the failure log (empty = default at -r root)
after_cmd=""
verify_output=false  # full-decode check of the output before it replaces anything
quality_check=false
quality_min_ssim=0.92  # minimum acceptable SSIM (0-1 scale)
quality_sample_secs=10 # seconds per sample segment for quality check
quality_samples=5      # evenly-spaced sample points for the quality check

# -- Global state (for cleanup) ------------------------------------------------
CURRENT_TEMP_FILE=""
CURRENT_LOCK_FILE=""
CURRENT_STDERR_LOG=""
CURRENT_FFMPEG_PID=""
LAST_ENCODE_SECS=0        # wall time of the last file's ffmpeg run (for --log)
EARLY_ABORTED=false
SKIP_REQUESTED=false
SUMMARY_FILES=()
SUMMARY_STATUSES=()
SUMMARY_INPUT_SIZES=()
SUMMARY_OUTPUT_SIZES=()
SUMMARY_NOTES=()
SUMMARY_SPACE=()          # per row: "freed" (source gone/replaced), "pending", ""
FILES_PROCESSED=0
FILES_TOTAL=0
# Savings accounting (exact bytes, OK rows only — same basis as the summary):
# freed = source already removed/replaced; pending = frees once it is deleted
BATCH_SAVED_BYTES=0       # net: input - output over converted files (may be < 0)
BATCH_CONV_IN_BYTES=0
BATCH_CONV_OUT_BYTES=0
BATCH_FREED_BYTES=0
BATCH_PENDING_BYTES=0
BATCH_START_TIME=0
BATCH_TOTAL_BYTES=0       # sum of all input sizes in the batch (for the ETA)
BATCH_DONE_BYTES=0        # input bytes fully handled so far (for the ETA)
LAST_INPUT_SIZE=0         # input size of the last convert_file call (ETA accounting)
LAST_SSIM=""              # SSIM score of the last successful quality check

# Collision guard: final output path -> first source that claimed it
declare -A CLAIMED_OUTPUTS=()

# Quality-failure skip log: "abs-list-path \t entry-key" -> source size (bytes).
# Keys are namespaced by list file: profiles can activate several lists per run.
declare -A SKIP_LOG_SIZES=()

# --log files that already got their session banner (profiles may add logs mid-batch)
declare -A LOG_HEADER_WRITTEN=()

# -- Per-directory profile state -----------------------------------------------
# Base (CLI) encoding config, snapshotted so per-file profiles start clean.
declare -A BASE_CFG=()
# Option groups explicitly given on the command line — a profile never
# overrides what the user typed for THIS run (defaults don't block anything)
declare -A CLI_EXPLICIT=()
CURRENT_PROFILE_FILE=""   # path of the .convert-profile applied to current file
CURRENT_PROFILE_DIR=""    # its directory — anchors relative --log/--skip-log paths
CURRENT_PROFILE_TOKENS="" # its raw tokens, for the log note + root banner line
CURRENT_PROFILE_PRESETS="" # preset tokens only (--cartoon, --hq, ...) — per-file header

# ==============================================================================
# libvpx-vp9 preset helpers
# ==============================================================================

# Speed presets (shared by parse_args and apply_profile_tokens)
set_speed_fast() {
    vp9_cpu_used=5; vp9_crf=36; vp9_film_grain=0
    speed_preset="fast"
    vp9_cpu_used_explicit=false; vp9_crf_explicit=false
    vp9_two_pass=false; vp9_two_pass_explicit=false
}
set_speed_hq() {
    vp9_cpu_used=1; vp9_crf=32; vp9_film_grain=8
    speed_preset="hq"
    vp9_cpu_used_explicit=false; vp9_crf_explicit=false
    vp9_two_pass=true; vp9_two_pass_explicit=false
}

# Apply content-type overlay on top of speed preset values. An explicit
# --crf/--preset/--2pass always wins: content types only adjust derived values.
apply_content_type() {
    case "$content_type" in
        cartoon)
            vp9_film_grain=0
            $vp9_crf_explicit || vp9_crf=$(( vp9_crf + 2 ))
            ;;
        tv)
            vp9_film_grain=0
            $vp9_crf_explicit || vp9_crf=$(( vp9_crf + 1 ))
            if ! $vp9_cpu_used_explicit && [[ "$vp9_cpu_used" -lt 5 ]]; then
                vp9_cpu_used=5
            fi
            # Throughput material: --hq's implied 2-pass is dropped like its slow preset
            $vp9_two_pass_explicit || vp9_two_pass=false
            ;;
        movie)
            vp9_film_grain_denoise=1
            $vp9_crf_explicit || vp9_crf=$(( vp9_crf - 2 ))
            case "$speed_preset" in
                fast)    vp9_film_grain=8 ;;
                default) vp9_film_grain=10 ;;
                hq)      vp9_film_grain=10 ;;
            esac
            ;;
    esac
    (( vp9_crf > 63 )) && vp9_crf=63
    (( vp9_crf < 0 )) && vp9_crf=0
    return 0
}

# Grain synthesis has no VP9 counterpart: the nearest setting is
# tune-content=film (libvpx: "improves grain retention" — the grain is encoded,
# not re-synthesised). Denoise is not applied: without synthesis it would strip
# the grain for good.
build_vp9_options() {
    vp9_tune_content="default"
    [[ "$vp9_film_grain" -gt 0 ]] && vp9_tune_content="film"
    if { [[ "$vp9_film_grain" -gt 0 ]] || [[ "$vp9_film_grain_denoise" -eq 1 ]]; } \
        && ! $VP9_GRAIN_WARNED && ! $copy_streams; then
        VP9_GRAIN_WARNED=true
        local what="film-grain=${vp9_film_grain}" tail=""
        if [[ "$vp9_film_grain_denoise" -eq 1 ]]; then
            what+=" + film-grain-denoise"
            tail="; denoise not applied (it would strip the grain without re-synthesis)"
        fi
        warn "VP9 has no film-grain synthesis: preset request (${what}) mapped to -tune-content film${tail}"
    fi
    vp9_options="-deadline good -cpu-used ${vp9_cpu_used} -crf ${vp9_crf} -b:v 0 -row-mt 1"
    vp9_options+=" -auto-alt-ref ${vp9_auto_alt_ref} -lag-in-frames ${vp9_lag_in_frames}"
    vp9_options+=" -g ${vp9_keyint} -tune-content ${vp9_tune_content} -pix_fmt:v:0 ${vp9_pix_fmt}"
}

# ==============================================================================
# Per-directory profiles (.convert-profile)
# ==============================================================================
#
# Flags from the nearest .convert-profile (walking up from each file's dir)
# override the CLI base for that file; each directory can differ.

# Config a profile may override — snapshotted so every file starts from the
# same clean CLI base (no leakage between directories).
PROFILE_VARS=(vp9_cpu_used vp9_crf vp9_cpu_used_explicit vp9_crf_explicit
    vp9_two_pass vp9_two_pass_explicit vp9_film_grain vp9_film_grain_denoise
    vp9_pix_fmt vp9_auto_alt_ref vp9_lag_in_frames convert_av1
    content_type speed_preset max_res
    audio_mode audio_bitrate_threshold audio_langs sub_langs audio_tracks copy_streams
    quality_check quality_min_ssim quality_samples verify_output
    early_abort early_abort_threshold merge_subs
    log_file skip_log_enabled skip_log_file
    min_size min_bitrate sort_by_size sort_by_date sort_by_bitrate)

# exclude_patterns is an array — snapshotted apart (printf -v can't restore it);
# profile --exclude APPENDS to the CLI patterns instead of replacing them
BASE_EXCLUDES=()

snapshot_base_config() {
    local v
    for v in "${PROFILE_VARS[@]}"; do
        BASE_CFG["$v"]="${!v}"
    done
    BASE_EXCLUDES=("${exclude_patterns[@]+"${exclude_patterns[@]}"}")
}

restore_base_config() {
    local v
    for v in "${PROFILE_VARS[@]}"; do
        printf -v "$v" '%s' "${BASE_CFG[$v]}"
    done
    exclude_patterns=("${BASE_EXCLUDES[@]+"${BASE_EXCLUDES[@]}"}")
}

find_profile_file() {
    local dir
    dir=$(cd "$(dirname "$1")" 2>/dev/null && pwd) || return 0
    while [[ -n "$dir" ]]; do
        if [[ -f "$dir/.convert-profile" ]]; then
            echo "$dir/.convert-profile"
            return 0
        fi
        [[ "$dir" == "/" ]] && break
        dir=$(dirname "$dir")
    done
}

# Profile validators warn+ignore instead of dying — a bad profile line must
# never kill a whole batch.
profile_uint() {
    [[ "${2:-}" =~ ^[0-9]+$ ]] && return 0
    warn "Profile option $1 expects a whole number, got: ${2:-<missing>} — ignored"
    return 1
}
profile_str() {
    [[ -n "${2:-}" ]] && return 0
    warn "Profile option $1 needs a value — ignored"
    return 1
}
profile_ssim() {
    [[ "${2:-}" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] && return 0
    warn "Profile option $1 expects a value between 0 and 1, got: ${2:-<missing>} — ignored"
    return 1
}
# Must reject everything parse_size dies on — a profile can't afford the die
profile_size() {
    [[ "${2:-}" =~ ^[0-9]+(\.[0-9]+)?([KkMmGgTt]([Ii]?[Bb])?|[Bb])?$ ]] && return 0
    warn "Profile option $1 expects a size (e.g. 500K, 1.5G), got: ${2:-<missing>} — ignored"
    return 1
}

cli_set() { [[ -n "${CLI_EXPLICIT[$1]:-}" ]]; }

# A profile speed preset resets crf/cpu-used/2-pass — but never values the
# user typed on the command line for this run (convert-to-av1 lost them here)
profile_speed() {
    local c="$vp9_crf" ce="$vp9_crf_explicit"
    local p="$vp9_cpu_used" pe="$vp9_cpu_used_explicit"
    local t="$vp9_two_pass" te="$vp9_two_pass_explicit"
    if [[ "$1" == "fast" ]]; then set_speed_fast; else set_speed_hq; fi
    if cli_set crf; then vp9_crf="$c"; vp9_crf_explicit="$ce"; fi
    if cli_set preset; then vp9_cpu_used="$p"; vp9_cpu_used_explicit="$pe"; fi
    if cli_set two_pass; then vp9_two_pass="$t"; vp9_two_pass_explicit="$te"; fi
    return 0
}

# Relative --log/--skip-log values in a profile anchor to the profile's dir
profile_path() {
    case "$1" in
        /*) echo "$1" ;;
        *)  echo "${CURRENT_PROFILE_DIR}/$1" ;;
    esac
}

# Profile-safe subset of parse_args. Value-taking options consume 2 tokens
# when the value is present, 1 otherwise.
# Precedence: explicit CLI flags (CLI_EXPLICIT groups) always win — a profile
# only fills what the user did not type for this run. Same-direction booleans
# (--verify, --quality-check) and appending --exclude need no guard.
apply_profile_tokens() {
    local n
    while [[ $# -gt 0 ]]; do
        n=1; [[ $# -ge 2 ]] && n=2
        case "$1" in
            --sd|--fast)   cli_set speed || profile_speed fast
                           shift ;;
            --hq)          cli_set speed || { profile_speed hq
                               [[ "$audio_mode" == "auto" ]] && audio_mode="copy"; true; }
                           shift ;;
            --cartoon)     cli_set content || content_type="cartoon"; shift ;;
            --tv)          cli_set content || content_type="tv"; shift ;;
            --movie)       cli_set content || content_type="movie"; shift ;;
            --crf)         if cli_set crf; then :
                           elif profile_uint "$1" "${2:-}" && [[ "$2" -le 63 ]]; then
                               vp9_crf="$2"; vp9_crf_explicit=true
                           elif [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                               warn "Profile option $1 expects 0-63 — ignored"
                           fi
                           shift "$n" ;;
            --preset|--cpu-used)
                           if cli_set preset; then :
                           elif profile_uint "$1" "${2:-}" && [[ "$2" -le 8 ]]; then
                               vp9_cpu_used="$2"; vp9_cpu_used_explicit=true
                           elif [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                               warn "Profile option $1 expects 0-8 (libvpx-vp9 -cpu-used) — ignored"
                           fi
                           shift "$n" ;;
            --2pass|--two-pass)
                           cli_set two_pass || { vp9_two_pass=true; vp9_two_pass_explicit=true; }
                           shift ;;
            --1pass|--one-pass)
                           cli_set two_pass || { vp9_two_pass=false; vp9_two_pass_explicit=true; }
                           shift ;;
            --convert-av1) convert_av1=true; shift ;;
            --max-res|--max-h|--max-height)
                           cli_set maxres || { profile_uint "$1" "${2:-}" && max_res="$2"; }
                           shift "$n" ;;
            --1080|--1080p) cli_set maxres || max_res="1080"; shift ;;
            --720|--720p)  cli_set maxres || max_res="720"; shift ;;
            --copy-audio)  cli_set audio_mode || audio_mode="copy"; shift ;;
            --opus)        cli_set audio_mode || audio_mode="opus"; shift ;;
            --auto-audio)  cli_set audio_mode || audio_mode="auto"; shift ;;
            --audio-threshold)
                           if ! cli_set audio_threshold && profile_uint "$1" "${2:-}"; then
                               audio_bitrate_threshold="$2"
                               cli_set audio_mode || audio_mode="auto"
                           fi
                           shift "$n" ;;
            --langs|--lang)
                           if profile_str "$1" "${2:-}"; then
                               cli_set audio_langs || audio_langs="$2"
                               cli_set sub_langs || sub_langs="$2"
                           fi
                           shift "$n" ;;
            --audio-tracks)
                           cli_set audio_tracks || { profile_str "$1" "${2:-}" && audio_tracks="$2"; }
                           shift "$n" ;;
            --audio-langs|--audio-lang)
                           cli_set audio_langs || { profile_str "$1" "${2:-}" && audio_langs="$2"; }
                           shift "$n" ;;
            --sub-langs|--sub-lang)
                           cli_set sub_langs || { profile_str "$1" "${2:-}" && sub_langs="$2"; }
                           shift "$n" ;;
            --copy-streams|--remux)  copy_streams=true; shift ;;
            --quality-check) quality_check=true; shift ;;
            --min-ssim)    cli_set min_ssim \
                               || { profile_ssim "$1" "${2:-}" && { quality_min_ssim="$2"; quality_check=true; }; }
                           shift "$n" ;;
            --ssim-samples)
                           if cli_set ssim_samples; then :
                           elif profile_uint "$1" "${2:-}" && [[ "$2" -ge 1 ]]; then
                               quality_samples="$2"; quality_check=true
                           elif [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                               warn "Profile option $1 expects at least 1 — ignored"
                           fi
                           shift "$n" ;;
            --verify)      verify_output=true; shift ;;
            --no-early-abort) early_abort=false; shift ;;
            --early-abort-threshold)
                           if cli_set early_abort_threshold; then :
                           elif profile_uint "$1" "${2:-}" && [[ "$2" -ge 1 && "$2" -le 99 ]]; then
                               early_abort_threshold="$2"
                           elif [[ "${2:-}" =~ ^[0-9]+$ ]]; then
                               warn "Profile option $1 expects 1-99 — ignored"
                           fi
                           shift "$n" ;;
            --no-merge-subs) merge_subs=false; shift ;;
            --exclude|--ignore)
                           profile_str "$1" "${2:-}" && exclude_patterns+=("$2"); shift "$n" ;;
            --min-size)    cli_set min_size \
                               || { profile_size "$1" "${2:-}" && min_size=$(parse_size "$2"); }
                           shift "$n" ;;
            --min-bitrate) cli_set min_bitrate \
                               || { profile_str "$1" "${2:-}" && min_bitrate=$(parse_rate "$2"); }
                           shift "$n" ;;
            --sort-by-size|--sort-by-date|--sort-by-bitrate)
                           # Batch-level: only honored from the input root's profile
                           local _sort_opt="$1" _sort_dir="desc"
                           if [[ "${2:-}" == "asc" || "${2:-}" == "desc" ]]; then
                               _sort_dir="$2"; shift 2
                           else
                               shift
                           fi
                           if ! cli_set sort; then
                               sort_by_size=""; sort_by_date=""; sort_by_bitrate=""
                               case "$_sort_opt" in
                                   --sort-by-size)    sort_by_size="$_sort_dir" ;;
                                   --sort-by-date)    sort_by_date="$_sort_dir" ;;
                                   --sort-by-bitrate) sort_by_bitrate="$_sort_dir" ;;
                               esac
                           fi ;;
            --log)         cli_set log \
                               || { profile_str "$1" "${2:-}" && log_file=$(profile_path "$2"); }
                           shift "$n" ;;
            --skip-log)    cli_set skip_log || { skip_log_enabled=true
                               skip_log_file="${CURRENT_PROFILE_DIR}/.convert-skip.list"; }
                           shift ;;
            --skip-log=*)
                           if cli_set skip_log; then :
                           elif [[ -n "${1#*=}" ]]; then
                               skip_log_enabled=true
                               skip_log_file=$(profile_path "${1#*=}")
                           else
                               warn "Profile option --skip-log= needs a value — ignored"
                           fi
                           shift ;;
            "")            shift ;;
            *)             warn "Ignoring unsupported profile option: $1"; shift ;;
        esac
    done
}

# Reset to the CLI base, overlay the file's profile, recompute derived options.
resolve_file_profile() {
    local input_file="$1"
    restore_base_config
    CURRENT_PROFILE_FILE=""
    CURRENT_PROFILE_DIR=""
    CURRENT_PROFILE_TOKENS=""
    CURRENT_PROFILE_PRESETS=""

    if $use_profiles; then
        local pf
        pf=$(find_profile_file "$input_file")
        if [[ -n "$pf" ]]; then
            local -a toks=()
            local line tk
            while IFS= read -r line || [[ -n "$line" ]]; do
                line="${line%%#*}"                 # strip comments
                [[ -z "${line// /}" ]] && continue
                local -a lt=()
                read -ra lt <<< "$line"
                # Normalise: --opt=value splits in two, and one pair of
                # surrounding quotes is stripped — profiles have no shell
                for tk in "${lt[@]+"${lt[@]}"}"; do
                    case "$tk" in
                        --skip-log=*) : ;;   # keeps its = form (bare form exists too)
                        --*=*) toks+=("${tk%%=*}"); tk="${tk#*=}" ;;
                    esac
                    case "$tk" in
                        --skip-log=*)
                            local v="${tk#*=}"
                            case "$v" in
                                \'*\') v="${v#\'}"; v="${v%\'}" ;;
                                \"*\") v="${v#\"}"; v="${v%\"}" ;;
                            esac
                            tk="--skip-log=${v}" ;;
                        \'*\') tk="${tk#\'}"; tk="${tk%\'}" ;;
                        \"*\") tk="${tk#\"}"; tk="${tk%\"}" ;;
                    esac
                    toks+=("$tk")
                done
            done < "$pf"
            CURRENT_PROFILE_FILE="$pf"
            CURRENT_PROFILE_DIR=$(dirname "$pf")
            CURRENT_PROFILE_TOKENS="${toks[*]-}"
            local -a plabels=()
            for tk in "${toks[@]+"${toks[@]}"}"; do
                case "$tk" in
                    --sd|--fast|--hq|--cartoon|--tv|--movie|--2pass|--two-pass) plabels+=("$tk") ;;
                esac
            done
            CURRENT_PROFILE_PRESETS="${plabels[*]-}"
            apply_profile_tokens "${toks[@]+"${toks[@]}"}"
        fi
    fi

    apply_content_type
    build_vp9_options
    # Re-point (and lazily load) the skip list — a profile may have switched it
    activate_skip_log
}

# ==============================================================================
# Utility functions
# ==============================================================================

die() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit "${2:-1}"
}

warn() {
    echo -e "${ORANGE}WARN: $1${NC}" >&2
}

info() {
    echo -e "${GREEN}$1${NC}"
}

debug() {
    if $verbose; then
        echo -e "${GRAY}[debug] $1${NC}" >&2
    fi
}

# Width-agnostic erase of the live progress line ("err" = clear on stderr)
clear_line() {
    $no_progress && return
    if [[ "${1:-}" == "err" ]]; then
        printf '\r\033[K' >&2
    else
        printf '\r\033[K'
    fi
}

# Live one-line status for the initial file scan (stderr, interactive only)
scan_tick() {
    { $no_progress || [[ ! -t 2 ]]; } && return
    printf '\r\033[K  %s' "$1" >&2
}
scan_done() {
    { $no_progress || [[ ! -t 2 ]]; } && return
    printf '\r\033[K' >&2
}

human_size() {
    local bytes="${1:-0}"
    if [[ "$bytes" -eq 0 ]]; then
        echo "0B"
    else
        # "--": a negative delta would otherwise be parsed as an option
        numfmt --to=iec -- "$bytes"
    fi
}

# Percentage with one decimal, sign kept: pct_1dp PART WHOLE -> "61.3"
pct_1dp() {
    local part="${1:-0}" whole="${2:-0}"
    [[ "$whole" -gt 0 ]] || { echo "0.0"; return; }
    awk -v p="$part" -v w="$whole" 'BEGIN { printf "%.1f", p * 100 / w }'
}

format_duration() {
    local secs="${1:-0}"
    printf "%02d:%02d:%02d" $((secs / 3600)) $(((secs % 3600) / 60)) $((secs % 60))
}

# -- CLI argument validators (fail at parse time, not mid-batch) ---------------
need_arg() {
    [[ -n "${2:-}" ]] || die "Option $1 requires a value"
}
need_uint() {
    need_arg "$1" "${2:-}"
    [[ "$2" =~ ^[0-9]+$ ]] || die "Option $1 expects a whole number, got: $2"
}
need_ssim() {
    need_arg "$1" "${2:-}"
    [[ "$2" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]] \
        || die "Option $1 expects a value between 0 and 1 (e.g. 0.92), got: $2"
}

# Human-readable size (100M, 1.5G, ...) -> bytes; dies on garbage
parse_size() {
    local input="$1" num unit mult=1
    [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)([A-Za-z]*)$ ]] \
        || die "Invalid size: $input (expected e.g. 500K, 100M, 1.5G)"
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]^^}"
    case "$unit" in
        ""|B)     mult=1 ;;
        K|KB|KIB) mult=1024 ;;
        M|MB|MIB) mult=$(( 1024 ** 2 )) ;;
        G|GB|GIB) mult=$(( 1024 ** 3 )) ;;
        T|TB|TIB) mult=$(( 1024 ** 4 )) ;;
        *)        die "Invalid size unit: $input (use K, M, G or T)" ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f", n * m }'
}
# Bitrates are decimal, not binary: 1500k is 1 500 000 bit/s, and reusing
# parse_size here would silently inflate every threshold by 2.4 %.
parse_rate() {
    local input="$1" num unit mult=1
    [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)([A-Za-z/]*)$ ]] \
        || die "Invalid bitrate: $input (expected e.g. 1500k, 2M, 800000)"
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[3]^^}"
    unit="${unit%/S}"; unit="${unit%BPS}"; unit="${unit%B}"
    case "$unit" in
        "")   mult=1 ;;
        K)    mult=1000 ;;
        M)    mult=1000000 ;;
        G)    mult=1000000000 ;;
        *)    die "Invalid bitrate unit: $input (use k, M or G)" ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN { printf "%.0f", n * m }'
}


# Encoder names people actually type → codec ids ffprobe reports
codec_alias() {
    case "${1,,}" in
        x264|h264|avc)  echo "h264" ;;
        x265|h265)      echo "hevc" ;;
        vp9|libvpx-vp9) echo "vp9" ;;
        av1|svt-av1|svtav1|libsvtav1|aom|libaom-av1) echo "av1" ;;
        *)              echo "${1,,}" ;;
    esac
}

is_excluded() {
    local filename="$1"
    local base pattern
    base=$(basename "$filename")
    base=${base,,}
    for pattern in "${exclude_patterns[@]+"${exclude_patterns[@]}"}"; do
        if [[ "$pattern" == codec:* ]]; then
            # Costs one probe per candidate at collection time — only when the
            # user opts into a codec: pattern (cache is single-slot, no reuse)
            probe_load "$filename"
            [[ -n "$PROBE_V0_CODEC" && "$PROBE_V0_CODEC" == "$(codec_alias "${pattern#codec:}")" ]] \
                && return 0
        else
            # shellcheck disable=SC2254
            case "$base" in ${pattern,,}) return 0 ;; esac
        fi
    done
    return 1
}

# One synthetic TSV line per file in --log — never raw ffmpeg output
write_log_line() {
    local file="$1" status="$2" in_sz="${3:-0}" out_sz="${4:-0}" note="${5:-}"
    write_log_session_header   # no-op once written; profiles add logs mid-batch
    local ts saved="-" out_disp="-" took="-"
    ts=$(date -Iseconds)
    [[ "$out_sz" -gt 0 ]] && out_disp=$(human_size "$out_sz")
    if [[ "$in_sz" -gt 0 && "$out_sz" -gt 0 ]]; then
        saved="$(( (in_sz - out_sz) * 100 / in_sz ))%"
    fi
    [[ "$LAST_ENCODE_SECS" -gt 0 ]] && took=$(format_duration "$LAST_ENCODE_SECS")
    # Profile flags vary per file — the session banner only carries the CLI base
    [[ -n "$CURRENT_PROFILE_TOKENS" ]] && note="${note:+$note }[${CURRENT_PROFILE_TOKENS}]"
    printf '%s\t%-8s\tin=%s\tout=%s\tsaved=%s\ttook=%s\t%s\t%s\n' \
        "$ts" "$status" "$(human_size "$in_sz")" "$out_disp" "$saved" \
        "$took" "${note:-}" "$file" >> "$log_file" 2>/dev/null \
        || warn "Could not write log: $log_file"
}

# Per-session "# ..." banner in --log, written before the first encode.
# Must stay tab-free: print_log_stats skips comment lines via its NF filter.
write_log_session_header() {
    [[ -n "${LOG_HEADER_WRITTEN[$log_file]:-}" ]] && return 0
    LOG_HEADER_WRITTEN["$log_file"]=1
    local enc audio
    if $copy_streams; then
        enc="remux only (no re-encode)"
    else
        enc=$(format_vp9_options)
        [[ -n "$content_type" ]] && enc+=" content=${content_type}"
    fi
    case "$audio_mode" in
        opus) audio="opus (always)" ;;
        auto) audio="auto > ${audio_bitrate_threshold} kb/s" ;;
        *)    audio="copy" ;;
    esac

    local line3="" flags=()
    $keep_best_version && flags+=("smart")
    $remove_source && flags+=("rm-source")
    $remove_if_bigger && flags+=("rm-if-bigger")
    $recursive && flags+=("recursive")
    [[ -n "$overwrite" ]] && flags+=("overwrite")
    $quality_check && flags+=("quality-check>=${quality_min_ssim}")
    $verify_output && flags+=("verify")
    if [[ ${#flags[@]} -gt 0 ]]; then
        local flag_str
        flag_str=$(printf '%s, ' "${flags[@]}")
        line3+="flags: ${flag_str%, }"
    fi
    if [[ -n "$audio_langs" || -n "$sub_langs" ]]; then
        line3+="${line3:+ | }langs: audio=${audio_langs:-all} subs=${sub_langs:-all}"
    fi
    if $early_abort && { $remove_if_bigger || $keep_best_version; }; then
        line3+="${line3:+ | }early-abort: ${early_abort_threshold}%"
    fi
    $use_profiles && line3+="${line3:+ | }profiles: per-dir"

    {
        printf '# ── session %s — convert-to-vp9 v%s\n' "$(date -Iseconds)" "$VERSION"
        printf '# output: %s | encoder: %s | audio: %s\n' \
            "$($in_place && echo "in-place" || echo "$output_dir")" "$enc" "$audio"
        [[ -n "$line3" ]] && printf '# %s\n' "$line3"
        printf '# files: %s queued (%s)\n' "$FILES_TOTAL" "$(human_size "$BATCH_TOTAL_BYTES")"
    } >> "$log_file" 2>/dev/null || warn "Could not write log: $log_file"
}

# Summarise a --log TSV (write_log_line format) and exit
print_log_stats() {
    local f="$1"
    [[ -f "$f" ]] || die "Log file not found: $f"
    echo -e "${BOLD}convert-to-vp9 v${VERSION} — stats for ${f}${NC}"
    echo ""
    awk -F'\t' -v G="$GREEN" -v R="$RED" -v O="$ORANGE" -v D="$GRAY" -v NC="$NC" '
        # human size -> bytes ("in=1.2M" / "out=637K" / "-")
        function hb(s,    n, u) {
            sub(/^(in|out)=/, "", s)
            if (s == "-" || s == "") return 0
            n = s + 0
            u = substr(s, length(s), 1)
            if      (u == "K") n *= 1024
            else if (u == "M") n *= 1048576
            else if (u == "G") n *= 1073741824
            else if (u == "T") n *= 1099511627776
            return n
        }
        # bytes -> human size
        function hs(b) {
            if (b >= 1099511627776) return sprintf("%.1fT", b / 1099511627776)
            if (b >= 1073741824)    return sprintf("%.1fG", b / 1073741824)
            if (b >= 1048576)       return sprintf("%.0fM", b / 1048576)
            if (b >= 1024)          return sprintf("%.0fK", b / 1024)
            return sprintf("%dB", b)
        }
        # "took=HH:MM:SS" -> seconds
        function tsec(s,    a) {
            sub(/^took=/, "", s)
            if (split(s, a, ":") != 3) return 0
            return a[1] * 3600 + a[2] * 60 + a[3]
        }
        function dur(sec) {
            return sprintf("%02dh%02dm", sec / 3600, (sec % 3600) / 60)
        }
        NF >= 8 {
            st = $2; gsub(/ +$/, "", st)
            cnt[st]++; total++
            if (st == "OK") {
                tin  += hb($3); tout += hb($4)
                sec = tsec($6); tsecs += sec
                if (sec > 0) timed++
                if (match($7, /ssim=[0-9.]+/)) {
                    v = substr($7, RSTART + 5, RLENGTH - 5) + 0
                    ssum += v; sn++
                    if (smin == "" || v < smin) smin = v
                }
            }
        }
        function stcolor(st) {
            if (st == "OK")      return G
            if (st == "FAILED" || st == "NOTFOUND") return R
            if (st == "ABORTED") return O
            if (st == "SKIPPED") return D
            return ""
        }
        END {
            if (!total) { print "  (empty log)"; exit }
            for (st in cnt) printf "  %s%-10s%s %d\n", stcolor(st), st, NC, cnt[st]
            printf "  %-10s %d\n", "total", total
            print ""
            if (tin > 0) {
                printf "  converted ......... %s -> %s (%ssaved %s, %d%%%s)\n",
                       hs(tin), hs(tout), G, hs(tin - tout), (tin - tout) * 100 / tin, NC
                if (tsecs > 0) {
                    printf "  encode time ....... %s total", dur(tsecs)
                    if (timed > 0) printf ", avg %dm/file", tsecs / timed / 60
                    printf ", %.1f MB/s\n", tin / tsecs / 1048576
                }
                if (sn > 0)
                    printf "  ssim .............. min %.4f, avg %.4f (%d checked)\n",
                           smin, ssum / sn, sn
            }
        }
    ' "$f"
}

# Follow the log (tail -f style): redraw the stats whenever it changes.
# The file may not exist yet — the batch writing it may not have started.
print_log_stats_live() {
    local f="$1" last="" cur
    trap 'exit 0' INT   # Ctrl-C is the normal way out — leave silently
    while :; do
        cur=$(stat -c '%s %Y' "$f" 2>/dev/null || echo "absent")
        if [[ "$cur" != "$last" ]]; then
            last="$cur"
            [[ -t 1 ]] && printf '\033[H\033[2J'
            if [[ -f "$f" ]]; then
                print_log_stats "$f"
                print_log_last_event "$f"
            else
                echo -e "${GRAY}Waiting for log file: ${f}${NC}"
            fi
            [[ -t 1 ]] && printf "\n  ${GREEN}● live${NC} ${GRAY}— refreshed %s — Ctrl-C to quit${NC}\n" "$(date +%H:%M:%S)"
        fi
        sleep 2
    done
}

# Last TSV line of the log, condensed (live mode: what just happened, when).
# Parsed inside awk: empty fields + tab-whitespace IFS would shift a bash read
print_log_last_event() {
    awk -F'\t' -v G="$GREEN" -v R="$RED" -v O="$ORANGE" -v D="$GRAY" -v NC="$NC" '
        NF >= 8 { ts = $1; st = $2; note = $7; path = $8 }
        END {
            if (ts == "") exit
            gsub(/ +$/, "", st)
            c = ""
            if (st == "OK") c = G
            else if (st == "FAILED" || st == "NOTFOUND") c = R
            else if (st == "ABORTED") c = O
            else if (st == "SKIPPED") c = D
            n = split(path, a, "/")
            printf "  last event ........ %s%s%s  %s%s%s  %s%s\n",
                   D, ts, NC, c, st, NC, a[n],
                   (note == "" ? "" : "  " D "(" note ")" NC)
        }' "$1"
}

add_result() {
    local file="$1" status="$2" input_sz="${3:-0}" output_sz="${4:-0}" note="${5:-}"
    local space="${6:-}"
    SUMMARY_FILES+=("$file")
    SUMMARY_STATUSES+=("$status")
    SUMMARY_INPUT_SIZES+=("$input_sz")
    SUMMARY_OUTPUT_SIZES+=("$output_sz")
    SUMMARY_NOTES+=("$note")
    SUMMARY_SPACE+=("$space")

    if [[ -n "$log_file" && "$status" != "DRYRUN" ]]; then
        write_log_line "$file" "$status" "$input_sz" "$output_sz" "$note"
    fi
}

# ==============================================================================
# Language matching (track filtering)
# ==============================================================================

# Canonicalise to ISO 639-2/B when known; unknown codes pass through lowercased
canon_lang() {
    local c="${1,,}"
    case "$c" in
        fr|fre|fra)     echo "fre" ;;
        en|eng)         echo "eng" ;;
        de|ger|deu)     echo "ger" ;;
        es|spa)         echo "spa" ;;
        it|ita)         echo "ita" ;;
        pt|por)         echo "por" ;;
        ja|jpn)         echo "jpn" ;;
        zh|chi|zho)     echo "chi" ;;
        ru|rus)         echo "rus" ;;
        nl|dut|nld)     echo "dut" ;;
        pl|pol)         echo "pol" ;;
        sv|swe)         echo "swe" ;;
        no|nor)         echo "nor" ;;
        da|dan)         echo "dan" ;;
        fi|fin)         echo "fin" ;;
        ko|kor)         echo "kor" ;;
        ar|ara)         echo "ara" ;;
        tr|tur)         echo "tur" ;;
        cs|cze|ces)     echo "cze" ;;
        el|gre|ell)     echo "gre" ;;
        hu|hun)         echo "hun" ;;
        he|heb)         echo "heb" ;;
        hi|hin)         echo "hin" ;;
        *)              echo "$c" ;;
    esac
}

# Undefined/missing languages ("", "und") always match — never drop a track
# on a missing tag.
lang_matches() {
    local stream_lang="${1,,}"
    local requested_csv="$2"

    if [[ -z "$stream_lang" || "$stream_lang" == "und" ]]; then
        return 0
    fi

    local stream_canon
    stream_canon=$(canon_lang "$stream_lang")

    local IFS=','
    local token
    for token in $requested_csv; do
        token="${token// /}"
        [[ -z "$token" ]] && continue
        [[ "$(canon_lang "$token")" == "$stream_canon" ]] && return 0
    done
    return 1
}

# ==============================================================================
# Quality-failure skip log
# ==============================================================================
#
# Files not worth keeping (low SSIM, output larger) are recorded and skipped on
# later runs. Paths are stored relative to the log so the tree can move; the
# recorded source size means a changed file is retried.

SKIP_LOG_DIR=""
SKIP_LOG_ABS=""                # abspath of the active list — namespaces cache keys
declare -A SKIP_LOGS_LOADED=()

# Absolute path without resolving symlinks (realpath may be absent)
abspath() {
    local p="$1"
    if [[ -d "$p" ]]; then
        (cd "$p" 2>/dev/null && pwd)
    else
        local d
        d=$(cd "$(dirname "$p")" 2>/dev/null && pwd) || { echo "$p"; return; }
        echo "${d%/}/$(basename "$p")"
    fi
}

# Relative to the log dir when under it, absolute otherwise
skip_key() {
    local af
    af=$(abspath "$1")
    if [[ -n "$SKIP_LOG_DIR" && "$af" == "$SKIP_LOG_DIR"/* ]]; then
        echo "${af#"$SKIP_LOG_DIR"/}"
    else
        echo "$af"
    fi
}

# Point the helpers at $skip_log_file and load it once per distinct list —
# profiles can switch lists mid-batch, so this runs per file (cheap after load)
activate_skip_log() {
    $skip_log_enabled || return 0
    SKIP_LOG_ABS=$(abspath "$skip_log_file")
    SKIP_LOG_DIR=$(abspath "$(dirname "$skip_log_file")")
    [[ -n "${SKIP_LOGS_LOADED[$SKIP_LOG_ABS]:-}" ]] && return 0
    SKIP_LOGS_LOADED["$SKIP_LOG_ABS"]=1
    [[ -f "$skip_log_file" ]] || return 0
    local size path
    while IFS=$'\t' read -r size path _; do
        [[ -z "$path" || "$size" == \#* ]] && continue
        [[ "$size" =~ ^[0-9]+$ ]] || continue
        SKIP_LOG_SIZES["${SKIP_LOG_ABS}"$'\t'"$path"]="$size"
    done < "$skip_log_file"
}

# True if the file previously failed and is unchanged (same size = same file)
is_skip_logged() {
    $skip_log_enabled || return 1
    local key rec
    key="${SKIP_LOG_ABS}"$'\t'"$(skip_key "$1")"
    rec="${SKIP_LOG_SIZES[$key]:-}"
    [[ -n "$rec" ]] || return 1
    [[ "$(get_file_size "$1")" == "$rec" ]]
}

# Line format: size \t relpath \t source-mtime \t reason — the mtime identifies
# the file version that failed, not the log-write time.
append_skip_log() {
    $skip_log_enabled || return 0
    local file="$1" size="$2" reason="$3"
    local key rel
    rel=$(skip_key "$file")
    key="${SKIP_LOG_ABS}"$'\t'"$rel"
    [[ "${SKIP_LOG_SIZES[$key]:-}" == "$size" ]] && return 0   # already recorded
    SKIP_LOG_SIZES["$key"]="$size"
    local mt src_mtime="?"
    mt=$(stat -c %Y "$file" 2>/dev/null)
    [[ -n "$mt" ]] && src_mtime=$(date -d "@$mt" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "?")
    printf '%s\t%s\t%s\t%s\n' "$size" "$rel" "$src_mtime" "$reason" \
        >> "$skip_log_file" 2>/dev/null || warn "Could not write skip-log: $skip_log_file"
}

# ==============================================================================
# Probe functions (ffprobe)
# ==============================================================================

# Overall bitrate of a file in bit/s, 0 when the duration is unknown. Goes
# through the probe cache, but on a first visit it is still one ffprobe per
# file — the reason --min-bitrate and --sort-by-bitrate are opt-in.
file_bitrate() {
    local f="$1" sz dur
    probe_load "$f"
    dur="$PROBE_DURATION"
    awk -v d="$dur" 'BEGIN { exit (d > 0.5) ? 0 : 1 }' || { echo 0; return; }
    sz=$(get_file_size "$f")
    awk -v s="$sz" -v d="$dur" 'BEGIN { printf "%.0f", s * 8 / d }'
}

# Per-file probe cache: one ffprobe + one python3 parse serves every metadata
# consumer. Never spawn a fresh ffprobe for a field already in here — each
# spawn costs a fork + file open, painful on slow mounts.
PROBE_FILE=""
PROBE_FORMAT_NAME=""
PROBE_DURATION="0"
PROBE_V0_CODEC=""
PROBE_V0_HEIGHT="0"
PROBE_V0_WIDTH="0"
PROBE_V0_NB_FRAMES="0"
PROBE_V0_AVG_FRAME_RATE=""
PROBE_V0_COLOR_SPACE=""
PROBE_V0_COLOR_TRC=""
PROBE_V0_COLOR_PRIMARIES=""
PROBE_JSON=""          # raw ffprobe JSON, reused by print_file_info
PROBE_STREAMS_TSV=""   # one row per stream: index / type / attached_pic / lang /
                       # channels / bitrate (stream bit_rate, else BPS tag) / codec.
                       # `read` assigns every leftover field to its LAST variable:
                       # an extra column silently lands inside codec_name.

probe_load() {
    local file="$1"
    [[ "$file" == "$PROBE_FILE" ]] && return 0

    PROBE_FILE="$file"
    PROBE_FORMAT_NAME=""; PROBE_DURATION="0"
    PROBE_V0_CODEC=""; PROBE_V0_HEIGHT="0"; PROBE_V0_WIDTH="0"
    PROBE_V0_NB_FRAMES="0"; PROBE_V0_AVG_FRAME_RATE=""; PROBE_V0_COLOR_SPACE=""
    PROBE_V0_COLOR_TRC=""; PROBE_V0_COLOR_PRIMARIES=""
    PROBE_JSON=""; PROBE_STREAMS_TSV=""

    local json
    json=$(ffprobe -v error -show_format -show_streams -of json "$file" 2>/dev/null) || return 0
    [[ -z "$json" ]] && return 0
    PROBE_JSON="$json"

    local parsed
    parsed=$(printf '%s' "$json" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
fmt = d.get("format", {}) or {}
streams = d.get("streams", []) or []
def g(o, k, default=""):
    v = o.get(k, default)
    return "" if v is None else str(v)
# Empty fields become "-": tab is IFS whitespace on the bash side, so
# consecutive tabs would collapse and shift the following columns.
def f(v):
    return v if v != "" else "-"
v0 = next((s for s in streams if s.get("codec_type") == "video"), {})
print("\t".join(f(x) for x in [
    g(fmt, "format_name"),
    g(fmt, "duration", "0"),
    g(v0, "codec_name"),
    g(v0, "height", "0"),
    g(v0, "nb_frames", "0"),
    g(v0, "avg_frame_rate"),
    g(v0, "color_space"),
    g(v0, "color_transfer"),
    g(v0, "color_primaries"),
    g(v0, "width", "0"),
]))
for s in streams:
    disp = s.get("disposition", {}) or {}
    tags = s.get("tags", {}) or {}
    # bit_rate is often absent for audio in MKV; mkvmerge stores it as a BPS tag
    br = g(s, "bit_rate") or (tags.get("BPS", "") or tags.get("BPS-eng", "") or "")
    print("\t".join(f(x) for x in [
        g(s, "index"), g(s, "codec_type"),
        str(disp.get("attached_pic", 0)),
        (tags.get("language", "") or ""),
        g(s, "channels"), str(br), g(s, "codec_name"),
    ]))
') || return 0
    [[ -z "$parsed" ]] && return 0

    # First line = format/video scalars; the rest = per-stream TSV
    local first_line
    IFS= read -r first_line <<< "$parsed"
    IFS=$'\t' read -r PROBE_FORMAT_NAME PROBE_DURATION PROBE_V0_CODEC \
        PROBE_V0_HEIGHT PROBE_V0_NB_FRAMES \
        PROBE_V0_AVG_FRAME_RATE PROBE_V0_COLOR_SPACE \
        PROBE_V0_COLOR_TRC PROBE_V0_COLOR_PRIMARIES PROBE_V0_WIDTH <<< "$first_line"
    # Decode the "-" empty-field placeholder
    local v
    for v in PROBE_FORMAT_NAME PROBE_DURATION PROBE_V0_CODEC PROBE_V0_HEIGHT \
             PROBE_V0_NB_FRAMES PROBE_V0_AVG_FRAME_RATE PROBE_V0_COLOR_SPACE \
             PROBE_V0_COLOR_TRC PROBE_V0_COLOR_PRIMARIES PROBE_V0_WIDTH; do
        [[ "${!v}" == "-" ]] && printf -v "$v" ''
    done
    PROBE_STREAMS_TSV=$(printf '%s\n' "$parsed" | tail -n +2)
    return 0
}

is_av1() {
    probe_load "$1"
    [[ "$PROBE_V0_CODEC" == "av1" ]]
}

is_vp9() {
    probe_load "$1"
    [[ "$PROBE_V0_CODEC" == "vp9" ]]
}

is_mpeg_ts() {
    probe_load "$1"
    [[ "$PROBE_FORMAT_NAME" == *mpegts* ]]
}

get_video_height() {
    probe_load "$1"
    local h="${PROBE_V0_HEIGHT//[!0-9]/}"
    echo "${h:-0}"
}

get_video_width() {
    probe_load "$1"
    local w="${PROBE_V0_WIDTH//[!0-9]/}"
    echo "${w:-0}"
}

# log2 tile columns for libvpx-vp9: VP9 tiles are at least 256 px wide, so
# floor(log2(width / 256)), clamped 0..6 (320 px -> 0, 1080p -> 2, 4K -> 3)
vp9_tile_columns() {
    local w="${1:-0}" t=0
    while (( t < 6 && (w >> (t + 1)) >= 256 )); do
        t=$((t + 1))
    done
    echo "$t"
}

get_duration_secs() {
    probe_load "$1"
    local dur="${PROBE_DURATION%%,*}"
    dur="${dur//[!0-9.]/}"
    printf "%.0f" "${dur:-0}" 2>/dev/null || echo "0"
}

# Total frame count of the primary video stream — drives the progress bar in
# stream-copy mode, where ffmpeg reports out_time as N/A.
get_total_frames() {
    probe_load "$1"
    local duration="${2:-0}"
    local nb="${PROBE_V0_NB_FRAMES//[!0-9]/}"
    if [[ -n "$nb" && "$nb" -gt 0 ]]; then
        echo "$nb"
        return
    fi
    local rfr="${PROBE_V0_AVG_FRAME_RATE%%,*}"
    if [[ "$rfr" == */* && "$duration" -gt 0 ]]; then
        local num den
        num="${rfr%/*}"; den="${rfr#*/}"
        if [[ "$num" =~ ^[0-9]+$ && "$den" =~ ^[0-9]+$ && "$den" -gt 0 ]]; then
            echo $(( duration * num / den ))
            return
        fi
    fi
    echo "0"
}

# Conservative per-layout Opus bitrates — audio quality over video savings
get_opus_bitrate() {
    local channels="$1"
    case "$channels" in
        1) echo "64k" ;;
        2) echo "128k" ;;
        6) echo "256k" ;;   # 5.1
        8) echo "320k" ;;   # 7.1
        *) echo "192k" ;;   # safe default
    esac
}

# libopus rejects non-standard layouts like "5.1(side)": normalising via
# aformat keeps all surround channels. Empty = no normalisation needed.
opus_channel_layout() {
    case "$1" in
        6) echo "5.1" ;;
        8) echo "7.1" ;;
        *) echo "" ;;
    esac
}

get_file_size() {
    stat -c %s "$1" 2>/dev/null || echo "0"
}

# Free bytes on the filesystem holding DIR; empty = unknown (must not block)
get_free_space() {
    df -PB1 "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# Audio bitrates measured by demuxing ~20s of packets — MKV often carries no
# per-stream bit_rate at all, and auto mode must not treat that as 0 kb/s.
# One ffprobe covers every audio stream (packets carry their stream_index);
# cached per file.
ABR_ESTIMATE_FILE=""
declare -A ABR_ESTIMATE_CACHE=()   # stream index -> bits/sec

estimate_audio_bitrates() {
    local file="$1"
    [[ "$file" == "$ABR_ESTIMATE_FILE" ]] && return 0
    ABR_ESTIMATE_FILE="$file"
    ABR_ESTIMATE_CACHE=()
    # Sample away from the head; intros/credits are not representative
    local start=60
    [[ "$(get_duration_secs "$file")" -lt 90 ]] && start=0
    local sidx est
    while read -r sidx est; do
        [[ "$sidx" =~ ^[0-9]+$ && "$est" =~ ^[0-9]+$ ]] || continue
        ABR_ESTIMATE_CACHE[$sidx]="$est"
    done < <(ffprobe -v error -select_streams a \
        -read_intervals "${start}%+20" \
        -show_entries packet=stream_index,pts_time,size -of csv=p=0 "$file" 2>/dev/null \
        | awk -F, '
            $2 != "N/A" && $3 != "" {
                i = $1; p = $2 + 0; sz[i] += $3 + 0
                if (!(i in n) || p < mn[i]) mn[i] = p
                if (!(i in n) || p > mx[i]) mx[i] = p
                n[i]++
            }
            END {
                for (i in n)
                    if (n[i] > 1 && mx[i] > mn[i])
                        printf "%s %.0f\n", i, sz[i] * 8 / (mx[i] - mn[i])
            }
        ') || true
}

# Cached per-stream estimate (bits/sec, 0 = unknown)
estimate_stream_bitrate() {
    estimate_audio_bitrates "$1"
    echo "${ABR_ESTIMATE_CACHE[$2]:-0}"
}

# The per-track opus/copy decision — the ONLY place it is made, shared by the
# header table and build_ffmpeg_cmd so display always matches the encode.
# Already-Opus tracks are never re-encoded (generation loss for no gain).
audio_stream_action() {
    local idx="$1"
    local codec="${TRACKSEL_AUDIO_CODEC[$idx]:-}"
    if [[ "$codec" == "opus" ]]; then
        echo "copy"
        return
    fi
    case "$audio_mode" in
        copy) echo "copy"; return ;;
        opus) echo "opus"; return ;;
    esac
    local kbps=$(( ${TRACKSEL_AUDIO_BR[$idx]:-0} / 1000 ))
    if [[ "$kbps" -gt 0 ]]; then
        if [[ "$kbps" -gt "$audio_bitrate_threshold" ]]; then echo "opus"; else echo "copy"; fi
        return
    fi
    # Bitrate unknown even after packet sampling: lossless/high-bitrate codecs
    # always exceed any sane threshold, everything else copies (safe default)
    case "$codec" in
        flac|alac|dts|truehd|mlp|pcm_*|wmalossless) echo "opus" ;;
        *) echo "copy" ;;
    esac
}

# Emit comma-separated "index=state" pairs for every stream (vp9/opus/copy/
# skip). Requires compute_track_selection to have run for the file.
stream_dispositions() {
    local -A kept_a=() kept_s=()
    local x
    for x in "${TRACKSEL_AUDIO_IDX[@]+"${TRACKSEL_AUDIO_IDX[@]}"}"; do kept_a[$x]=1; done
    for x in "${TRACKSEL_SUB_IDX[@]+"${TRACKSEL_SUB_IDX[@]}"}"; do kept_s[$x]=1; done

    local pairs=() idx ctype state vseen=0
    while IFS=$'\t' read -r idx ctype _ _ _ _ _; do
        [[ -z "$idx" ]] && continue
        case "$ctype" in
            video)
                if [[ "$vseen" -eq 0 ]]; then
                    vseen=1
                    $copy_streams && state="copy" || state="vp9"
                else
                    state="copy"   # cover art / thumbnail
                fi ;;
            audio)
                if [[ -z "${kept_a[$idx]:-}" ]]; then
                    state="skip"
                elif $copy_streams; then
                    state="copy"
                else
                    state=$(audio_stream_action "$idx")
                    # ":~NNNk" suffix = packet-sampled bitrate, fills an
                    # otherwise-empty rate cell in the table
                    if [[ -n "${TRACKSEL_AUDIO_BR_EST[$idx]:-}" && "${TRACKSEL_AUDIO_BR[$idx]:-0}" -gt 0 ]]; then
                        state+=":~$(( TRACKSEL_AUDIO_BR[$idx] / 1000 ))k"
                    fi
                fi ;;
            subtitle)
                if [[ -n "$sub_langs" && -z "${kept_s[$idx]:-}" ]]; then
                    state="skip"
                elif [[ -n "$(mkv_sub_target "${TRACKSEL_SUB_CODEC[$idx]:-}")" ]]; then
                    state="$(mkv_sub_target "${TRACKSEL_SUB_CODEC[$idx]:-}")"
                else
                    state="copy"
                fi ;;
            *)  state="copy" ;;
        esac
        pairs+=("${idx}=${state}")
    done <<< "$PROBE_STREAMS_TSV"
    local IFS=,
    echo "${pairs[*]}"
}

# Render the stream table: type / disposition / codec / specs / rate /
# lang-title, fixed-width and truncated so exotic names never break alignment.
# NOTE: the python block is wrapped in bash single quotes — apostrophes inside
# it are fatal; use double quotes only.
print_file_info() {
    local file="$1"
    local decisions="${2:-}"  # "idx=state,..." from stream_dispositions
    local sidecars="${3:-}"   # "sub\tname" / "txt\tname" per line
    probe_load "$file"
    [[ -z "$PROBE_JSON" ]] && return

    local rendered
    rendered=$(printf '%s' "$PROBE_JSON" | python3 -c '
import sys, json
args = (sys.argv + [""] * 8)[1:9]
GRAY, ORANGE, BOLD, NC, GREEN, RED, decs, sidecars = args
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
streams = data.get("streams", []) or []
fmt = data.get("format", {}) or {}

dec = {}
for p in decs.split(","):
    if "=" in p:
        k, v = p.split("=", 1)
        dec[k] = v

# "state" or "state:extra" — extra is a packet-sampled bitrate ("~256k")
def dec_parts(idx):
    raw = dec.get(str(idx), "")
    state, _, extra = raw.partition(":")
    return state, extra

# orange = re-encode, green = kept as-is, red = dropped
STATE = {
    "vp9":   (ORANGE, "↻ vp9"),
    "opus":  (ORANGE, "↻ opus"),
    "srt":   (ORANGE, "↻ srt"),
    "copy":  (GREEN,  "✓ copy"),
    "mux":   (GREEN,  "✓ mux"),
    "embed": (GREEN,  "✓ embed"),
    "skip":  (RED,    "✗ skip"),
}
SW = 7  # visible width of the disposition column

def cell(word):
    if word not in STATE:
        return " " * SW
    color, w = STATE[word]
    return f"{color}{w}{NC}" + " " * max(0, SW - len(w))

def state_cell(idx):
    return cell(dec_parts(idx)[0])

def trunc(s, w):
    return s if len(s) <= w else s[:w - 1] + "…"

def layout(ch):
    return {1: "mono", 2: "stereo", 6: "5.1", 8: "7.1"}.get(ch, f"{ch}ch" if ch else "")

def fps(rfr):
    if rfr and "/" in rfr:
        try:
            n, d = rfr.split("/")
            d = int(d)
            if d > 0:
                v = int(n) / d
                # 24000/1001 must stay 23.98fps — only true integers collapse
                return f"{v:.0f}fps" if abs(v - round(v)) < 0.001 else f"{v:.2f}fps"
        except Exception:
            pass
    return ""

def dur_fmt(sec):
    try:
        sec = int(float(sec))
    except Exception:
        return ""
    h, m, s = sec // 3600, (sec % 3600) // 60, sec % 60
    if h:
        return f"{h}h{m:02d}m"
    if m:
        return f"{m}m{s:02d}s"
    return f"{s}s"

def kbits(br):
    return f"{int(br)//1000}k" if (br and str(br).isdigit()) else ""

def row(label, sidx, codec, specs, rate, tail):
    return ("  "
            + f"{GRAY}{label:<8}{NC}  "
            + state_cell(sidx) + "  "
            + f"{BOLD}{trunc(codec, 9):<9}{NC}  "
            + f"{trunc(specs, 11):<11}  "
            + f"{rate:<8}  "
            + tail).rstrip()

prim = next((i for i, s in enumerate(streams) if s.get("codec_type") == "video"), None)

# Main video first, then audio/subs/covers — whatever the container order
def prio(i, s):
    ct = s.get("codec_type", "")
    if ct == "video":
        return 0 if i == prim else 3
    return {"audio": 1, "subtitle": 2}.get(ct, 4)

out = []
for i, s in sorted(enumerate(streams), key=lambda t: (prio(t[0], t[1]), t[0])):
    ct = s.get("codec_type", "?")
    cn = s.get("codec_name", "?")
    sidx = s.get("index", i)
    tags = s.get("tags", {}) or {}
    lang, title = tags.get("language", "") or "", tags.get("title", "") or ""
    tag = ""
    if lang:
        tag += f"{ORANGE}[{lang}]{NC}"
    if title:
        tag += (" " if lang else "") + f"{GRAY}{title}{NC}"
    if ct == "video" and i == prim:
        w, h = s.get("width", "?"), s.get("height", "?")
        specs = f"{w}×{h}" if w != "?" else ""
        file_br = kbits(fmt.get("bit_rate", ""))
        d = dur_fmt(fmt.get("duration", ""))
        f = fps(s.get("r_frame_rate", ""))
        container = fmt.get("format_name", "").split(",")[0]
        meta = f"{d} @ {f}" if (d and f) else (d or f)
        if container:
            meta = (meta + " " if meta else "") + f"({container})"
        vtail = f"{GRAY}{meta}{NC}" if meta else ""
        out.append(row("video", sidx, cn, specs, file_br, vtail))
    elif ct == "video":
        w, h = s.get("width", "?"), s.get("height", "?")
        out.append(row("cover", sidx, cn, f"{w}×{h}", "", tag))
    elif ct == "audio":
        try:
            ch = int(s.get("channels") or 0)
        except Exception:
            ch = 0
        # bit_rate, else mkvmerge BPS tag, else the packet-sampled estimate
        rate = kbits(s.get("bit_rate", "") or tags.get("BPS", "") or tags.get("BPS-eng", ""))
        if not rate:
            rate = dec_parts(sidx)[1]
        out.append(row("audio", sidx, cn, layout(ch), rate, tag))
    elif ct == "subtitle":
        out.append(row("subtitle", sidx, cn, "", "", tag))
    else:
        out.append(row(ct, sidx, cn, "", "", tag))

# Sidecar files (external subs, .txt description) as trailing table rows
LABELS = {"sub": "+sub", "txt": "+txt"}
STATES = {"sub": "mux", "txt": "embed"}
for line in sidecars.split("\n"):
    if not line.strip():
        continue
    parts = line.split("\t")
    kind = parts[0]
    name = parts[1] if len(parts) > 1 else ""
    label = LABELS.get(kind) or ("+" + kind)
    out.append("  "
               + f"{GRAY}{label:<8}{NC}  "
               + cell(STATES.get(kind, "copy")) + "  "
               + f"{name} {GRAY}(sidecar){NC}")

print("\n".join(out))
' "$GRAY" "$ORANGE" "$BOLD" "$NC" "$GREEN" "$RED" "$decisions" "$sidecars") || return
    [[ -n "$rendered" ]] && echo -e "$rendered"
}

# Adjacent .srt/.vtt files: exact (video.srt) and language-tagged (video.en.srt)
find_subtitle_files() {
    local input_file="$1"
    local input_dir input_noext
    input_dir=$(dirname "$input_file")
    input_noext="${input_file%.*}"

    local subs=()
    for ext in srt vtt; do
        if [[ -f "${input_noext}.${ext}" ]]; then
            subs+=("${input_noext}.${ext}")
        fi
        for sub_file in "${input_noext}".*."${ext}"; do
            if [[ -f "$sub_file" ]]; then
                local already=false
                for s in "${subs[@]+"${subs[@]}"}"; do
                    [[ "$s" == "$sub_file" ]] && already=true
                done
                $already || subs+=("$sub_file")
            fi
        done
    done

    printf '%s\n' "${subs[@]+"${subs[@]}"}"
}

find_description_file() {
    local input_file="$1"
    local input_noext="${input_file%.*}"

    if [[ -f "${input_noext}.txt" ]]; then
        echo "${input_noext}.txt"
    fi
}

# ==============================================================================
# Lock files
# ==============================================================================

acquire_lock() {
    local file="$1"
    local lock_file="${file}.lock"

    # noclobber makes the creation atomic; a lock owned by a dead PID is stale
    # and retried once
    if ! ( set -C; echo "pid=$$,start=$(date -Iseconds)" > "$lock_file" ) 2>/dev/null; then
        local existing_pid
        existing_pid=$(grep -oP 'pid=\K[0-9]+' "$lock_file" 2>/dev/null || echo "")
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            warn "File locked by PID $existing_pid: $file"
            return 1
        fi
        warn "Stale lock removed: $lock_file"
        rm -f "$lock_file"
        if ! ( set -C; echo "pid=$$,start=$(date -Iseconds)" > "$lock_file" ) 2>/dev/null; then
            warn "Failed to acquire lock (race): $file"
            return 1
        fi
    fi

    CURRENT_LOCK_FILE="$lock_file"
    return 0
}

release_lock() {
    local file="$1"
    local lock_file="${file}.lock"
    rm -f "$lock_file"
    if [[ "$CURRENT_LOCK_FILE" == "$lock_file" ]]; then
        CURRENT_LOCK_FILE=""
    fi
}

# ==============================================================================
# Cleanup (trap)
# ==============================================================================

# Recursive kill: the SSIM ffmpeg runs inside a command substitution (deep
# grandchild of $$), so pkill -P $$ alone would leave it running on Ctrl-C.
kill_descendants() {
    local parent="$1" child
    for child in $(pgrep -P "$parent" 2>/dev/null); do
        kill_descendants "$child"
    done
    if [[ "$parent" != "$$" ]]; then
        kill -9 "$parent" 2>/dev/null || true
    fi
}

cleanup() {
    local exit_code=$?

    # TTOU must be ignored: from a non-foreground process group (timeout(1)
    # setpgid's its child) stty would be SIGSTOPped and hang the exit forever
    { trap '' TTOU; stty sane < /dev/tty; trap - TTOU; } 2>/dev/null || true

    # Only signal exits (>= 128: Ctrl-C, TERM) are an interruption; plain error
    # exits have nothing running and clean up silently
    if [[ "$exit_code" -ge 128 ]]; then
        echo ""
        info "Interrupted — cleaning up..."
        kill_descendants $$
        wait 2>/dev/null || true
    fi
    # Fallback: ffmpeg may outlive the tree walk — kill it by PID file
    local ffmpeg_pid_to_kill="$CURRENT_FFMPEG_PID"
    if [[ -z "$ffmpeg_pid_to_kill" ]]; then
        local pf
        for pf in "${TMPDIR:-/tmp}/convert-${$}-pid-"*; do
            [[ -f "$pf" ]] && ffmpeg_pid_to_kill=$(cat "$pf" 2>/dev/null || echo "") && break
        done
    fi
    if [[ -n "$ffmpeg_pid_to_kill" ]] && kill -0 "$ffmpeg_pid_to_kill" 2>/dev/null; then
        info "  Killing ffmpeg (PID $ffmpeg_pid_to_kill)"
        kill -9 "$ffmpeg_pid_to_kill" 2>/dev/null || true
    fi

    rm -f "${TMPDIR:-/tmp}/convert-${$}-"* 2>/dev/null || true

    if [[ -n "$CURRENT_TEMP_FILE" && -f "$CURRENT_TEMP_FILE" ]]; then
        info "  Removing temp file: $CURRENT_TEMP_FILE"
        rm -f "$CURRENT_TEMP_FILE"
    fi

    if [[ -n "$CURRENT_STDERR_LOG" && -f "$CURRENT_STDERR_LOG" ]]; then
        info "  Removing stderr log: $CURRENT_STDERR_LOG"
        rm -f "$CURRENT_STDERR_LOG"
    fi

    if [[ -n "$CURRENT_LOCK_FILE" && -f "$CURRENT_LOCK_FILE" ]]; then
        info "  Removing lock: $CURRENT_LOCK_FILE"
        rm -f "$CURRENT_LOCK_FILE"
    fi

    if [[ $FILES_PROCESSED -gt 0 ]]; then
        echo ""
        print_summary
    fi

    exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT TERM

# ==============================================================================
# Dependency check
# ==============================================================================

REQUIRED_DEPS=(ffmpeg ffprobe python3 numfmt stat mktemp bc awk)

check_dependencies() {
    local missing=()

    for dep in "${REQUIRED_DEPS[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}"
    fi

    # Not needed for a pure remux — --copy-streams must work on any ffmpeg.
    # Captured first: grep -q on the pipe would SIGPIPE ffmpeg under pipefail
    if ! $copy_streams; then
        local encoders
        encoders=$(ffmpeg -encoders 2>/dev/null || true)
        [[ "$encoders" == *libvpx-vp9* ]] \
            || die "ffmpeg was built without VP9 support (libvpx-vp9) — see --check"
        # Opus is only needed when a track can be re-encoded
        if [[ "$audio_mode" != "copy" && "$encoders" != *libopus* ]]; then
            die "ffmpeg was built without Opus support (libopus) — use --copy-audio or see --check"
        fi
        # 10-bit needs libvpx built with --enable-vp9-highbitdepth; without it
        # every encode would fail, so fall back to 8-bit (profile 0) loudly
        if [[ "$vp9_pix_fmt" == *10le ]] && ! vp9_supports_10bit; then
            warn "libvpx-vp9 in this ffmpeg has no 10-bit support (high bit depth) — encoding 8-bit"
            vp9_pix_fmt="yuv420p"
            BASE_CFG[vp9_pix_fmt]="yuv420p"
            build_vp9_options
        fi
    fi

    debug "ffmpeg: $(ffmpeg -version | sed -n 1p)"
}

vp9_supports_10bit() {
    local h
    h=$(ffmpeg -hide_banner -h encoder=libvpx-vp9 2>/dev/null || true)
    [[ "$h" == *yuv420p10le* ]]
}

check_dependencies_verbose() {
    local all_ok=true

    echo "convert-to-vp9 v$VERSION — dependency check"
    echo ""

    for dep in "${REQUIRED_DEPS[@]}"; do
        local path version_info
        if path=$(command -v "$dep" 2>/dev/null); then
            version_info=""
            # sed -n 1p, not head -1: head closes the pipe early, the writer
            # dies of SIGPIPE, and under pipefail + errexit the script exits 141
            case "$dep" in
                ffmpeg)  version_info=$(ffmpeg -version 2>/dev/null | sed -n 1p) ;;
                ffprobe) version_info=$(ffprobe -version 2>/dev/null | sed -n 1p) ;;
                python3) version_info=$(python3 --version 2>/dev/null) ;;
                bc)      version_info=$(bc --version 2>/dev/null | sed -n 1p) ;;
            esac
            printf "  %-10s OK    %s" "$dep" "$path"
            [[ -n "$version_info" ]] && printf "  (%s)" "$version_info"
            printf "\n"
        else
            printf "  %-10s MISSING\n" "$dep"
            all_ok=false
        fi
    done

    echo ""
    local encoders
    encoders=$(ffmpeg -encoders 2>/dev/null || true)
    if [[ "$encoders" == *libvpx-vp9* ]]; then
        local vpx_ver bits="8-bit only (no high bit depth)"
        # libvpx only reports its version while encoding — 1-frame null encode
        vpx_ver=$(ffmpeg -hide_banner -f lavfi -i "color=black:s=64x64:d=0.1" \
            -frames:v 1 -c:v libvpx-vp9 -f null - 2>&1 \
            | grep -oP '\[libvpx-vp9 @ [^]]*\] v\K[0-9][0-9a-z.-]*' | sed -n 1p) || true
        vp9_supports_10bit && bits="10-bit OK"
        echo "  libvpx-vp9 OK    (VP9 encoder available, ${bits}${vpx_ver:+, lib v$vpx_ver})"
    else
        echo "  libvpx-vp9 MISSING (ffmpeg was built without VP9 support)"
        all_ok=false
    fi
    if [[ "$encoders" == *libopus* ]]; then
        echo "  libopus    OK    (Opus audio encoder available)"
    else
        echo "  libopus    MISSING (needed unless every run uses --copy-audio)"
        all_ok=false
    fi

    echo ""
    if $all_ok; then
        echo "All dependencies satisfied."
    else
        echo "Some dependencies are missing. Install them before running conversions."
        exit 1
    fi
}

# ==============================================================================
# Usage
# ==============================================================================

usage() {
    cat <<'USAGE'
Usage: convert-to-vp9 [options] FILES[...]

OUTPUT:
  -o, --output-dir DIR          Store converted files in DIR (auto-created)
  --in-place                    Convert and replace in-place (default if no -o)

FILE MANAGEMENT:
  --smart, --keep-best-version  rm-src + rm-if-bigger + quality-check + best version
  --rm-source, --rm-src         Remove source if output is smaller
  --rm-if-bigger                Remove output if larger than source
  -y, --overwrite               Overwrite an existing output file
                                (default: skip it — makes re-runs resumable)

QUALITY:
  --max-res, --max-h HEIGHT     Scale down to HEIGHT px if source is taller
  --1080, --1080p               Alias for --max-res 1080
  --720, --720p                 Alias for --max-res 720
  --sd, --fast                  Fast encoding (cpu-used 5, crf 36)
  --hq                          High quality (cpu-used 1, crf 32, 2-pass,
                                tune-content film in place of film-grain 8)
  --cartoon                     Optimised for animation (no grain, higher CRF)
  --tv                          Optimised for TV/broadcasts (no grain, higher CRF,
                                cpu-used >= 5, single pass)
  --movie                       Optimised for cinema (grain retention via
                                tune-content film, lower CRF)
  --crf N                       VP9 CRF 0-63, lower = better quality (overrides
                                presets; always encoded with -b:v 0)
  --preset, --cpu-used N        libvpx-vp9 -cpu-used 0-8, lower = slower/better
                                (overrides presets)
  --2pass, --two-pass           Two-pass encode (analysis pass + final pass;
                                implied by --hq)
  --1pass, --one-pass           Force single-pass (overrides --hq's 2-pass)
                                VP9 has no film-grain synthesis: presets that
                                asked for it in AV1 map to -tune-content film
                                and print a warning (see README)
  --quality-check               SSIM check after conversion; reject if below threshold
  --min-ssim VALUE              Minimum SSIM score 0-1 (default: 0.92)
  --ssim-samples N              Evenly-spaced sample points for the check (default: 5)
  --verify                      Fully decode the output before accepting it
                                (catches corrupt bitstreams; costs one decode)

BATCH:
  --sort-by-size [asc|desc]     Sort files by size before processing (default: desc)
  --sort-by-date [asc|desc]     Sort files by mtime before processing (default:
                                desc = newest first)
  --sort-by-bitrate [asc|desc]  Sort files by overall bitrate (default: desc).
                                Costs one ffprobe per file. The three sort keys
                                are mutually exclusive, last one wins
  --dry-run                     Show what would be done without converting
  -r, --recursive               Recurse into subdirectories
  --min-size SIZE               Skip inputs smaller than SIZE (default: 128K;
                                0 disables). Output sanity checks stay on a
                                fixed internal 128K threshold regardless
  --min-bitrate RATE            Skip inputs thinner than RATE, decimal units
                                (1500k = 1 500 000 bit/s; 0 disables, default).
                                Costs one ffprobe per file. A file whose duration
                                cannot be read is kept, not dropped
  --exclude, --ignore PATTERN   Exclude files matching glob PATTERN, case-insensitive (repeatable)
                                codec:NAME excludes by video codec (codec:x265 = hevc, codec:x264 = h264)
  --skip-log[=FILE]             Log files not worth converting (low SSIM / output
                                larger) and skip them on re-runs. Default FILE:
                                .convert-skip.list at the input root
  --convert-av1                 Also re-encode AV1 sources (skipped by default,
                                like VP9 sources: AV1 is the more efficient codec)
  --no-early-abort              Don't abort if output is estimated larger
                                (in 2-pass mode evaluated during the final pass)
  --early-abort-threshold PCT   Progress % at which to evaluate (default: 15)
  --after CMD                   Run CMD after the batch completes

AUDIO:
  --copy-audio                  Keep original audio (no re-encoding)
  --opus                        Re-encode audio to Opus (conservative bitrates)
  --auto-audio                  Re-encode to Opus only if source bitrate > threshold (default)
  --audio-threshold KB/S        Bitrate threshold for auto mode (default: 200)
                                Already-Opus tracks are never re-encoded.

TRACKS (keep only selected languages; default keeps all):
  --langs LIST                  Keep only these languages for audio AND subs (e.g. fr,en)
  --audio-tracks LIST           Keep exactly these audio tracks, e.g. "a:0,a:2"
                                (audio-relative) or "1,3" (absolute stream index).
                                No heuristic: the caller decides. An unmatched
                                selector keeps every track rather than none
  --audio-langs LIST            Keep only these audio languages (e.g. fr,en)
  --sub-langs LIST              Keep only these subtitle languages (e.g. fr,en)
                                Untagged/undefined tracks are always kept.
  --copy-streams, --remux       Don't re-encode: just remux and keep selected
                                tracks (fast cleanup; pairs with --langs)

PROFILES:
  A '.convert-profile' file in a directory (or any parent) applies its flags
  to files under it — e.g. put '--movie' in a grainy-films folder, '--cartoon'
  in an animation folder. Resolved per file; one flag per line or space-separated;
  '#' starts a comment. Supports encoding/quality/audio/track flags (incl.
  --cpu-used, --2pass/--1pass, --convert-av1) plus
  --quality-check/--min-ssim/--ssim-samples, --verify, early-abort tuning,
  --no-merge-subs, --log and --skip-log (relative paths anchor to the profile's
  directory), plus --exclude (appends to CLI patterns), --min-size and
  --min-bitrate.
  --sort-by-size/--sort-by-date/--sort-by-bitrate are honored from the FIRST input root's
  profile only (ordering is batch-global). Destructive and output flags
  (--smart, --rm-*, -y, -o, ...) stay CLI-only. Precedence: flags typed on
  the command line win over the profile; the profile beats defaults.
  --no-profile                  Ignore all .convert-profile files

SUBTITLES:
  --no-merge-subs               Don't merge adjacent .srt/.vtt files into output

LOGGING:
  Space savings are shown per file (source -> output, bytes and %, freed now
  or pending until the source is deleted), live as an estimated final size,
  between files as a running total with ETA, and in the end-of-batch table.

  -l, --log FILE                Append a synthetic, greppable per-file log to FILE
                                (tab-separated: time, status, sizes, saved%, took, note)
  --stats FILE                  Summarise a --log file (counts, totals, SSIM) and exit
  --stats-live FILE             Same, but follow the log and refresh on change
                                (watch a running batch; Ctrl-C to quit)
  -v, --verbose                 Verbose output
  --no-progress                 Disable progress bar

OTHER:
  --check                        Check dependencies and exit
  -h, --help                    Show this help
  --version                     Show version
USAGE
}

# ==============================================================================
# Argument parsing
# ==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output-dir)
                need_arg "$1" "${2:-}"
                output_dir="$2"
                shift 2
                ;;
            --in-place)
                in_place=true
                shift
                ;;
            --smart|--keep-best-version)
                keep_best_version=true
                remove_source=true
                remove_if_bigger=true
                quality_check=true
                shift
                ;;
            --remove-source|--rm-source|--rm-src)
                remove_source=true
                shift
                ;;
            --remove-if-bigger|--rm-if-bigger)
                remove_if_bigger=true
                shift
                ;;
            --max-res|--max-h|--max-height)
                need_uint "$1" "${2:-}"
                max_res="$2"
                CLI_EXPLICIT[maxres]=1
                shift 2
                ;;
            --1080|--1080p)
                max_res="1080"
                CLI_EXPLICIT[maxres]=1
                shift
                ;;
            --720|--720p)
                max_res="720"
                CLI_EXPLICIT[maxres]=1
                shift
                ;;
            --sd|--fast)
                set_speed_fast
                CLI_EXPLICIT[speed]=1
                shift
                ;;
            --hq)
                set_speed_hq
                [[ "$audio_mode" == "auto" ]] && audio_mode="copy"
                CLI_EXPLICIT[speed]=1
                shift
                ;;
            --crf)
                need_uint "$1" "${2:-}"
                [[ "$2" -le 63 ]] || die "Option --crf expects 0-63 (VP9 CRF), got: $2"
                vp9_crf="$2"; vp9_crf_explicit=true
                CLI_EXPLICIT[crf]=1
                shift 2
                ;;
            --preset|--cpu-used)
                need_uint "$1" "${2:-}"
                [[ "$2" -le 8 ]] || die "Option $1 expects 0-8 (libvpx-vp9 -cpu-used; SVT-AV1 presets 9-13 have no VP9 equivalent), got: $2"
                vp9_cpu_used="$2"; vp9_cpu_used_explicit=true
                CLI_EXPLICIT[preset]=1
                shift 2
                ;;
            --2pass|--two-pass)
                vp9_two_pass=true; vp9_two_pass_explicit=true
                CLI_EXPLICIT[two_pass]=1
                shift
                ;;
            --1pass|--one-pass)
                vp9_two_pass=false; vp9_two_pass_explicit=true
                CLI_EXPLICIT[two_pass]=1
                shift
                ;;
            --convert-av1)
                convert_av1=true
                shift
                ;;
            --cartoon)
                content_type="cartoon"
                CLI_EXPLICIT[content]=1
                shift
                ;;
            --tv)
                content_type="tv"
                CLI_EXPLICIT[content]=1
                shift
                ;;
            --movie)
                content_type="movie"
                CLI_EXPLICIT[content]=1
                shift
                ;;
            --quality-check)
                quality_check=true
                shift
                ;;
            --verify)
                verify_output=true
                shift
                ;;
            --min-ssim)
                need_ssim "$1" "${2:-}"
                quality_check=true
                quality_min_ssim="$2"
                CLI_EXPLICIT[min_ssim]=1
                shift 2
                ;;
            --ssim-samples)
                need_uint "$1" "${2:-}"
                [[ "$2" -ge 1 ]] || die "Option --ssim-samples expects at least 1, got: $2"
                quality_check=true
                quality_samples="$2"
                CLI_EXPLICIT[ssim_samples]=1
                shift 2
                ;;
            -y|--overwrite)
                overwrite="-y"
                shift
                ;;
            --sort-by-size)
                if [[ "${2:-}" == "asc" || "${2:-}" == "desc" ]]; then
                    sort_by_size="$2"
                    shift 2
                else
                    sort_by_size="desc"
                    shift
                fi
                sort_by_date=""; sort_by_bitrate=""
                CLI_EXPLICIT[sort]=1
                ;;
            --sort-by-date)
                if [[ "${2:-}" == "asc" || "${2:-}" == "desc" ]]; then
                    sort_by_date="$2"
                    shift 2
                else
                    sort_by_date="desc"
                    shift
                fi
                sort_by_size=""; sort_by_bitrate=""
                CLI_EXPLICIT[sort]=1
                ;;
            --sort-by-bitrate)
                if [[ "${2:-}" == "asc" || "${2:-}" == "desc" ]]; then
                    sort_by_bitrate="$2"
                    shift 2
                else
                    sort_by_bitrate="desc"
                    shift
                fi
                sort_by_size=""; sort_by_date=""
                CLI_EXPLICIT[sort]=1
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            -r|--recursive)
                recursive=true
                shift
                ;;
            --min-size)
                need_arg "$1" "${2:-}"
                min_size=$(parse_size "$2")
                CLI_EXPLICIT[min_size]=1
                shift 2
                ;;
            --min-bitrate)
                need_arg "$1" "${2:-}"
                min_bitrate=$(parse_rate "$2")
                CLI_EXPLICIT[min_bitrate]=1
                shift 2
                ;;
            --exclude|--ignore)
                need_arg "$1" "${2:-}"
                exclude_patterns+=("$2")
                shift 2
                ;;
            --skip-log)
                skip_log_enabled=true
                CLI_EXPLICIT[skip_log]=1
                shift
                ;;
            --skip-log=*)
                skip_log_enabled=true
                skip_log_file="${1#*=}"
                CLI_EXPLICIT[skip_log]=1
                shift
                ;;
            --after)
                need_arg "$1" "${2:-}"
                after_cmd="$2"
                shift 2
                ;;
            --no-early-abort)
                early_abort=false
                shift
                ;;
            --early-abort-threshold)
                need_uint "$1" "${2:-}"
                [[ "$2" -ge 1 && "$2" -le 99 ]] \
                    || die "Option --early-abort-threshold expects 1-99, got: $2"
                early_abort_threshold="$2"
                CLI_EXPLICIT[early_abort_threshold]=1
                shift 2
                ;;
            --copy-audio)
                audio_mode="copy"
                CLI_EXPLICIT[audio_mode]=1
                shift
                ;;
            --opus)
                audio_mode="opus"
                CLI_EXPLICIT[audio_mode]=1
                shift
                ;;
            --auto-audio)
                audio_mode="auto"
                CLI_EXPLICIT[audio_mode]=1
                shift
                ;;
            --audio-threshold)
                need_uint "$1" "${2:-}"
                audio_bitrate_threshold="$2"
                audio_mode="auto"
                CLI_EXPLICIT[audio_threshold]=1
                CLI_EXPLICIT[audio_mode]=1
                shift 2
                ;;
            --no-merge-subs)
                merge_subs=false
                shift
                ;;
            --langs|--lang)
                need_arg "$1" "${2:-}"
                # Both audio and subs, unless a more specific flag already set one
                [[ -z "$audio_langs" ]] && audio_langs="$2"
                [[ -z "$sub_langs" ]] && sub_langs="$2"
                CLI_EXPLICIT[audio_langs]=1
                CLI_EXPLICIT[sub_langs]=1
                shift 2
                ;;
            --audio-tracks)
                need_arg "$1" "${2:-}"
                audio_tracks="$2"
                CLI_EXPLICIT[audio_tracks]=1
                shift 2
                ;;
            --audio-langs|--audio-lang)
                need_arg "$1" "${2:-}"
                audio_langs="$2"
                CLI_EXPLICIT[audio_langs]=1
                shift 2
                ;;
            --sub-langs|--sub-lang)
                need_arg "$1" "${2:-}"
                sub_langs="$2"
                CLI_EXPLICIT[sub_langs]=1
                shift 2
                ;;
            --copy-streams|--remux)
                copy_streams=true
                CLI_EXPLICIT[copy_streams]=1
                shift
                ;;
            --no-profile)
                use_profiles=false
                shift
                ;;
            -l|--log)
                need_arg "$1" "${2:-}"
                log_file="$2"
                CLI_EXPLICIT[log]=1
                shift 2
                ;;
            --stats)
                need_arg "$1" "${2:-}"
                print_log_stats "$2"
                exit 0
                ;;
            --stats-live|--live-stats)
                need_arg "$1" "${2:-}"
                print_log_stats_live "$2"
                exit 0
                ;;
            -v|--verbose)
                verbose=true
                shift
                ;;
            --no-progress)
                no_progress=true
                shift
                ;;
            --check)
                check_dependencies_verbose
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                echo "convert-to-vp9 v$VERSION"
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                input_args+=("$1")
                shift
                ;;
        esac
    done

    if [[ -n "$output_dir" && "$in_place" == true ]]; then
        die "--in-place and --output-dir are mutually exclusive"
    fi

    if [[ -z "$output_dir" ]]; then
        in_place=true
    fi

    if [[ ${#input_args[@]} -eq 0 ]]; then
        usage
        exit 1
    fi

    if [[ -n "$output_dir" ]]; then
        mkdir -p "$output_dir"
    fi

    # Default skip-log location: .convert-skip.list at the first input's root
    if $skip_log_enabled && [[ -z "$skip_log_file" ]]; then
        local root="${input_args[0]}"
        if [[ -d "$root" ]]; then
            skip_log_file="${root%/}/.convert-skip.list"
        else
            skip_log_file="$(dirname "$root")/.convert-skip.list"
        fi
    fi
}

# ==============================================================================
# File collection and sorting
# ==============================================================================

collect_and_sort_files() {
    local -n _result=$1
    local video_extensions="mp4|mkv|avi|mov|wmv|flv|ts|m2ts|mts|m4v|webm|mpg|mpeg"
    local collected=()

    for arg in "${input_args[@]}"; do
        if [[ -d "$arg" ]]; then
            local -a find_opts=("$arg")
            $recursive || find_opts+=(-maxdepth 1)
            find_opts+=(-type f -regextype posix-extended
                -iregex ".*\\.($video_extensions)" -print0)
            while IFS= read -r -d '' f; do
                collected+=("$f")
                (( ${#collected[@]} % 20 == 0 )) && scan_tick "scanning… ${#collected[@]} files found"
            done < <(find "${find_opts[@]}" 2>/dev/null)
        elif [[ -f "$arg" ]]; then
            collected+=("$arg")
        else
            warn "Not found: $arg"
            add_result "$arg" "NOTFOUND" 0 0 ""
        fi
    done

    local filtered=()
    local total_c=${#collected[@]} i=0
    for f in "${collected[@]+"${collected[@]}"}"; do
        i=$((i + 1))
        (( i % 20 == 0 || i == total_c )) && scan_tick "checking… ${i}/${total_c}"
        # Per-file profile BEFORE the filters: exclude/min-size/skip-log may
        # come from the file's own .convert-profile
        $use_profiles && resolve_file_profile "$f"
        if is_excluded "$f"; then
            debug "Excluded by pattern: $f"
            add_result "$f" "SKIPPED" 0 0 "excluded"
            continue
        fi
        if is_skip_logged "$f"; then
            debug "In skip-log (previously not worth converting): $f"
            add_result "$f" "SKIPPED" "$(get_file_size "$f")" 0 "in skip-log"
            continue
        fi
        if [[ "$min_size" -gt 0 ]]; then
            local fsz
            fsz=$(get_file_size "$f")
            if [[ "$fsz" -lt "$min_size" ]]; then
                debug "Skipped (too small: $(human_size "$fsz") < $(human_size "$min_size")): $f"
                add_result "$f" "SKIPPED" "$fsz" 0 "below min-size"
                continue
            fi
        fi
        if [[ "$min_bitrate" -gt 0 ]]; then
            local fbr
            fbr=$(file_bitrate "$f")
            # A file whose duration cannot be read keeps its place: refusing to
            # convert on a failed probe would silently drop the odd container.
            if [[ "$fbr" -gt 0 && "$fbr" -lt "$min_bitrate" ]]; then
                debug "Skipped (thin: ${fbr} < ${min_bitrate} bit/s): $f"
                add_result "$f" "SKIPPED" "$(get_file_size "$f")" 0 "below min-bitrate"
                continue
            fi
        fi
        filtered+=("$f")
    done
    scan_done
    collected=("${filtered[@]+"${filtered[@]}"}")

    # Sorting is batch-level: the list is global, so per-file profiles cannot
    # reorder it — only the CLI or the FIRST input root's profile decides
    if $use_profiles && [[ ${#input_args[@]} -gt 0 ]]; then
        local sort_root="${input_args[0]}"
        [[ -d "$sort_root" ]] && sort_root="${sort_root%/}/."
        resolve_file_profile "$sort_root"
    fi

    if [[ -n "$sort_by_size$sort_by_date$sort_by_bitrate" && ${#collected[@]} -gt 0 ]]; then
        local sort_flag="-n"
        [[ "$sort_by_size$sort_by_date$sort_by_bitrate" == "desc" ]] && sort_flag="-rn"

        local keyed_list=""
        for f in "${collected[@]}"; do
            local key
            if [[ -n "$sort_by_size" ]]; then
                key=$(get_file_size "$f")
            elif [[ -n "$sort_by_bitrate" ]]; then
                key=$(file_bitrate "$f")
            else
                key=$(stat -c %Y "$f" 2>/dev/null || echo 0)
            fi
            keyed_list+="${key} ${f}"$'\n'
        done

        _result=()
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _result+=("${line#* }")
        done < <(echo -n "$keyed_list" | sort "$sort_flag")
    else
        _result=("${collected[@]}")
    fi
}

# ==============================================================================
# Output path resolution
# ==============================================================================

# Return variables (avoids subshells)
RESOLVED_FINAL=""
RESOLVED_TEMP=""
RESOLVED_IS_TEMP=false

resolve_output_path() {
    local input_file="$1"
    local input_dir input_basename input_noext

    input_dir=$(dirname "$input_file")
    input_basename=$(basename "$input_file")
    input_noext="${input_basename%.*}"

    if $in_place; then
        RESOLVED_FINAL="${input_dir}/${input_noext}.mkv"
    else
        RESOLVED_FINAL="${output_dir}/${input_noext}.mkv"
    fi

    # The temp lives next to the final output: same filesystem = atomic mv
    local temp_dir
    if $in_place; then
        temp_dir="$input_dir"
    else
        temp_dir="$output_dir"
    fi
    RESOLVED_TEMP=$(mktemp "${temp_dir}/.convert-XXXXXX.mkv")
    RESOLVED_IS_TEMP=true
}

# ==============================================================================
# Track selection (mapping + language filtering)
# ==============================================================================

# Populated by compute_track_selection()
TRACKSEL_MAP_ARGS=()
TRACKSEL_COVER_POS=()   # output video-stream positions to copy verbatim (cover art)
TRACKSEL_AUDIO_IDX=()   # input indices of kept audio streams, in output order
TRACKSEL_SUB_IDX=()     # input indices of kept subtitle streams
declare -A TRACKSEL_AUDIO_CH=()    # input index -> channel count
declare -A TRACKSEL_AUDIO_BR=()    # input index -> bitrate (bit/s)
declare -A TRACKSEL_AUDIO_CODEC=() # input index -> codec name
declare -A TRACKSEL_AUDIO_BR_EST=() # input index -> 1 if bitrate is packet-sampled
declare -A TRACKSEL_SUB_CODEC=()    # input index -> subtitle codec name
TRACKSEL_A_TOTAL=0
TRACKSEL_A_KEPT=0
TRACKSEL_S_TOTAL=0
TRACKSEL_S_KEPT=0
TRACKSEL_AUDIO_FALLBACK=false

# Stream mapping: -map 0 without a language filter; explicit per-index maps
# otherwise (video/attachments/data always kept). Also flags cover-art video
# positions and gathers per-audio channels/bitrate/codec for the encode.
compute_track_selection() {
    local input="$1"

    TRACKSEL_MAP_ARGS=()
    TRACKSEL_COVER_POS=()
    TRACKSEL_AUDIO_IDX=()
    TRACKSEL_SUB_IDX=()
    TRACKSEL_AUDIO_CH=()
    TRACKSEL_AUDIO_BR=()
    TRACKSEL_AUDIO_CODEC=()
    TRACKSEL_AUDIO_BR_EST=()
    TRACKSEL_SUB_CODEC=()
    TRACKSEL_A_TOTAL=0 TRACKSEL_A_KEPT=0 TRACKSEL_S_TOTAL=0 TRACKSEL_S_KEPT=0
    TRACKSEL_AUDIO_FALLBACK=false

    local filtering=false
    [[ -n "$audio_langs" || -n "$sub_langs" || -n "$audio_tracks" ]] && filtering=true

    probe_load "$input"

    local -a kept_audio=() kept_sub=() all_audio=()
    local vpos=0
    local idx ctype lang ach abr acodec this_kept
    while IFS=$'\t' read -r idx ctype _ lang ach abr acodec; do
        [[ -z "$idx" ]] && continue
        # "-" is the TSV empty-field placeholder (tabs collapse under IFS=tab)
        [[ "$lang"   == "-" ]] && lang=""
        [[ "$acodec" == "-" ]] && acodec=""
        case "$ctype" in
            video)
                # Any video stream past the first is a cover/thumbnail — the
                # attached_pic flag is not always set, so position decides
                [[ "$vpos" -ge 1 ]] && TRACKSEL_COVER_POS+=("$vpos")
                vpos=$((vpos + 1))
                ;;
            audio)
                TRACKSEL_A_TOTAL=$((TRACKSEL_A_TOTAL + 1))
                all_audio+=("$idx")
                this_kept=false
                if [[ -z "$audio_langs" ]] || lang_matches "$lang" "$audio_langs"; then
                    kept_audio+=("$idx")
                    TRACKSEL_A_KEPT=$((TRACKSEL_A_KEPT + 1))
                    this_kept=true
                fi
                [[ "$ach" =~ ^[0-9]+$ ]] || ach=2
                abr="${abr//[!0-9]/}"
                # No container bitrate (common in MKV): measure real packets
                # instead of letting auto mode treat the track as 0 kb/s
                if [[ -z "$abr" || "$abr" -eq 0 ]] && $this_kept \
                   && [[ "$audio_mode" == "auto" ]] && ! $copy_streams; then
                    abr=$(estimate_stream_bitrate "$input" "$idx")
                    [[ "$abr" -gt 0 ]] && TRACKSEL_AUDIO_BR_EST[$idx]=1
                fi
                TRACKSEL_AUDIO_CH[$idx]="$ach"
                TRACKSEL_AUDIO_BR[$idx]="${abr:-0}"
                TRACKSEL_AUDIO_CODEC[$idx]="$acodec"
                ;;
            subtitle)
                TRACKSEL_S_TOTAL=$((TRACKSEL_S_TOTAL + 1))
                TRACKSEL_SUB_CODEC[$idx]="$acodec"
                if [[ -z "$sub_langs" ]] || lang_matches "$lang" "$sub_langs"; then
                    kept_sub+=("$idx")
                    TRACKSEL_S_KEPT=$((TRACKSEL_S_KEPT + 1))
                fi
                ;;
        esac
    done <<< "$PROBE_STREAMS_TSV"

    if [[ -n "$audio_tracks" ]]; then
        local -a picked=()
        local sel n
        for sel in ${audio_tracks//,/ }; do
            case "$sel" in
                a:*) n="${sel#a:}"
                     [[ "$n" =~ ^[0-9]+$ && -n "${all_audio[$n]:-}" ]] && picked+=("${all_audio[$n]}") ;;
                *)   [[ "$sel" =~ ^[0-9]+$ ]] || continue
                     local a
                     for a in "${all_audio[@]+"${all_audio[@]}"}"; do
                         [[ "$a" == "$sel" ]] && picked+=("$sel")
                     done ;;
            esac
        done
        if [[ ${#picked[@]} -eq 0 ]]; then
            # Never produce a silent file because a selector was mistyped
            warn "No audio track matched [${audio_tracks}] — keeping all audio: $(basename "$input")"
            TRACKSEL_AUDIO_FALLBACK=true
        else
            kept_audio=("${picked[@]}")
            TRACKSEL_A_KEPT=${#picked[@]}
        fi
    fi

    TRACKSEL_SUB_IDX=("${kept_sub[@]+"${kept_sub[@]}"}")

    if ! $filtering; then
        TRACKSEL_MAP_ARGS=(-map 0)
        TRACKSEL_AUDIO_IDX=("${all_audio[@]+"${all_audio[@]}"}")
        return
    fi

    TRACKSEL_MAP_ARGS=(-map 0:v)

    if [[ -n "$audio_langs" || -n "$audio_tracks" ]]; then
        if [[ "$TRACKSEL_A_TOTAL" -gt 0 && "$TRACKSEL_A_KEPT" -eq 0 ]] || $TRACKSEL_AUDIO_FALLBACK; then
            # Safety net: never produce a file with no audio
            TRACKSEL_AUDIO_FALLBACK=true
            TRACKSEL_A_KEPT="$TRACKSEL_A_TOTAL"
            TRACKSEL_MAP_ARGS+=(-map "0:a?")
            TRACKSEL_AUDIO_IDX=("${all_audio[@]+"${all_audio[@]}"}")
        else
            local i
            for i in "${kept_audio[@]+"${kept_audio[@]}"}"; do
                TRACKSEL_MAP_ARGS+=(-map "0:$i")
            done
            TRACKSEL_AUDIO_IDX=("${kept_audio[@]+"${kept_audio[@]}"}")
        fi
    else
        TRACKSEL_MAP_ARGS+=(-map "0:a?")
        TRACKSEL_AUDIO_IDX=("${all_audio[@]+"${all_audio[@]}"}")
    fi

    if [[ -n "$sub_langs" ]]; then
        local i
        for i in "${kept_sub[@]+"${kept_sub[@]}"}"; do
            TRACKSEL_MAP_ARGS+=(-map "0:$i")
        done
    else
        TRACKSEL_MAP_ARGS+=(-map "0:s?")
    fi

    # Attachments (subtitle fonts) and data streams
    TRACKSEL_MAP_ARGS+=(-map "0:t?" -map "0:d?")
}

# Subtitle codecs Matroska cannot store, and the text codec that replaces
# them. mov_text (MP4 timed text) is the common case: copied as-is the muxer
# rejects the header and the whole file fails. Empty = copy unchanged.
mkv_sub_target() {
    case "$1" in
        mov_text) echo "srt" ;;
        *)        echo "" ;;
    esac
}

# Per-subtitle codec overrides for the kept embedded subs. Output subtitle
# order == TRACKSEL_SUB_IDX order (-map 0 and the per-index maps both keep
# input order); sidecar .srt/.vtt inputs come after and are left alone.
append_sub_codec_fixes() {
    local -n _sc=$1
    local j=0 sidx tgt
    for sidx in "${TRACKSEL_SUB_IDX[@]+"${TRACKSEL_SUB_IDX[@]}"}"; do
        tgt=$(mkv_sub_target "${TRACKSEL_SUB_CODEC[$sidx]:-}")
        if [[ -n "$tgt" ]]; then
            _sc+=(-c:s:"$j" "$tgt")
            debug "Subtitle stream $sidx (${TRACKSEL_SUB_CODEC[$sidx]}) -> $tgt (not storable in MKV)"
        fi
        j=$((j + 1))
    done
}

# ==============================================================================
# Build ffmpeg command
# ==============================================================================

# Video encode arguments for the main stream (v:0), shared by the final pass
# and the 2-pass analysis pass so both see identical settings. $3 = quiet
# (no info lines — the analysis pass must not repeat them).
append_vp9_video_args() {
    local input="$1"
    local -n _va=$2
    local quiet="${3:-false}"

    # HDR sources must carry their colour metadata explicitly — untagged HDR
    # plays back washed-out (VP9 codes only the matrix in the bitstream;
    # transfer/primaries live in the MKV Colour element, set from these).
    # SDR with invalid/missing metadata gets tagged BT.709.
    probe_load "$input"
    local color_matrix="${PROBE_V0_COLOR_SPACE%%,*}"
    local color_trc="${PROBE_V0_COLOR_TRC%%,*}"
    if [[ "$color_trc" == "smpte2084" || "$color_trc" == "arib-std-b67" ]]; then
        _va+=(-colorspace "${color_matrix:-bt2020nc}" \
               -color_primaries "${PROBE_V0_COLOR_PRIMARIES:-bt2020}" \
               -color_trc "$color_trc")
        $quiet || info "  HDR source (${color_trc}) — colour metadata preserved"
    elif [[ -z "$color_matrix" || "$color_matrix" == "unknown" || "$color_matrix" == "reserved" || "$color_matrix" == "gbr" ]]; then
        _va+=(-colorspace bt709 -color_primaries bt709 -color_trc bt709)
        $quiet || debug "Fixing invalid/missing color metadata -> BT.709"
    fi

    local -a vp9_opts
    read -ra vp9_opts <<< "$vp9_options"
    _va+=(-c:v libvpx-vp9 "${vp9_opts[@]}")

    # Scale only the main stream (v:0), never the cover art
    local height width out_w
    height=$(get_video_height "$input")
    width=$(get_video_width "$input")
    out_w="$width"
    if [[ -n "$max_res" && "$height" -gt "$max_res" ]]; then
        _va+=(-filter:v:0 "scale=-2:${max_res}")
        $quiet || info "  Scaling: ${height}p -> ${max_res}p"
        out_w=$(( width * max_res / height ))
    fi
    _va+=(-tile-columns:v:0 "$(vp9_tile_columns "$out_w")")
}

# 2-pass analysis run: main video only, no output file (stats go to PASSLOG)
build_pass1_cmd() {
    local input="$1"
    local passlog="$2"
    local -n _p1=$3

    _p1=(ffmpeg -hide_banner)
    if is_mpeg_ts "$input"; then
        _p1+=(-fflags +genpts+igndts+discardcorrupt -avoid_negative_ts make_zero -err_detect ignore_err)
    fi
    _p1+=(-i "$input" -y -map 0:v:0)
    append_vp9_video_args "$input" _p1 true
    _p1+=(-pass 1 -passlogfile "$passlog" -an -sn -dn)
    _p1+=(-progress pipe:1 -nostats -f null /dev/null)
}

build_ffmpeg_cmd() {
    local input="$1"
    local output="$2"
    local -n _cmd=$3
    local passlog="${4:-}"   # set = final pass of a 2-pass encode

    _cmd=(ffmpeg -hide_banner)

    if is_mpeg_ts "$input"; then
        _cmd+=(-fflags +genpts+igndts+discardcorrupt -avoid_negative_ts make_zero -err_detect ignore_err)
        debug "MPEG-TS detected, applying timestamp fix flags"
    fi

    _cmd+=(-i "$input")

    if $merge_subs; then
        local sub_files
        sub_files=$(find_subtitle_files "$input")
        local sub_count=0
        while IFS= read -r sub_file; do
            [[ -z "$sub_file" ]] && continue
            _cmd+=(-i "$sub_file")
            sub_count=$((sub_count + 1))
            debug "Merging subtitle: $sub_file"
        done <<< "$sub_files"
    fi

    # -y at ffmpeg level: the mktemp target must be overwritable — the script
    # handles output-exists logic itself, upstream
    _cmd+=(-y)

    compute_track_selection "$input"
    if $TRACKSEL_AUDIO_FALLBACK; then
        warn "No audio track matched languages [${audio_langs}] — keeping all audio: $(basename "$input")"
    fi
    _cmd+=("${TRACKSEL_MAP_ARGS[@]}" -map_metadata 0 -map_chapters 0)

    if $merge_subs && [[ "${sub_count:-0}" -gt 0 ]]; then
        for ((si = 1; si <= sub_count; si++)); do
            _cmd+=(-map "$si")
        done
    fi

    local desc_file
    desc_file=$(find_description_file "$input")
    if [[ -n "$desc_file" ]]; then
        local desc_content
        desc_content=$(cat "$desc_file")
        _cmd+=(-metadata "description=${desc_content}")
        debug "Embedding description from: $desc_file"
    fi

    if $copy_streams; then
        [[ -n "$max_res" ]] && warn "--copy-streams ignores --max-res (no video re-encode)"
        _cmd+=(-c copy)
        append_sub_codec_fixes _cmd
        info "  Remux only: copying all kept streams (no re-encode)"
        _cmd+=(-max_muxing_queue_size 4096 -progress pipe:1 -nostats "$output")
        return
    fi

    # Main video to VP9; cover streams copied verbatim — a single-frame
    # attached_pic must stay the image it is, not become a 1-frame video
    append_vp9_video_args "$input" _cmd
    if [[ -n "$passlog" ]]; then
        _cmd+=(-pass 2 -passlogfile "$passlog")
    fi
    local cpos
    for cpos in "${TRACKSEL_COVER_POS[@]+"${TRACKSEL_COVER_POS[@]}"}"; do
        _cmd+=(-c:v:"$cpos" copy)
        debug "Copying cover art (output video stream $cpos) instead of encoding"
    done

    # Per-stream audio codec; no global -ac, so libopus never downmixes 5.1/7.1
    local aj=0
    local a_idx a_ch opus_br
    for a_idx in "${TRACKSEL_AUDIO_IDX[@]+"${TRACKSEL_AUDIO_IDX[@]}"}"; do
        a_ch="${TRACKSEL_AUDIO_CH[$a_idx]:-2}"
        if [[ "$(audio_stream_action "$a_idx")" == "opus" ]]; then
            opus_br=$(get_opus_bitrate "$a_ch")
            _cmd+=(-c:a:"$aj" libopus -b:a:"$aj" "$opus_br")
            local a_layout
            a_layout=$(opus_channel_layout "$a_ch")
            [[ -n "$a_layout" ]] && _cmd+=(-filter:a:"$aj" "aformat=channel_layouts=$a_layout")
        else
            _cmd+=(-c:a:"$aj" copy)
        fi
        aj=$((aj + 1))
    done

    # Copy other non-audio/video streams
    _cmd+=(-c:s copy)
    append_sub_codec_fixes _cmd

    _cmd+=(-max_muxing_queue_size 4096)
    _cmd+=(-progress pipe:1 -nostats)

    _cmd+=("$output")
}

# ==============================================================================
# Progress monitor + early abort
# ==============================================================================

run_progress_monitor() {
    local duration="$1"
    local start_time="$2"
    local temp_file="$3"
    local input_size="$4"
    local pid_file="${5:-}"
    local abort_signal="${6:-}"
    local total_frames="${7:-0}"
    local pass_label="${8:-}"   # "pass 1/2" (analysis, no output) / "pass 2/2"
    local abort_checked=false

    local out_time_sec=0 fps_val=0 cur_frame=0
    local tag=""
    [[ -n "$pass_label" ]] && tag="${pass_label} "

    if ! $no_progress; then
        printf "\r  %s[  0%%] [------------------------------] working..." "$tag"
    fi

    while IFS='=' read -r key val; do
        case "$key" in
            out_time_us)
                [[ -n "$val" && "$val" != "N/A" ]] && out_time_sec=$((val / 1000000))
                ;;
            frame)
                [[ "$val" =~ ^[0-9]+$ ]] && cur_frame="$val"
                ;;
            fps)
                fps_val="${val:-0}"
                ;;
            progress)
                if [[ "$val" == "end" ]]; then
                    clear_line
                    local what="Conversion"
                    [[ "$pass_label" == "pass 1/"* ]] && what="Analysis (pass 1/2)"
                    local done_secs=$(( $(date +%s) - start_time ))
                    if [[ "$done_secs" -gt 0 && "$duration" -gt 0 ]]; then
                        local sp10=$(( duration * 10 / done_secs )) fps_avg=""
                        if [[ "$cur_frame" -gt 0 ]]; then
                            local fa10=$(( cur_frame * 10 / done_secs ))
                            fps_avg="avg $((fa10 / 10)).$((fa10 % 10)) fps, "
                        fi
                        info "  ${what} done in $(format_duration "$done_secs") (${fps_avg}$((sp10 / 10)).$((sp10 % 10))x)."
                    else
                        info "  ${what} done."
                    fi
                fi
                continue
                ;;
            *)
                continue
                ;;
        esac

        [[ "$key" != "out_time_us" && "$key" != "frame" ]] && continue

        # Position: real out_time when available; in -c copy mode ffmpeg
        # reports N/A there, so fall back to the muxed-frame fraction
        local pos_sec=0
        if [[ "$out_time_sec" -gt 0 ]]; then
            pos_sec="$out_time_sec"
        elif [[ "$total_frames" -gt 0 && "$cur_frame" -gt 0 ]]; then
            pos_sec=$(( cur_frame * duration / total_frames ))
        fi
        [[ "$duration" -le 0 || "$pos_sec" -le 0 ]] && continue

        local now elapsed speed_x progress_pct
        now=$(date +%s)
        elapsed=$((now - start_time))
        [[ "$elapsed" -le 0 ]] && continue

        # Fixed-point tenths — this path redraws every second, keep it fork-free
        local speed_t=$(( pos_sec * 10 / elapsed ))
        speed_x="$((speed_t / 10)).$((speed_t % 10))"
        progress_pct=$(( (pos_sec * 100) / duration ))
        [[ "$progress_pct" -gt 100 ]] && progress_pct=100

        local eta_str="?"
        if [[ "$pos_sec" -gt 0 && "$duration" -gt "$pos_sec" ]]; then
            eta_str=$(format_duration $(( (duration - pos_sec) * elapsed / pos_sec )))
        elif [[ "$pos_sec" -ge "$duration" ]]; then
            eta_str=$(format_duration 0)
        fi

        # Early abort is gated on real-timestamp progress only — the frame-count
        # fallback is too coarse to base a size extrapolation on
        local time_pct=0
        [[ "$out_time_sec" -gt 0 ]] && time_pct=$(( out_time_sec * 100 / duration ))
        if $early_abort && ! $abort_checked && \
           [[ "$time_pct" -ge "$early_abort_threshold" ]] && \
           ($remove_if_bigger || $keep_best_version); then

            local current_output_size estimated_final_size

            if [[ -f "$temp_file" ]]; then
                current_output_size=$(get_file_size "$temp_file")
                if [[ "$current_output_size" -le 0 ]]; then
                    : # ffmpeg has not flushed yet — retry on the next update
                elif [[ "$out_time_sec" -gt 0 ]]; then
                    abort_checked=true
                    estimated_final_size=$(( current_output_size * duration / out_time_sec ))
                    if [[ "$estimated_final_size" -ge "$input_size" ]]; then
                        clear_line
                        warn "Early abort: estimated output $(human_size "$estimated_final_size") >= input $(human_size "$input_size") (at ${progress_pct}%)"
                        # Signal the parent (subshell cannot set its variables)
                        [[ -n "$abort_signal" ]] && touch "$abort_signal"
                        if [[ -n "$pid_file" && -f "$pid_file" ]]; then
                            local ffmpeg_pid
                            ffmpeg_pid=$(cat "$pid_file" 2>/dev/null || echo "")
                            if [[ -n "$ffmpeg_pid" ]]; then kill "$ffmpeg_pid" 2>/dev/null || true; fi
                        fi

                        return 0
                    fi
                fi
            fi
        fi

        # -- Progress bar -----------------------------------------------------
        if ! $no_progress; then
            local filled empty bar current_time total_time
            filled=$(( progress_pct * 30 / 100 ))
            empty=$(( 30 - filled ))
            bar=$(printf "%${filled}s" | tr ' ' '#')$(printf "%${empty}s" | tr ' ' '-')

            current_time=$(format_duration "$pos_sec")
            total_time=$(format_duration "$duration")

            # Live estimate of the final size: muxed bytes so far, extrapolated
            # over the duration (MKV writes as it goes; no output in pass 1)
            local extra_str=""
            if [[ -n "$temp_file" && -f "$temp_file" && "$pos_sec" -gt 0 ]]; then
                local cur_sz out_br_kbps
                cur_sz=$(stat -c %s "$temp_file" 2>/dev/null || echo 0)
                out_br_kbps=$(( cur_sz * 8 / pos_sec / 1000 ))
                extra_str=" | ${out_br_kbps}kb/s"
                if [[ "$input_size" -gt 0 && "$cur_sz" -gt 0 ]]; then
                    local est_sz saving_pct cmp_color
                    est_sz=$(( cur_sz * duration / pos_sec ))
                    saving_pct=$(( (input_size - est_sz) * 100 / input_size ))
                    if [[ "$saving_pct" -ge 0 ]]; then
                        cmp_color="$GREEN"
                        extra_str+=" | ${cmp_color}est. $(human_size "$est_sz") saved=${saving_pct}%${NC}"
                    else
                        cmp_color="$RED"
                        extra_str+=" | ${cmp_color}est. $(human_size "$est_sz") larger=+$(( -saving_pct ))%${NC}"
                    fi
                fi
            fi

            printf "\r  %s[%3d%%] [%s] %s/%s | fps: %s %sx | ETA: %s%b  " \
                "$tag" "$progress_pct" "$bar" "$current_time" "$total_time" \
                "$fps_val" "$speed_x" "$eta_str" "$extra_str"
        fi

    done
}

# ==============================================================================
# Per-file header
# ==============================================================================

# The per-file block: "▸ [n/N] name SIZE [profile]", stream table, target.
# Shared by real runs and --dry-run. Side effect: runs compute_track_selection
# (stream_dispositions needs it).
print_file_header() {
    local input_file="$1" input_size="$2" final_output="$3"
    local input_dir_h input_basename_h
    input_dir_h=$(dirname "$input_file")
    input_basename_h=$(basename "$input_file")

    local ctr="" src_disp prof=""
    [[ "$FILES_TOTAL" -gt 1 ]] && ctr="${GRAY}[${FILES_PROCESSED}/${FILES_TOTAL}]${NC} "
    if [[ "$input_dir_h" == "." ]]; then
        src_disp="${BOLD}${input_basename_h}${NC}"
    else
        src_disp="${GRAY}${input_dir_h}/${NC}${BOLD}${input_basename_h}${NC}"
    fi
    [[ -n "$CURRENT_PROFILE_PRESETS" ]] && prof="  ${ORANGE}[${CURRENT_PROFILE_PRESETS}]${NC}"
    echo -e "${GREEN}▸${NC} ${ctr}${src_disp}   ${BOLD}${ORANGE}$(human_size "$input_size")${NC}${prof}"

    local sidecars=""
    if $merge_subs; then
        local ext_subs sf
        ext_subs=$(find_subtitle_files "$input_file")
        while IFS= read -r sf; do
            [[ -z "$sf" ]] && continue
            sidecars+="sub"$'\t'"$(basename "$sf")"$'\n'
        done <<< "$ext_subs"
    fi
    local ext_desc
    ext_desc=$(find_description_file "$input_file")
    [[ -n "$ext_desc" ]] && sidecars+="txt"$'\t'"$(basename "$ext_desc")"$'\n'

    compute_track_selection "$input_file"
    print_file_info "$input_file" "$(stream_dispositions)" "$sidecars"
    echo -e "  ${GRAY}→${NC} ${final_output}"
}

# ==============================================================================
# Convert a single file
# ==============================================================================

convert_file() {
    local input_file="$1"

    FILES_PROCESSED=$((FILES_PROCESSED + 1))
    LAST_ENCODE_SECS=0
    LAST_SSIM=""
    LAST_INPUT_SIZE=0

    # -- Pre-checks ------------------------------------------------------------
    if [[ ! -f "$input_file" ]]; then
        warn "File not found: $input_file"
        add_result "$input_file" "NOTFOUND" 0 0 ""
        return 0
    fi

    local input_size
    input_size=$(get_file_size "$input_file")
    LAST_INPUT_SIZE="$input_size"
    if [[ "$input_size" -eq 0 ]]; then
        warn "Empty file: $input_file"
        add_result "$input_file" "SKIPPED" 0 0 "empty file"
        return 0
    fi

    # Profile resolution comes before the VP9/AV1 skip: a profile may enable
    # --copy-streams, and remux mode must still clean already-VP9/AV1 files
    resolve_file_profile "$input_file"

    # Re-check after profile resolution: a profile-activated skip list is not
    # known at collection time (CLI lists were already filtered there)
    if is_skip_logged "$input_file"; then
        info "  In skip-log (previously not worth converting), skipping: $input_file"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "in skip-log"
        return 0
    fi

    if ! $copy_streams && is_vp9 "$input_file"; then
        info "  Already VP9, skipping: $input_file"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "already VP9"
        return 0
    fi
    # AV1 is the more efficient codec: re-encoding it to VP9 nearly always
    # grows the file and costs a generation — opt-in only
    if ! $copy_streams && ! $convert_av1 && is_av1 "$input_file"; then
        info "  Already AV1 (more efficient than VP9), skipping: $input_file"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "already AV1"
        return 0
    fi

    # -- Final output path (no temp files yet) ----------------------------------
    local input_dir_r input_basename_r input_noext_r final_output
    input_dir_r=$(dirname "$input_file")
    input_basename_r=$(basename "$input_file")
    input_noext_r="${input_basename_r%.*}"
    if $in_place; then
        final_output="${input_dir_r}/${input_noext_r}.mkv"
    else
        final_output="${output_dir}/${input_noext_r}.mkv"
    fi

    # -- Output-name collision guard (foo.mp4 + foo.avi -> foo.mkv) -------------
    local claimant="${CLAIMED_OUTPUTS[$final_output]:-}"
    if [[ -n "$claimant" && "$claimant" != "$input_file" ]]; then
        warn "Output collision: $final_output already produced from $claimant — skipping: $input_file"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "output name collision"
        return 0
    fi
    CLAIMED_OUTPUTS[$final_output]="$input_file"

    # Existing outputs are only overwritten with -y; in-place .mkv -> .mkv
    # (target == source) is always allowed. input_canon rebuilds the source
    # path the same way final_output was built ("rich.mkv" vs "./rich.mkv").
    local input_canon="${input_dir_r}/${input_basename_r}"
    local output_exists=false
    if [[ -f "$final_output" && "$final_output" != "$input_canon" && -z "$overwrite" ]]; then
        output_exists=true
    fi

    # -- Dry run: real header block + one note line for the rest ----------------
    if $dry_run; then
        echo ""
        print_file_header "$input_file" "$input_size" "$final_output"
        local notes=""
        is_mpeg_ts "$input_file" && notes+=" [MPEG-TS fix]"
        if [[ -n "$max_res" ]]; then
            local h_dr
            h_dr=$(get_video_height "$input_file")
            [[ "$h_dr" -gt "$max_res" ]] && notes+=" [scale ${h_dr}p -> ${max_res}p]"
        fi
        $copy_streams && notes+=" [remux]"
        $TRACKSEL_AUDIO_FALLBACK && notes+=" [no audio matched '${audio_langs}' — keeping all]"
        $output_exists && notes+=" [target exists — will be skipped without -y]"
        [[ -n "$notes" ]] && echo -e "  ${ORANGE}${notes# }${NC}"
        add_result "$input_file" "DRYRUN" "$input_size" 0 ""
        return 0
    fi

    if $output_exists; then
        info "  Output exists, skipping (use -y to overwrite): $final_output"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "output exists (no -y)"
        return 0
    fi

    # -- Disk space guard --------------------------------------------------------
    # The temp can grow to ~input size; skipping now beats ffmpeg dying on
    # ENOSPC an hour in. Unknown free space never blocks.
    local dest_dir free_bytes
    $in_place && dest_dir="$input_dir_r" || dest_dir="$output_dir"
    free_bytes=$(get_free_space "$dest_dir")
    if [[ -n "$free_bytes" && "$free_bytes" -lt "$input_size" ]]; then
        warn "Insufficient free space on target (need ~$(human_size "$input_size"), have $(human_size "$free_bytes")): skipping $input_file"
        add_result "$input_file" "SKIPPED" "$input_size" 0 "insufficient disk space"
        return 0
    fi

    # -- Lock ------------------------------------------------------------------
    if ! acquire_lock "$input_file"; then
        add_result "$input_file" "LOCKED" "$input_size" 0 "locked"
        return 0
    fi

    # -- Header ----------------------------------------------------------------
    echo ""
    # Batch progress above the file header — a batch-level note, not part of
    # the next file's block. The ETA is byte-based and firms up over the run.
    if [[ "$FILES_TOTAL" -gt 1 && "$FILES_PROCESSED" -gt 1 ]]; then
        print_batch_progress
        echo ""
    fi
    print_file_header "$input_file" "$input_size" "$final_output"

    # -- Resolve output path (creates the temp file) ----------------------------
    resolve_output_path "$input_file"
    final_output="$RESOLVED_FINAL"
    local temp_output="$RESOLVED_TEMP"
    local is_temp="$RESOLVED_IS_TEMP"

    # -- Build ffmpeg command(s) -----------------------------------------------
    # 2-pass: the stats file lives under the convert-$$- prefix, so cleanup()
    # removes it on any exit (ffmpeg appends "-0.log")
    local passlog=""
    if $vp9_two_pass && ! $copy_streams; then
        passlog=$(mktemp -u "${TMPDIR:-/tmp}/convert-${$}-2pass-XXXXXX")
    fi
    local -a cmd pass1_cmd=()
    build_ffmpeg_cmd "$input_file" "$temp_output" cmd "$passlog"
    [[ -n "$passlog" ]] && build_pass1_cmd "$input_file" "$passlog" pass1_cmd

    [[ -n "$passlog" ]] && debug "CMD (pass 1): ${pass1_cmd[*]}"
    debug "CMD: ${cmd[*]}"

    # Source timestamps, saved before the in-place mv can overwrite them
    local ts_ref=""
    ts_ref=$(mktemp "${TMPDIR:-/tmp}/convert-${$}-tsref-XXXXXX") || true
    touch -r "$input_file" "$ts_ref" 2>/dev/null || true
    # Permissions too: the output is born from mktemp (0600), which hides it
    # from a media server running as another user
    chmod --reference="$input_file" "$ts_ref" 2>/dev/null || true

    # -- Run conversion --------------------------------------------------------
    local duration
    duration=$(get_duration_secs "$input_file")
    local total_frames
    total_frames=$(get_total_frames "$input_file" "$duration")
    local start_time
    start_time=$(date +%s)

    CURRENT_TEMP_FILE="$temp_output"
    EARLY_ABORTED=false
    SKIP_REQUESTED=false

    local stderr_log=""
    stderr_log=$(mktemp "${TMPDIR:-/tmp}/convert-${$}-stderr-XXXXXX.log") || true
    CURRENT_STDERR_LOG="$stderr_log"

    # PID tracking and abort/skip signalling go through temp files — the
    # monitor runs in a pipe subshell and cannot set parent variables
    local pid_file="" abort_signal="" skip_signal=""
    pid_file=$(mktemp "${TMPDIR:-/tmp}/convert-${$}-pid-XXXXXX") || true
    abort_signal=$(mktemp -u "${TMPDIR:-/tmp}/convert-${$}-abort-XXXXXX")
    skip_signal=$(mktemp -u "${TMPDIR:-/tmp}/convert-${$}-skip-XXXXXX")

    # Key reader for ">" (skip file) — forked from the main shell, not the pipe
    local key_reader_pid=""
    if [[ -t 2 ]] && ! $no_progress; then
        local tty_saved
        tty_saved=$(stty -g < /dev/tty 2>/dev/null || true)
        stty -icanon -echo < /dev/tty 2>/dev/null || true
        (
            trap 'exit 0' TERM
            while true; do
                local ch=""
                if IFS= read -rsn1 ch < /dev/tty 2>/dev/null; then
                    if [[ "$ch" == ">" ]]; then
                        touch "$skip_signal"
                        local fpid
                        fpid=$(cat "$pid_file" 2>/dev/null || echo "")
                        if [[ -n "$fpid" ]]; then kill "$fpid" 2>/dev/null || true; fi
                        exit 0
                    fi
                fi
            done
        ) &
        key_reader_pid=$!
    fi

    local ffmpeg_exit=0
    if [[ -n "$passlog" ]]; then
        # Analysis pass: no output file, so no size estimate and no early abort
        { "${pass1_cmd[@]}" 2>"$stderr_log" & echo $! > "$pid_file"; wait $!; } \
            | run_progress_monitor "$duration" "$start_time" "" "$input_size" "$pid_file" "" "$total_frames" "pass 1/2" \
            || ffmpeg_exit="${PIPESTATUS[0]}"
    fi
    if [[ "$ffmpeg_exit" -eq 0 && ! -f "$skip_signal" ]]; then
        local pass_start
        pass_start=$(date +%s)
        { "${cmd[@]}" 2>>"$stderr_log" & echo $! > "$pid_file"; wait $!; } \
            | run_progress_monitor "$duration" "$pass_start" "$temp_output" "$input_size" "$pid_file" "$abort_signal" "$total_frames" "${passlog:+pass 2/2}" \
            || ffmpeg_exit="${PIPESTATUS[0]}"
    fi
    [[ -n "$passlog" ]] && rm -f "${passlog}"*

    if [[ -n "$key_reader_pid" ]]; then
        kill "$key_reader_pid" 2>/dev/null || true
        wait "$key_reader_pid" 2>/dev/null || true
        stty "$tty_saved" < /dev/tty 2>/dev/null || true
    fi

    CURRENT_FFMPEG_PID=$(cat "$pid_file" 2>/dev/null || echo "")

    # Ctrl-C reaches ffmpeg too: it traps SIGINT and exits 255 "normally", so
    # bash never runs the INT trap and the batch went on with the next file
    # (inherited from convert-to-av1). Early abort and the ">" key stop ffmpeg
    # with SIGTERM (signal 15), so signal 2 here can only be the user.
    if [[ "$ffmpeg_exit" -ne 0 && ! -f "$abort_signal" && ! -f "$skip_signal" ]] \
       && grep -q "received signal 2" "$stderr_log" 2>/dev/null; then
        exit 130
    fi

    if [[ -f "$abort_signal" ]]; then
        EARLY_ABORTED=true
        rm -f "$abort_signal"
    fi
    if [[ -f "$skip_signal" ]]; then
        SKIP_REQUESTED=true
        rm -f "$skip_signal"
        clear_line
        info "  Skipped by user."
    fi
    rm -f "$pid_file"

    # ffmpeg stderr is captured, not shown live; surface the tail on a hard
    # failure only (not interrupt/early-abort/user-skip)
    if [[ "$ffmpeg_exit" -ne 0 && "$ffmpeg_exit" -ne 130 ]] \
       && ! $EARLY_ABORTED && ! $SKIP_REQUESTED && [[ -s "$stderr_log" ]]; then
        warn "ffmpeg failed (exit $ffmpeg_exit); last lines:"
        while IFS= read -r _l; do echo -e "  ${GRAY}${_l}${NC}" >&2; done \
            < <(tail -n 5 "$stderr_log")
    fi
    rm -f "$stderr_log"
    CURRENT_STDERR_LOG=""

    LAST_ENCODE_SECS=$(( $(date +%s) - start_time ))

    post_process "$input_file" "$final_output" "$temp_output" "$ffmpeg_exit" \
        "$is_temp" "$input_size" "$ts_ref"

    rm -f "$ts_ref"
    release_lock "$input_file"

    return 0
}

# ==============================================================================
# Quality check (SSIM sampling)
# ==============================================================================

# Seconds from the container start to the first video frame (0 when unknown)
video_lead() {
    local v f
    v=$(ffprobe -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 "$1" 2>/dev/null | sed -n 1p)
    f=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$1" 2>/dev/null | sed -n 1p)
    awk -v v="$v" -v f="$f" 'BEGIN { if (v !~ /^-?[0-9.]+$/) v = 0; if (f !~ /^-?[0-9.]+$/) f = 0; printf "%.6f", v - f }'
}

# Mean SSIM over sampled segments (stdout), "N/A" on failure.
# The explicit [0:v:0][1:v:0] pads are required throughout: a bare "ssim"
# filter mis-selects streams when a cover/attached_pic second video stream is
# present and silently returns N/A.
compute_ssim_sampled() {
    local source="$1"
    local output="$2"

    # ssim requires equal dimensions: when the output was downscaled
    # (--max-res/--720/...), bring the source down to it and compare at the
    # output resolution — otherwise the check silently returns N/A
    # Both timelines are rebased to their first frame (setpts=PTS-STARTPTS):
    # ssim pairs frames by timestamp, and an output whose video starts later
    # than the source's (AAC priming in MP4 shifts the MKV by ~23 ms) was
    # compared one frame off — 0.92 instead of 0.996 on moving content, enough
    # to make --smart reject good encodes (inherited from convert-to-av1).
    local ref_chain="[0:v:0]setpts=PTS-STARTPTS"
    local out_dims
    out_dims=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=s=x:p=0 "$output" 2>/dev/null | head -1)
    if [[ "$out_dims" =~ ^([0-9]+)x([0-9]+)$ ]] \
        && [[ "${BASH_REMATCH[2]}" != "$(get_video_height "$source")" ]]; then
        ref_chain+=",scale=${BASH_REMATCH[1]}:${BASH_REMATCH[2]}:flags=bicubic"
    fi
    local ssim_graph="${ref_chain}[ref];[1:v:0]setpts=PTS-STARTPTS[out];[ref][out]ssim"

    # Input -ss counts from the container start, not from the first video
    # frame. Shifting the output's seek by the difference of those two gaps
    # lands both inputs on the same frame index.
    local seek_shift
    seek_shift=$(awk -v so="$(video_lead "$source")" -v oo="$(video_lead "$output")" \
        'BEGIN { printf "%.3f", oo - so }')

    local dur
    dur=$(get_duration_secs "$source")
    if [[ "$dur" -lt 10 ]]; then
        # Short file: compare the whole thing
        local result
        result=$(ffmpeg -hide_banner -i "$source" -i "$output" \
            -filter_complex "$ssim_graph" -f null /dev/null 2>&1 \
            | grep -oP 'All:\K[0-9.]+' | tail -1) || true
        echo "${result:-N/A}"
        return
    fi

    # N evenly-spaced sample points spanning 10%..90% of the duration
    local positions=()
    local n_samp="$quality_samples"
    [[ "$n_samp" -lt 1 ]] && n_samp=1
    if [[ "$n_samp" -eq 1 ]]; then
        positions+=( $(( dur * 50 / 100 )) )
    else
        local si pct
        for (( si = 0; si < n_samp; si++ )); do
            pct=$(( 10 + si * 80 / (n_samp - 1) ))
            positions+=( $(( dur * pct / 100 )) )
        done
    fi

    # MPEG-TS has no seek index: -ss lands mid-GOP and the source decodes
    # garbage until the next keyframe (SSIM ~0.85 on a perfect encode). Each
    # sample therefore starts on the first source keyframe at/after its point.
    local snap_keyframes=false fmt_start=0
    if is_mpeg_ts "$source"; then
        snap_keyframes=true
        fmt_start=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$source" 2>/dev/null | sed -n 1p)
        [[ "$fmt_start" =~ ^-?[0-9.]+$ ]] || fmt_start=0
    fi

    local total=0 count=0 i=0 n=${#positions[@]}
    for pos in "${positions[@]}"; do
        local spos="$pos"   # seek position (may be fractional); pos stays whole for display
        if $snap_keyframes; then
            local kf
            kf=$(ffprobe -v error -select_streams v:0 -read_intervals "${pos}%+30" \
                -show_entries packet=pts_time,flags -of csv=p=0 "$source" 2>/dev/null \
                | awk -F, -v fs="$fmt_start" -v p="$pos" \
                    '$1 ~ /^[0-9.]+$/ && $2 ~ /K/ && $1 - fs >= p { printf "%.3f", $1 - fs; exit }') || true
            [[ -n "$kf" ]] && spos="$kf"
        fi
        i=$((i + 1))
        # Feedback on stderr — stdout carries the score
        if ! $no_progress; then
            printf "\r  SSIM sampling %d/%d (@%s)...        " \
                "$i" "$n" "$(format_duration "$pos")" >&2
        fi
        local ssim_val
        local opos
        opos=$(awk -v p="$spos" -v s="$seek_shift" 'BEGIN { v = p + s; if (v < 0) v = 0; printf "%.3f", v }')
        ssim_val=$(ffmpeg -hide_banner \
            -ss "$spos" -t "$quality_sample_secs" -i "$source" \
            -ss "$opos" -t "$quality_sample_secs" -i "$output" \
            -filter_complex "$ssim_graph" -f null /dev/null 2>&1 \
            | grep -oP 'All:\K[0-9.]+' | tail -1) || true
        if [[ -n "$ssim_val" && "$ssim_val" != "0" ]]; then
            total=$(echo "$total + $ssim_val" | bc -l)
            count=$((count + 1))
        fi
    done
    clear_line err

    if [[ "$count" -eq 0 ]]; then
        echo "N/A"
        return
    fi

    local mean
    mean=$(echo "scale=6; $total / $count" | bc -l)
    [[ "$mean" == .* ]] && mean="0${mean}"   # bc omits the leading zero
    echo "$mean"
}

# ==============================================================================
# Post-processing
# ==============================================================================

post_process() {
    local input_file="$1"
    local final_output="$2"
    local temp_output="$3"
    local ffmpeg_exit="$4"
    local is_temp="$5"
    local input_size="$6"
    local ts_ref="${7:-}"

    if $EARLY_ABORTED; then
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""

        if $keep_best_version && $in_place; then
            info "  Early abort: source kept as-is."
        elif $keep_best_version && [[ -n "$output_dir" ]]; then
            local dest_path
            dest_path="${output_dir}/$(basename "$input_file")"
            if [[ -f "$dest_path" ]]; then
                warn "Destination already exists, not overwriting: $dest_path"
            else
                info "  Early abort: copying source to output directory."
                cp -f "$input_file" "$dest_path"
            fi
        fi

        append_skip_log "$input_file" "$input_size" "early-abort: estimated output larger"
        add_result "$input_file" "ABORTED" "$input_size" 0 "estimated output larger"
        return 0
    fi

    if $SKIP_REQUESTED; then
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "SKIPPED" "$input_size" 0 "skipped by user"
        return 0
    fi

    if [[ "$ffmpeg_exit" -ne 0 ]]; then
        warn "Conversion failed (code $ffmpeg_exit): $input_file"
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "FAILED" "$input_size" 0 "ffmpeg exit $ffmpeg_exit"
        return 0
    fi

    # All validation below runs on the temp, before the atomic mv — a rejected
    # encode must never touch the destination (nor the in-place source)
    local output_size=0
    [[ -f "$temp_output" ]] && output_size=$(get_file_size "$temp_output")

    if [[ "$output_size" -eq 0 ]]; then
        warn "Output file empty or missing: $final_output"
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "FAILED" "$input_size" 0 "empty output"
        return 0
    fi

    # Corrupt-output tripwire: min(SANITY_SIZE, input/10), hard floor 1K — the
    # cap keeps tiny-but-valid clips from being misflagged
    local min_output_size=$(( input_size / 10 ))
    [[ "$min_output_size" -gt "$SANITY_SIZE" ]] && min_output_size="$SANITY_SIZE"
    [[ "$min_output_size" -lt 1024 ]] && min_output_size=1024
    if [[ "$output_size" -lt "$min_output_size" ]]; then
        warn "Output too small (${output_size} bytes), likely corrupt: $final_output"
        rm -f "$temp_output"
        CURRENT_TEMP_FILE=""
        add_result "$input_file" "FAILED" "$input_size" 0 "corrupt output (${output_size} bytes)"
        return 0
    fi

    # SSIM check — pointless in remux mode (streams are copied verbatim)
    if $quality_check && ! $copy_streams && [[ -f "$input_file" ]]; then
        info "  Quality check (SSIM sampling)..."
        local ssim_score
        ssim_score=$(compute_ssim_sampled "$input_file" "$temp_output")
        if [[ "$ssim_score" == "N/A" ]]; then
            warn "Quality check failed (could not compute SSIM): $final_output"
        else
            local ssim_ok
            ssim_ok=$(echo "$ssim_score >= $quality_min_ssim" | bc -l 2>/dev/null || echo "1")
            if [[ "$ssim_ok" -eq 0 ]]; then
                warn "Quality too low (SSIM=${ssim_score}, min=${quality_min_ssim}): $final_output"
                append_skip_log "$input_file" "$input_size" "SSIM ${ssim_score} < ${quality_min_ssim}"
                rm -f "$temp_output"
                CURRENT_TEMP_FILE=""
                add_result "$input_file" "FAILED" "$input_size" "$output_size" "SSIM ${ssim_score} < ${quality_min_ssim}"
                return 0
            fi
            info "  SSIM: ${ssim_score} (min: ${quality_min_ssim})"
            LAST_SSIM="$ssim_score"
        fi
    fi

    # Full decode (-xerror = fail on first decode error). Forced on outputs
    # below SANITY_SIZE: near-free at that size, and the size tripwire alone
    # cannot tell a legit tiny clip from garbage.
    local force_verify=false
    [[ "$output_size" -lt "$SANITY_SIZE" ]] && force_verify=true
    if $verify_output || $force_verify; then
        if $force_verify && ! $verify_output; then
            info "  Output is small ($(human_size "$output_size")) — verifying (full decode)..."
        else
            info "  Verifying output (full decode)..."
        fi
        local verify_err=""
        if ! verify_err=$(ffmpeg -v error -xerror -i "$temp_output" \
                -f null - 2>&1); then
            warn "Output failed decode verification: $final_output"
            [[ -n "$verify_err" ]] && warn "  $(echo "$verify_err" | tail -n 2)"
            rm -f "$temp_output"
            CURRENT_TEMP_FILE=""
            add_result "$input_file" "FAILED" "$input_size" "$output_size" "verify: decode errors"
            return 0
        fi
    fi

    # Place the validated output at its final destination (atomic mv on the
    # same filesystem — the temp lives in the destination dir).
    if [[ "$is_temp" == true ]]; then
        mv -f "$temp_output" "$final_output"
    fi
    CURRENT_TEMP_FILE=""

    # Preserve source filesystem timestamps (mtime/atime) and permissions
    if [[ -n "$ts_ref" && -f "$ts_ref" ]]; then
        chmod --reference="$ts_ref" "$final_output" 2>/dev/null || true
        touch -r "$ts_ref" "$final_output" 2>/dev/null || true
    fi

    # Size saved (exact bytes; the percentage is display-only)
    local saved_pct="0.0" saved_bytes=0
    if [[ "$input_size" -gt 0 ]]; then
        saved_pct=$(pct_1dp "$(( input_size - output_size ))" "$input_size")
        saved_bytes=$(( input_size - output_size ))
    fi

    if [[ "$output_size" -gt "$input_size" ]]; then
        report_savings "$input_size" "$output_size" ""

        # Skip-logged before any source move so the recorded path stays right
        if $keep_best_version || $remove_if_bigger; then
            append_skip_log "$input_file" "$input_size" "output larger than source"
        fi

        if $keep_best_version; then
            info "  Smart: output larger, removing it and keeping source."
            rm -f "$final_output"
            if [[ -n "$output_dir" ]]; then
                local dest_path
                dest_path="${output_dir}/$(basename "$input_file")"
                if [[ -f "$dest_path" ]]; then
                    warn "Destination already exists, not overwriting: $dest_path"
                else
                    mv -f "$input_file" "$dest_path"
                fi
            fi
            add_result "$input_file" "KEPT_SRC" "$input_size" "$output_size" "smart: source kept (output +${saved_pct#-}%)"
        elif $remove_if_bigger; then
            info "  Removing larger output."
            rm -f "$final_output"
            add_result "$input_file" "RM_OUT" "$input_size" "$output_size" "output removed (+${saved_pct#-}%)"
        else
            local space
            space=$(space_state "$input_file" "$final_output")
            account_savings "$input_size" "$output_size" "$space"
            report_space "$saved_bytes" "$space"
            add_result "$input_file" "OK" "$input_size" "$output_size" "larger +${saved_pct#-}%" "$space"
        fi
    else
        if $remove_source; then
            if $in_place; then
                # An in-place .mkv source IS the output — never remove it
                local input_ext="${input_file##*.}"
                if [[ "${input_ext,,}" != "mkv" ]]; then
                    debug "  Removing source (different extension): $input_file"
                    rm -f "$input_file"
                fi
            else
                debug "  Removing source: $input_file"
                rm -f "$input_file"
            fi

            # Merged subs go with the source; .txt descriptions are always kept
            if $merge_subs; then
                local sub_files
                sub_files=$(find_subtitle_files "$input_file")
                while IFS= read -r sf; do
                    [[ -z "$sf" ]] && continue
                    debug "  Removing merged subtitle: $sf"
                    rm -f "$sf"
                done <<< "$sub_files"
            fi
        fi

        # Reported after the source handling, so "freed" reflects the disk
        local space
        space=$(space_state "$input_file" "$final_output")
        report_savings "$input_size" "$output_size" "$space"
        account_savings "$input_size" "$output_size" "$space"
        add_result "$input_file" "OK" "$input_size" "$output_size" \
            "saved ${saved_pct}% ($(human_size "$saved_bytes"))${LAST_SSIM:+ ssim=$LAST_SSIM}" "$space"
    fi
}

# "freed" when the source is already gone (removed, or replaced in place by
# the output at the same path), "pending" while it still sits on disk
space_state() {
    local src="$1" out="$2"
    local canon
    canon="$(dirname "$src")/$(basename "$src")"
    if [[ "$canon" == "$out" || ! -e "$src" ]]; then
        echo "freed"
    else
        echo "pending"
    fi
}

account_savings() {
    local in_sz="$1" out_sz="$2" space="$3"
    local d=$(( in_sz - out_sz ))
    BATCH_SAVED_BYTES=$(( BATCH_SAVED_BYTES + d ))
    BATCH_CONV_IN_BYTES=$(( BATCH_CONV_IN_BYTES + in_sz ))
    BATCH_CONV_OUT_BYTES=$(( BATCH_CONV_OUT_BYTES + out_sz ))
    if [[ "$space" == "freed" ]]; then
        BATCH_FREED_BYTES=$(( BATCH_FREED_BYTES + d ))
    else
        BATCH_PENDING_BYTES=$(( BATCH_PENDING_BYTES + d ))
    fi
}

# The per-file result line: source -> output, delta in bytes and %, and
# whether the space is already free. Exact byte counts in brackets.
report_savings() {
    local in_sz="$1" out_sz="$2" space="${3:-}"
    local d=$(( in_sz - out_sz )) pct
    pct=$(pct_1dp "$d" "$in_sz")
    if [[ "$d" -ge 0 ]]; then
        echo -e "  ${GREEN}${BOLD}▼ SAVED $(human_size "$d") (${pct}%)${NC}${GREEN}  $(human_size "$in_sz") -> $(human_size "$out_sz")  [${in_sz} -> ${out_sz} bytes, -${d}]${NC}"
    else
        echo -e "  ${RED}${BOLD}▲ LARGER +$(human_size "$(( -d ))") (+${pct#-}%)${NC}${RED}  $(human_size "$in_sz") -> $(human_size "$out_sz")  [${in_sz} -> ${out_sz} bytes, +$(( -d ))]${NC}"
    fi
    [[ -n "$space" ]] && report_space "$d" "$space"
    return 0
}

report_space() {
    local d="$1" space="$2"
    if [[ "$d" -lt 0 ]]; then
        local more
        more=$(human_size "$(( -d ))")
        if [[ "$space" == "freed" ]]; then
            echo -e "    ${GRAY}space:${NC} ${RED}${more} MORE in use now${NC} (source replaced by the larger output)"
        else
            echo -e "    ${GRAY}space:${NC} ${RED}would use ${more} more${NC} once the source is deleted (source kept)"
        fi
    elif [[ "$space" == "freed" ]]; then
        echo -e "    ${GRAY}space:${NC} ${GREEN}$(human_size "$d") freed now${NC} (source removed or replaced)"
    else
        echo -e "    ${GRAY}space:${NC} ${ORANGE}$(human_size "$d") pending${NC} — frees once the source is deleted (source kept)"
    fi
}

# Running total between files: exact same basis as the final summary
print_batch_progress() {
    local bline="batch: $((FILES_PROCESSED - 1))/${FILES_TOTAL} done"
    if [[ "$BATCH_CONV_IN_BYTES" -gt 0 ]]; then
        local s
        if [[ "$BATCH_SAVED_BYTES" -ge 0 ]]; then
            s="saved $(human_size "$BATCH_SAVED_BYTES")"
        else
            s="larger by $(human_size "$(( -BATCH_SAVED_BYTES ))")"
        fi
        bline+=" | ${s} ($(pct_1dp "$BATCH_SAVED_BYTES" "$BATCH_CONV_IN_BYTES")% of $(human_size "$BATCH_CONV_IN_BYTES"))"
        bline+=" | freed $(human_size "$BATCH_FREED_BYTES"), pending $(human_size "$BATCH_PENDING_BYTES")"
    fi
    if [[ "$BATCH_DONE_BYTES" -gt 0 && "$BATCH_TOTAL_BYTES" -gt "$BATCH_DONE_BYTES" ]]; then
        local b_elapsed=$(( $(date +%s) - BATCH_START_TIME ))
        if [[ "$b_elapsed" -ge 5 ]]; then
            bline+=" | ~$(format_duration $(( (BATCH_TOTAL_BYTES - BATCH_DONE_BYTES) * b_elapsed / BATCH_DONE_BYTES ))) left"
        fi
    fi
    echo -e "${BOLD}${bline}${NC}"
}

# ==============================================================================
# Summary
# ==============================================================================

# Column width of one code point in REPLY: combining marks 0, East-Asian
# Wide/Fullwidth 2, everything else 1.
cp_width() {
    local code=$1
    if   (( code >= 0x300 && code <= 0x36F )); then REPLY=0
    elif (( code >= 0x1100 && ( code <= 0x115F \
            || (code >= 0x2E80 && code <= 0xA4CF) \
            || (code >= 0xAC00 && code <= 0xD7A3) \
            || (code >= 0xF900 && code <= 0xFAFF) \
            || (code >= 0xFE30 && code <= 0xFE4F) \
            || (code >= 0xFF00 && code <= 0xFF60) \
            || (code >= 0xFFE0 && code <= 0xFFE6) \
            || (code >= 0x1F300 && code <= 0x1FAFF) \
            || (code >= 0x20000 && code <= 0x3FFFD) ) )); then REPLY=2
    else REPLY=1; fi
}

# Terminal display width of a UTF-8 string, returned in REPLY. bash's %-Ns pads
# by BYTES, so accents (2-byte, 1 col) shrink a field and full-width forms
# (｜：, 1 char / 2 cols) widen it — either way the columns after it shift.
disp_width() {
    local s=$1
    local n=${#s} i w=0
    for (( i = 0; i < n; i++ )); do
        printf -v REPLY '%d' "'${s:i:1}"
        cp_width "$REPLY"
        w=$(( w + REPLY ))
    done
    REPLY=$w
}

# Truncate to <= max display columns keeping the TAIL (episode ids live there),
# ".." prefix when cut — must be width-aware or wide chars overflow the column.
fit_tail() {
    local s=$1 max=$2
    disp_width "$s"
    (( REPLY <= max )) && { REPLY=$s; return; }
    local n=${#s} i code w=0 cut=${#s} budget=$(( max - 2 ))
    for (( i = n - 1; i >= 0; i-- )); do
        printf -v code '%d' "'${s:i:1}"
        cp_width "$code"
        (( w + REPLY > budget )) && break
        w=$(( w + REPLY )); cut=$i
    done
    REPLY="..${s:cut}"
}

print_summary() {
    local count=${#SUMMARY_FILES[@]}
    [[ "$count" -eq 0 ]] && return

    echo ""
    printf "${BOLD}%-50s %-10s %10s %10s %10s %7s %-7s  %s${NC}\n" \
        "File" "Status" "Input" "Output" "Saved" "%" "Space" "Note"
    printf "%-50s %-10s %10s %10s %10s %7s %-7s  %s\n" \
        "$(printf '%0.s-' {1..50})" "----------" "----------" "----------" "----------" "-------" "-------" "----"

    local total_input=0 total_output=0 total_freed=0 total_pending=0
    local n_freed=0 n_pending=0
    local count_ok=0 count_skip=0 count_fail=0 count_abort=0

    for ((i = 0; i < count; i++)); do
        local file status in_sz out_sz note
        # Relative path, left-truncated: with -r, same-named episodes from
        # different seasons must stay tellable apart
        file="${SUMMARY_FILES[$i]#./}"
        status="${SUMMARY_STATUSES[$i]}"
        in_sz="${SUMMARY_INPUT_SIZES[$i]}"
        out_sz="${SUMMARY_OUTPUT_SIZES[$i]}"
        note="${SUMMARY_NOTES[$i]}"
        local space="${SUMMARY_SPACE[$i]:-}"

        fit_tail "$file" 48
        file=$REPLY

        local in_h out_h gain_str saved_h color
        in_h=$(human_size "$in_sz")
        saved_h="---"
        color="$NC"

        case "$status" in
            OK)
                out_h=$(human_size "$out_sz")
                if [[ "$in_sz" -gt 0 ]]; then
                    gain_str="$(pct_1dp "$(( in_sz - out_sz ))" "$in_sz")%"
                    saved_h=$(human_size "$(( in_sz - out_sz ))")
                else
                    gain_str="---"
                fi
                color="$GREEN"
                [[ "$out_sz" -gt "$in_sz" ]] && color="$RED"
                total_input=$((total_input + in_sz))
                total_output=$((total_output + out_sz))
                if [[ "$space" == "freed" ]]; then
                    total_freed=$(( total_freed + in_sz - out_sz )); n_freed=$((n_freed + 1))
                else
                    total_pending=$(( total_pending + in_sz - out_sz )); n_pending=$((n_pending + 1))
                fi
                count_ok=$((count_ok + 1))
                ;;
            KEPT_SRC|RM_OUT)
                out_h="---"
                gain_str="---"
                color="$ORANGE"
                count_ok=$((count_ok + 1))
                ;;
            SKIPPED|DRYRUN|NOTFOUND|LOCKED)
                out_h="---"
                gain_str="---"
                color="$GRAY"
                count_skip=$((count_skip + 1))
                ;;
            ABORTED)
                out_h="---"
                gain_str="---"
                color="$ORANGE"
                count_abort=$((count_abort + 1))
                ;;
            FAILED)
                out_h="---"
                gain_str="---"
                color="$RED"
                count_fail=$((count_fail + 1))
                ;;
        esac

        disp_width "$file"
        local pad=$(( 50 - REPLY )); (( pad < 1 )) && pad=1
        printf "${color}%s%*s %-10s %10s %10s %10s %7s %-7s  %s${NC}\n" \
            "$file" "$pad" "" "$status" "$in_h" "$out_h" "$saved_h" "$gain_str" "$space" "$note"
    done

    echo ""
    if [[ "$total_input" -gt 0 ]]; then
        # Exact byte sums over the OK rows; freed + pending == saved, always
        local total_saved_bytes=$(( total_input - total_output ))
        local total_saved
        total_saved=$(pct_1dp "$total_saved_bytes" "$total_input")
        local verb="saved" tcol="$GREEN"
        [[ "$total_saved_bytes" -lt 0 ]] && { verb="larger by"; tcol="$RED"; }
        local shown_bytes=$total_saved_bytes
        [[ "$shown_bytes" -lt 0 ]] && shown_bytes=$(( -shown_bytes ))
        echo -e "${BOLD}${tcol}Total: $(human_size "$total_input") -> $(human_size "$total_output") | ${verb} $(human_size "$shown_bytes") (${total_saved}%) over $((n_freed + n_pending)) converted file(s)${NC}"
        echo -e "  exact ........... ${total_input} -> ${total_output} bytes = ${total_saved_bytes} bytes saved"
        echo -e "  freed now ....... ${GREEN}$(human_size "$total_freed")${NC} (${total_freed} bytes, ${n_freed} file(s): source removed or replaced)"
        if [[ "$n_pending" -gt 0 ]]; then
            echo -e "  pending ......... ${ORANGE}$(human_size "$total_pending")${NC} (${total_pending} bytes, ${n_pending} file(s): frees once the kept source is deleted)"
        else
            echo -e "  pending ......... 0B (0 bytes, no source left to delete)"
        fi
    fi
    if [[ "$BATCH_START_TIME" -gt 0 ]]; then
        local batch_elapsed=$(( $(date +%s) - BATCH_START_TIME ))
        echo -e "${BOLD}OK: ${count_ok} | Skip: ${count_skip} | Abort: ${count_abort} | Fail: ${count_fail} | Total: ${count} | elapsed: $(format_duration "$batch_elapsed")${NC}"
    else
        echo -e "${BOLD}OK: ${count_ok} | Skip: ${count_skip} | Abort: ${count_abort} | Fail: ${count_fail} | Total: ${count}${NC}"
    fi
}

# ==============================================================================
# Config banner
# ==============================================================================

# "  key ......... value"
banner_line() {
    local key="$1" value="$2" color="${3:-$NC}"
    local dots
    dots=$(printf '%*s' $(( 17 - ${#key} )) '' | tr ' ' '.')
    echo -e "  ${GRAY}${key} ${dots}${NC} ${color}${value}${NC}"
}

format_vp9_options() {
    local parts=()

    parts+=("cpu-used=${vp9_cpu_used}")
    parts+=("crf=${vp9_crf}")
    if [[ "$vp9_pix_fmt" == *"10le" ]]; then parts+=("10-bit"); else parts+=("8-bit"); fi
    if $vp9_two_pass; then parts+=("2-pass"); else parts+=("1-pass"); fi
    parts+=("tune=${vp9_tune_content}")

    # The AV1 grain request is shown with its VP9 mapping, never hidden
    if [[ "$vp9_film_grain" -gt 0 || "$vp9_film_grain_denoise" -eq 1 ]]; then
        local g="grain=${vp9_film_grain}"
        [[ "$vp9_film_grain_denoise" -eq 1 ]] && g+="+denoise"
        parts+=("(${g} requested: no VP9 synthesis)")
    fi

    echo "libvpx-vp9 ${parts[*]}"
}

print_banner() {
    local sep
    sep=$(printf '─%.0s' {1..48})

    # Repeat, don't slice: ${sep:0:N} cuts bytes under a non-UTF-8 locale and
    # leaves half a box-drawing character (invalid UTF-8) on the terminal
    local tail_n=$(( 48 - 20 - ${#VERSION} )) tail_sep
    tail_sep=$(printf '─%.0s' $(seq 1 "$tail_n"))
    echo -e "${GRAY}──${NC} ${BOLD}convert-to-vp9 v${VERSION}${NC} ${GRAY}${tail_sep}${NC}"

    if $in_place; then
        banner_line "output" "in-place"
    else
        banner_line "output" "$output_dir"
    fi

    if $copy_streams; then
        banner_line "encoder" "remux only (no re-encode)" "$ORANGE"
    else
        local enc_label=""
        [[ "$speed_preset" != "default" ]] && enc_label="$speed_preset"
        [[ -n "$content_type" ]] && enc_label+="${enc_label:+, }${content_type}"
        banner_line "encoder" "$(format_vp9_options)${enc_label:+ (${enc_label})}"
        [[ -n "$content_type" ]] && banner_line "content" "$content_type"
        if $convert_av1; then
            banner_line "skip" "VP9 sources (AV1 sources are re-encoded)"
        else
            banner_line "skip" "VP9 and AV1 sources (--convert-av1 to re-encode AV1)"
        fi
    fi

    if $copy_streams; then
        banner_line "audio" "copy"
    else
        case "$audio_mode" in
            opus) banner_line "audio" "Opus (always)" ;;
            auto) banner_line "audio" "Opus if > ${audio_bitrate_threshold} kb/s" ;;
            *)    banner_line "audio" "copy" ;;
        esac
    fi

    [[ -n "$audio_tracks" ]] && banner_line "audio tracks" "$audio_tracks" "$ORANGE"
    if [[ -n "$audio_langs" || -n "$sub_langs" ]]; then
        banner_line "keep langs" "audio: ${audio_langs:-all} | subs: ${sub_langs:-all}" "$ORANGE"
    fi

    [[ -n "$max_res" ]] && banner_line "max height" "${max_res}p" "$ORANGE"

    # Destructive flags in red, the rest in orange
    local flags=()
    $keep_best_version && flags+=("smart")
    $remove_source && flags+=("${RED}rm-source${NC}")
    $remove_if_bigger && flags+=("${RED}rm-if-bigger${NC}")
    $recursive && flags+=("recursive")
    [[ -n "$overwrite" ]] && flags+=("${RED}overwrite${NC}")
    $dry_run && flags+=("dry-run")
    if [[ ${#flags[@]} -gt 0 ]]; then
        local flag_str
        flag_str=$(printf '%s, ' "${flags[@]}")
        banner_line "flags" "${flag_str%, }" "$ORANGE"
    fi

    if $early_abort && ($remove_if_bigger || $keep_best_version); then
        banner_line "early abort" "${early_abort_threshold}%"
    fi

    $quality_check && banner_line "quality check" "SSIM >= ${quality_min_ssim} (${quality_samples} samples)"
    $verify_output && banner_line "verify" "full decode of each output"
    $merge_subs && banner_line "subtitles" "merge .srt/.vtt"
    if $use_profiles; then
        if [[ -n "$CURRENT_PROFILE_FILE" ]]; then
            banner_line "profiles" "root: ${CURRENT_PROFILE_FILE} [${CURRENT_PROFILE_TOKENS}]"
        else
            banner_line "profiles" ".convert-profile (per dir)"
        fi
    fi

    [[ -n "$sort_by_size" ]] && banner_line "sort" "size $sort_by_size"
    [[ -n "$sort_by_date" ]] && banner_line "sort" "date $sort_by_date"
    [[ -n "$sort_by_bitrate" ]] && banner_line "sort" "bitrate $sort_by_bitrate"
    [[ "$min_size" -gt 0 ]] && banner_line "min size" "$(human_size "$min_size")"
    [[ "$min_bitrate" -gt 0 ]] && banner_line "min bitrate" "$(( min_bitrate / 1000 )) kb/s"
    [[ ${#exclude_patterns[@]} -gt 0 ]] && banner_line "exclude" "${exclude_patterns[*]}"
    $skip_log_enabled && banner_line "skip-log" "$skip_log_file"
    [[ -n "$after_cmd" ]] && banner_line "after" "$after_cmd"

    echo -e "${GRAY}${sep}${NC}"
    if [[ -t 2 ]] && ! $no_progress; then
        echo -e "${GRAY}  Press > to skip the current file${NC}"
    fi
}

# ==============================================================================
# Entry point
# ==============================================================================

main() {
    parse_args "$@"
    # Snapshotted before deriving options — profiles must overlay the raw CLI base
    snapshot_base_config
    apply_content_type
    build_vp9_options
    check_dependencies
    activate_skip_log

    # Resolve the input root's profile first: the banner must show effective
    # values (12 samples, sort, ...), not the raw CLI base — deeper directories
    # may still override per file
    if $use_profiles && [[ ${#input_args[@]} -gt 0 ]]; then
        local banner_root="${input_args[0]}"
        [[ -d "$banner_root" ]] && banner_root="${banner_root%/}/."
        resolve_file_profile "$banner_root"
    fi

    print_banner

    local sorted_files=()
    collect_and_sort_files sorted_files

    if [[ ${#sorted_files[@]} -eq 0 ]]; then
        warn "No video files found."
        exit 0
    fi

    FILES_TOTAL=${#sorted_files[@]}
    BATCH_START_TIME=$(date +%s)

    # ETA denominator, captured up front — sources may shrink or vanish mid-batch
    for file in "${sorted_files[@]}"; do
        BATCH_TOTAL_BYTES=$((BATCH_TOTAL_BYTES + $(get_file_size "$file")))
    done

    if [[ -n "$log_file" ]] && ! $dry_run; then
        write_log_session_header
    fi

    for file in "${sorted_files[@]}"; do
        convert_file "$file" || true
        BATCH_DONE_BYTES=$((BATCH_DONE_BYTES + LAST_INPUT_SIZE))
    done

    if [[ -n "$after_cmd" ]]; then
        info "Running --after command: $after_cmd"
        eval "$after_cmd" || warn "--after command failed (exit $?)"
    fi

    # Summary is printed by the EXIT trap via cleanup
}

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
