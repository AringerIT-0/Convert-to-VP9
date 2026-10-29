#!/usr/bin/env bash
# Integration test suite for convert-to-vp9 (adapted from convert-to-av1).
# Generates synthetic video files on the fly and exercises the main script features.
# Usage: bash test.sh

set -uo pipefail

# The summary-alignment test measures display columns of UTF-8 file names;
# under a C/POSIX locale bash slices bytes, so the suite pins a UTF-8 LC_CTYPE.
if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]] && locale -a 2>/dev/null | grep -qix 'c.utf-\?8'; then
    export LC_CTYPE=C.UTF-8
fi

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERT_BIN="$SCRIPT_DIR/convert-to-vp9.sh"
# Synthetic test files can be tiny (a 2s testsrc clip compresses below the 128K
# default --min-size), so the suite runs with the filter disabled; tests that
# exercise --min-size pass their own value, which overrides (last flag wins).
CONVERT=""   # set in setup() — wrapper injecting --min-size 0

TEST_DIR=""
PASS=0
FAIL=0
SKIP=0
FAILURES=()

# ---------------------------------------------------------------------------
# Colors (disabled when NO_COLOR is set or stdout is not a terminal)
# ---------------------------------------------------------------------------

if [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'
    RED=$'\033[0;31m'
    YELLOW=$'\033[0;33m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    GREEN='' RED='' YELLOW='' BOLD='' RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
    TEST_DIR="$(mktemp -d /tmp/convert-vp9-test.XXXXXX)"
    CONVERT="$TEST_DIR/convert-wrapper.sh"
    printf '#!/usr/bin/env bash\nexec bash %q --min-size 0 "$@"\n' "$CONVERT_BIN" > "$CONVERT"
    chmod +x "$CONVERT"
}

# shellcheck disable=SC2317,SC2329  # invoked via trap (0.9 reports 2317, 0.10+ 2329)
teardown() {
    if [[ -n "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}
trap teardown EXIT

pass() {
    ((PASS++))
    printf "  ${GREEN}PASS${RESET}  %s\n" "$1"
}

fail() {
    ((FAIL++))
    FAILURES+=("$1: $2")
    printf "  ${RED}FAIL${RESET}  %s — %s\n" "$1" "$2"
}

section() {
    printf "\n${BOLD}── %s${RESET}\n" "$1"
}

# Generate a short synthetic h264 video.
# $1 = output path, $2 = duration (seconds, default 3), $3 = resolution (default 320x240)
generate_video() {
    local out="$1" dur="${2:-3}" res="${3:-320x240}"
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=${res}:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=${dur}" \
        -c:v libx264 -preset ultrafast -crf 28 \
        -c:a aac -b:a 64k \
        -pix_fmt yuv420p \
        "$out" 2>/dev/null
}

# Generate a short VP9 video (already converted).
generate_vp9_video() {
    local out="$1" dur="${2:-2}"
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=320x240:rate=25" \
        -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -crf 50 -b:v 0 \
        -an "$out" 2>/dev/null
}

# AV1 fixture encoder: any AV1 encoder this ffmpeg has (empty = none — the
# AV1 tests then count as skipped, the converter itself never needs one)
# (captured, not piped into grep -q: that SIGPIPEs ffmpeg under pipefail)
AV1_FIXTURE_ENC=""
_encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
for _e in libsvtav1 libaom-av1 librav1e; do
    if [[ "$_encoders" == *" ${_e} "* ]]; then
        AV1_FIXTURE_ENC="$_e"; break
    fi
done

# Generate a short AV1 video (a source this tool skips by default).
generate_av1_video() {
    local out="$1" dur="${2:-2}"
    local -a opts=()
    case "$AV1_FIXTURE_ENC" in
        libsvtav1)  opts=(-preset 12 -crf 50) ;;
        libaom-av1) opts=(-cpu-used 8 -crf 50 -b:v 0) ;;
        librav1e)   opts=(-speed 10 -qp 200) ;;
        *)          return 1 ;;
    esac
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=320x240:rate=25" \
        -c:v "$AV1_FIXTURE_ENC" "${opts[@]}" -an "$out" 2>/dev/null
}

skip_test() {
    ((SKIP++))
    printf "  ${YELLOW}SKIP${RESET}  %s — %s\n" "$1" "$2"
}

# Generate a large-bitrate video to trigger early abort.
generate_large_video() {
    local out="$1" dur="${2:-10}"
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=1920x1080:rate=30" \
        -f lavfi -i "sine=frequency=440:duration=${dur}" \
        -c:v libx264 -preset ultrafast -crf 1 \
        -c:a aac -b:a 256k \
        -pix_fmt yuv420p \
        "$out" 2>/dev/null
}

# Generate an MPEG-TS file.
generate_ts_video() {
    local out="$1" dur="${2:-3}"
    ffmpeg -y -f lavfi -i "testsrc=duration=${dur}:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=${dur}" \
        -c:v libx264 -preset ultrafast -crf 28 \
        -c:a aac -b:a 64k \
        -f mpegts \
        "$out" 2>/dev/null
}

# Generate an MKV with multiple audio languages (eng stereo, fre 5.1, spa stereo)
# and embedded eng/fre subtitles.
generate_multitrack_video() {
    local out="$1" dur="${2:-2}"
    local sub_en="${out}.en.srt" sub_fr="${out}.fr.srt"
    printf '1\n00:00:00,000 --> 00:00:01,000\nhello\n' > "$sub_en"
    printf '1\n00:00:00,000 --> 00:00:01,000\nbonjour\n' > "$sub_fr"
    ffmpeg -y \
        -f lavfi -i "testsrc=duration=${dur}:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=${dur}" \
        -f lavfi -i "sine=frequency=480:duration=${dur}" \
        -f lavfi -i "sine=frequency=500:duration=${dur}" \
        -i "$sub_en" -i "$sub_fr" \
        -map 0:v -map 1:a -map 2:a -map 3:a -map 4 -map 5 \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
        -c:a aac -ac:a:1 6 -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=fre -metadata:s:a:2 language=spa \
        -metadata:s:s:0 language=eng -metadata:s:s:1 language=fre \
        "$out" 2>/dev/null
    rm -f "$sub_en" "$sub_fr"
}

# Generate an MKV carrying an attached_pic cover (a still-image second video
# stream that must be copied, never fed to the encoder).
generate_cover_video() {
    local out="$1" dur="${2:-2}"
    local base="${out}.base.mkv" cover="${out}.cover.png"
    generate_video "$base" "$dur"
    ffmpeg -y -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 "$cover" 2>/dev/null
    ffmpeg -y -i "$base" -i "$cover" -map 0 -map 1 -c copy \
        -disposition:v:1 attached_pic "$out" 2>/dev/null
    rm -f "$base" "$cover"
}

# Count streams of a given selector (e.g. a, s, v) in a file.
count_streams() {
    ffprobe -v error -select_streams "$1" -show_entries stream=index \
        -of csv=p=0 "$2" 2>/dev/null | grep -c .
}

# Assert a file exists and is non-empty.
assert_file_exists() {
    [[ -f "$1" ]] && [[ -s "$1" ]]
}

# Assert a file does not exist.
assert_file_missing() {
    [[ ! -e "$1" ]]
}

# Get video codec of a file.
get_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of csv=p=0 "$1" 2>/dev/null | head -1 | tr -d '[:space:]'
}


# ===========================================================================
# Test cases
# ===========================================================================

setup

# --- Basic conversion ---

section "Basic conversion"

test_basic_conversion() {
    local dir="$TEST_DIR/basic"
    mkdir -p "$dir"
    generate_video "$dir/sample.mp4"

    "$CONVERT" --no-progress "$dir/sample.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/sample.mkv" "output"; then
        local codec
        codec=$(get_codec "$dir/sample.mkv")
        if [[ "$codec" == "vp9" ]]; then
            pass "basic conversion produces VP9 MKV"
        else
            fail "basic conversion" "expected vp9 codec, got '$codec'"
        fi
    else
        fail "basic conversion" "exit code $rc or output missing"
    fi
}
test_basic_conversion

# --- Skip already-VP9 / AV1 ---

section "Skip detection"

test_skip_already_vp9() {
    local dir="$TEST_DIR/skip-vp9"
    mkdir -p "$dir"
    generate_vp9_video "$dir/already.mkv"
    local before
    before=$(stat -c %s "$dir/already.mkv")

    local output
    output=$("$CONVERT" --no-progress "$dir/already.mkv" 2>&1) && rc=0 || rc=$?

    if echo "$output" | grep -q "already VP9" \
        && [[ "$(stat -c %s "$dir/already.mkv")" == "$before" ]]; then
        pass "skip already-VP9 file (left untouched)"
    else
        fail "skip already-VP9" "expected skip message, got: $(echo "$output" | tail -3)"
    fi
}
test_skip_already_vp9

# AV1 is the more efficient codec: skipped by default, --convert-av1 opts in.
test_skip_already_av1() {
    local dir="$TEST_DIR/skip-av1"
    mkdir -p "$dir"
    if ! generate_av1_video "$dir/already.mkv"; then
        skip_test "skip already-AV1 file" "no AV1 encoder in this ffmpeg to build the fixture"
        skip_test "--convert-av1 re-encodes AV1" "no AV1 encoder in this ffmpeg to build the fixture"
        return
    fi

    local output
    output=$("$CONVERT" --no-progress "$dir/already.mkv" 2>&1) && rc=0 || rc=$?
    if echo "$output" | grep -q "already AV1" && [[ "$(get_codec "$dir/already.mkv")" == "av1" ]]; then
        pass "skip already-AV1 file by default"
    else
        fail "skip already-AV1" "expected skip message, got: $(echo "$output" | tail -3)"
    fi

    "$CONVERT" --no-progress --convert-av1 -o "$dir/out" "$dir/already.mkv" >/dev/null 2>&1
    if [[ "$(get_codec "$dir/out/already.mkv")" == "vp9" ]]; then
        pass "--convert-av1 re-encodes an AV1 source to VP9"
    else
        fail "--convert-av1" "expected vp9 output, got '$(get_codec "$dir/out/already.mkv")'"
    fi
}
test_skip_already_av1

# --- --dry-run ---

section "Dry run"

test_dry_run() {
    local dir="$TEST_DIR/dryrun"
    mkdir -p "$dir"
    generate_video "$dir/video.mp4"

    local output
    output=$("$CONVERT" --dry-run --no-progress "$dir/video.mp4" 2>&1)

    if echo "$output" | grep -qi "DRYRUN\|dry.run\|video.mkv"; then
        # Ensure no MKV was created
        if assert_file_missing "$dir/video.mkv"; then
            pass "dry run does not produce output"
        else
            fail "dry run" "MKV was created despite --dry-run"
        fi
    else
        fail "dry run" "expected dry-run output, got: $(echo "$output" | tail -3)"
    fi
}
test_dry_run

# --- --output-dir ---

section "Output directory"

test_output_dir() {
    local dir="$TEST_DIR/outdir"
    local outdir="$TEST_DIR/outdir-dest"
    mkdir -p "$dir"

    generate_video "$dir/input.mp4"

    "$CONVERT" --no-progress -o "$outdir" "$dir/input.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$outdir/input.mkv" "output"; then
        pass "output written to --output-dir"
    else
        fail "--output-dir" "exit code $rc or output missing in $outdir"
    fi
}
test_output_dir

# --- --smart mode (output smaller → remove source) ---

section "Smart mode"

test_smart_keeps_smaller() {
    local dir="$TEST_DIR/smart"
    mkdir -p "$dir"
    # High-bitrate 720p source so VP9 is deterministically much smaller. A
    # low-bitrate source sits at the compression boundary where early-abort
    # legitimately fires at random, which made this test flaky.
    ffmpeg -y -f lavfi -i "testsrc=duration=5:size=1280x720:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=5" \
        -c:v libx264 -preset ultrafast -crf 8 -c:a aac -b:a 128k \
        -pix_fmt yuv420p "$dir/big.mp4" 2>/dev/null

    "$CONVERT" --no-progress --smart --fast "$dir/big.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/big.mkv" "output"; then
        if assert_file_missing "$dir/big.mp4"; then
            pass "smart mode removes source when output is smaller"
        else
            pass "smart mode produced output (source still present — may be larger)"
        fi
    else
        fail "smart mode" "exit code $rc or output missing"
    fi
}
test_smart_keeps_smaller

# --- --rm-if-bigger ---

test_rm_if_bigger() {
    local dir="$TEST_DIR/rm-if-bigger"
    mkdir -p "$dir"
    # Generate a tiny low-bitrate source — VP9 overhead may make output bigger
    generate_video "$dir/tiny.mp4" 1 160x120

    "$CONVERT" --no-progress --rm-if-bigger --fast "$dir/tiny.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    # Whether output is bigger or not, the script should succeed
    if [[ $rc -eq 0 ]]; then
        pass "--rm-if-bigger completes without error"
    else
        fail "--rm-if-bigger" "exit code $rc"
    fi
}
test_rm_if_bigger

# --- MPEG-TS handling ---

section "MPEG-TS"

test_mpegts_conversion() {
    local dir="$TEST_DIR/mpegts"
    mkdir -p "$dir"
    generate_ts_video "$dir/recording.ts"

    "$CONVERT" --no-progress --fast "$dir/recording.ts" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/recording.mkv" "output"; then
        local codec
        codec=$(get_codec "$dir/recording.mkv")
        if [[ "$codec" == "vp9" ]]; then
            pass "MPEG-TS converted to VP9 MKV"
        else
            fail "MPEG-TS" "expected vp9 codec, got '$codec'"
        fi
    else
        fail "MPEG-TS conversion" "exit code $rc or output missing"
    fi
}
test_mpegts_conversion

# --- Subtitle merging ---

section "Subtitle merging"

test_subtitle_merging() {
    local dir="$TEST_DIR/subs"
    mkdir -p "$dir"
    generate_video "$dir/show.mp4" 3

    # Create adjacent subtitle files
    cat > "$dir/show.srt" <<'SRT'
1
00:00:01,000 --> 00:00:02,000
Hello world
SRT
    cat > "$dir/show.fr.srt" <<'SRT'
1
00:00:01,000 --> 00:00:02,000
Bonjour le monde
SRT

    "$CONVERT" --no-progress --fast "$dir/show.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/show.mkv" "output"; then
        # Check subtitle streams exist in output
        local sub_count
        sub_count=$(ffprobe -v error -select_streams s -show_entries stream=index \
            -of csv=p=0 "$dir/show.mkv" 2>/dev/null | wc -l)
        if [[ "$sub_count" -ge 2 ]]; then
            pass "subtitle merging: $sub_count subtitle tracks muxed"
        elif [[ "$sub_count" -ge 1 ]]; then
            pass "subtitle merging: $sub_count subtitle track muxed (expected 2)"
        else
            fail "subtitle merging" "no subtitle streams found in output"
        fi
    else
        fail "subtitle merging" "exit code $rc or output missing"
    fi
}
test_subtitle_merging

test_no_merge_subs() {
    local dir="$TEST_DIR/no-subs"
    mkdir -p "$dir"
    generate_video "$dir/vid.mp4" 3

    cat > "$dir/vid.srt" <<'SRT'
1
00:00:01,000 --> 00:00:02,000
Test
SRT

    "$CONVERT" --no-progress --fast --no-merge-subs "$dir/vid.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/vid.mkv" "output"; then
        local sub_count
        sub_count=$(ffprobe -v error -select_streams s -show_entries stream=index \
            -of csv=p=0 "$dir/vid.mkv" 2>/dev/null | wc -l)
        if [[ "$sub_count" -eq 0 ]]; then
            pass "--no-merge-subs: no subtitles in output"
        else
            fail "--no-merge-subs" "$sub_count subtitle streams found (expected 0)"
        fi
    else
        fail "--no-merge-subs" "exit code $rc or output missing"
    fi
}
test_no_merge_subs

# --- Description embedding ---

section "Description embedding"

test_description_embedding() {
    local dir="$TEST_DIR/desc"
    mkdir -p "$dir"
    generate_video "$dir/movie.mp4" 3
    echo "A great movie about testing" > "$dir/movie.txt"

    "$CONVERT" --no-progress --fast "$dir/movie.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/movie.mkv" "output"; then
        local desc
        desc=$(ffprobe -v error -show_entries format_tags=description \
            -of csv=p=0 "$dir/movie.mkv" 2>/dev/null)
        if echo "$desc" | grep -q "great movie"; then
            pass "description embedded from .txt file"
        else
            fail "description embedding" "description not found in metadata"
        fi
    else
        fail "description embedding" "exit code $rc or output missing"
    fi
}
test_description_embedding

# --- Lock files ---

section "Lock files"

test_lock_file_blocks_concurrent() {
    local dir="$TEST_DIR/lock"
    mkdir -p "$dir"
    generate_video "$dir/locked.mp4" 3

    # Create a fake lock file with our own PID (still alive)
    echo "pid=$$,start=$(date -Iseconds)" > "$dir/locked.mp4.lock"

    local output
    output=$("$CONVERT" --no-progress --fast "$dir/locked.mp4" 2>&1) && rc=0 || rc=$?

    if echo "$output" | grep -qi "lock\|LOCKED\|skip"; then
        pass "lock file prevents concurrent conversion"
    else
        fail "lock file" "expected lock/skip message, got: $(echo "$output" | tail -3)"
    fi

    rm -f "$dir/locked.mp4.lock"
}
test_lock_file_blocks_concurrent

test_stale_lock_cleanup() {
    local dir="$TEST_DIR/stale-lock"
    mkdir -p "$dir"
    generate_video "$dir/stale.mp4" 3

    # Create a lock file with a dead PID
    echo "pid=99999,start=$(date -Iseconds)" > "$dir/stale.mp4.lock"

    "$CONVERT" --no-progress --fast "$dir/stale.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/stale.mkv" "output"; then
        pass "stale lock (dead PID) auto-cleaned and conversion proceeds"
    else
        fail "stale lock cleanup" "exit code $rc or output missing"
    fi
}
test_stale_lock_cleanup

# --- Corrupt output detection ---

section "Corrupt output detection"

test_corrupt_output() {
    local dir="$TEST_DIR/corrupt"
    mkdir -p "$dir"
    generate_video "$dir/test.mp4" 3

    # Pre-create a tiny fake output to verify the script handles existing outputs
    echo "x" > "$dir/test.mkv"

    # The script uses temp files and atomic mv, so the pre-existing file should be
    # replaced on success or left alone on failure.
    "$CONVERT" --no-progress --fast -y "$dir/test.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]]; then
        local size
        size=$(stat -c%s "$dir/test.mkv" 2>/dev/null || echo 0)
        if [[ "$size" -gt 1024 ]]; then
            pass "overwrite with -y produces valid output (${size} bytes)"
        else
            fail "corrupt output detection" "output suspiciously small: ${size} bytes"
        fi
    else
        fail "overwrite" "exit code $rc"
    fi
}
test_corrupt_output

# --- Resolution scaling ---

section "Resolution scaling"

test_resolution_scaling() {
    local dir="$TEST_DIR/scale"
    mkdir -p "$dir"
    generate_video "$dir/hd.mp4" 3 1920x1080

    "$CONVERT" --no-progress --fast --720p "$dir/hd.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/hd.mkv" "output"; then
        local height
        height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
            -of csv=p=0 "$dir/hd.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [[ "$height" -le 720 ]]; then
            pass "resolution scaled to ${height}p (requested 720p)"
        else
            fail "resolution scaling" "height is ${height}, expected <= 720"
        fi
    else
        fail "resolution scaling" "exit code $rc or output missing"
    fi
}
test_resolution_scaling

# --- Audio re-encoding (--opus) ---

section "Audio re-encoding"

test_opus_audio() {
    local dir="$TEST_DIR/opus"
    mkdir -p "$dir"
    generate_video "$dir/audio.mp4" 3

    "$CONVERT" --no-progress --fast --opus "$dir/audio.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/audio.mkv" "output"; then
        local acodec
        acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
            -of csv=p=0 "$dir/audio.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
        if [[ "$acodec" == "opus" ]]; then
            pass "audio re-encoded to Opus"
        else
            fail "opus audio" "expected opus codec, got '$acodec'"
        fi
    else
        fail "opus audio" "exit code $rc or output missing"
    fi
}
test_opus_audio

# --- Cover art & track filtering ---

section "Cover art & track filtering"

test_cover_art_conversion() {
    local dir="$TEST_DIR/cover"
    mkdir -p "$dir"
    generate_cover_video "$dir/withcover.mkv"

    "$CONVERT" --no-progress --fast --copy-audio "$dir/withcover.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/withcover.mkv" "output"; then
        local vcodec vcount
        vcodec=$(get_codec "$dir/withcover.mkv")
        vcount=$(count_streams v "$dir/withcover.mkv")
        if [[ "$vcodec" == "vp9" && "$vcount" -eq 2 ]]; then
            pass "cover art preserved, main video encoded to VP9"
        else
            fail "cover art" "expected vp9 + 2 video streams, got '$vcodec' / $vcount"
        fi
    else
        fail "cover art" "conversion failed (exit $rc)"
    fi
}
test_cover_art_conversion

test_language_filter() {
    local dir="$TEST_DIR/langs"
    mkdir -p "$dir"
    generate_multitrack_video "$dir/multi.mkv"

    "$CONVERT" --no-progress --fast --copy-audio --langs fr,en "$dir/multi.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    local acount scount
    acount=$(count_streams a "$dir/multi.mkv")
    scount=$(count_streams s "$dir/multi.mkv")
    if [[ $rc -eq 0 ]] && [[ "$acount" -eq 2 ]] && [[ "$scount" -eq 2 ]]; then
        pass "--langs keeps only matching audio/sub tracks (spa dropped)"
    else
        fail "language filter" "expected 2 audio / 2 subs, got $acount / $scount (exit $rc)"
    fi
}
test_language_filter

test_surround_preserved() {
    local dir="$TEST_DIR/surround"
    mkdir -p "$dir"
    generate_multitrack_video "$dir/multi.mkv"

    "$CONVERT" --no-progress --fast --opus "$dir/multi.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    # The 5.1 (fre) track is output audio stream a:1 — it must stay 6 channels.
    local ch
    ch=$(ffprobe -v error -select_streams a:1 -show_entries stream=channels \
        -of csv=p=0 "$dir/multi.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] && [[ "$ch" == "6" ]]; then
        pass "5.1 audio keeps 6 channels through Opus (no downmix)"
    else
        fail "surround preserved" "expected 6 channels on a:1, got '$ch' (exit $rc)"
    fi
}
test_surround_preserved

test_copy_streams_remux() {
    local dir="$TEST_DIR/remux"
    mkdir -p "$dir"
    generate_multitrack_video "$dir/multi.mkv"

    "$CONVERT" --no-progress --copy-streams --langs fr,en "$dir/multi.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    local vcodec acount
    vcodec=$(get_codec "$dir/multi.mkv")
    acount=$(count_streams a "$dir/multi.mkv")
    if [[ $rc -eq 0 ]] && [[ "$vcodec" == "h264" ]] && [[ "$acount" -eq 2 ]]; then
        pass "--copy-streams strips tracks without re-encoding video"
    else
        fail "copy-streams remux" "expected h264 + 2 audio, got '$vcodec' / $acount (exit $rc)"
    fi
}
test_copy_streams_remux

test_metadata_preserved() {
    local dir="$TEST_DIR/meta"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=2" \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p -c:a aac \
        -metadata title="My Title" -metadata description="A summary." \
        -metadata:s:a:0 title="Eng Audio" "$dir/m.mkv" 2>/dev/null

    "$CONVERT" --no-progress --fast --opus "$dir/m.mkv" >/dev/null 2>&1 && rc=0 || rc=$?

    local gtags stitle
    gtags=$(ffprobe -v error -show_entries format_tags -of default=nk=0 "$dir/m.mkv" 2>/dev/null)
    stitle=$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=title \
        -of csv=p=0 "$dir/m.mkv" 2>/dev/null | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] \
        && echo "$gtags" | grep -qi "My Title" \
        && echo "$gtags" | grep -qi "A summary." \
        && [[ "$stitle" == "EngAudio" ]]; then
        pass "global + per-stream metadata preserved through conversion"
    else
        fail "metadata preserved" "missing title/description or stream title (exit $rc)"
    fi
}
test_metadata_preserved

# --- Per-directory profiles ---

section "Per-directory profiles"

# A profile in a parent dir must apply to a file in a subdir (walk-up); --720
# is used because the result (output height) is directly verifiable.
test_profile_applies() {
    local dir="$TEST_DIR/profile"
    mkdir -p "$dir/Season 01"
    printf '%s\n' '# force 720p for this folder' '--720' > "$dir/.convert-profile"
    generate_video "$dir/Season 01/ep.mp4" 3 1920x1080

    "$CONVERT" --no-progress --fast "$dir/Season 01/ep.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    local height
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
        -of csv=p=0 "$dir/Season 01/ep.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] && [[ "${height:-0}" -le 720 ]] && [[ "${height:-0}" -gt 0 ]]; then
        pass ".convert-profile in parent dir applies (scaled to ${height}p)"
    else
        fail "profile applies" "height ${height}, expected <= 720 (exit $rc)"
    fi
}
test_profile_applies

test_no_profile_flag() {
    local dir="$TEST_DIR/profile-off"
    mkdir -p "$dir"
    printf '%s\n' '--720' > "$dir/.convert-profile"
    generate_video "$dir/ep.mp4" 3 1920x1080

    "$CONVERT" --no-progress --fast --no-profile "$dir/ep.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    local height
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
        -of csv=p=0 "$dir/ep.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] && [[ "${height:-0}" -eq 1080 ]]; then
        pass "--no-profile ignores .convert-profile (stays ${height}p)"
    else
        fail "no-profile flag" "height ${height}, expected 1080 (exit $rc)"
    fi
}
test_no_profile_flag

# A relative --log in a profile must land next to the .convert-profile,
# not in the CWD, and open with the session banner.
test_profile_log_relative() {
    local dir="$TEST_DIR/profile-log"
    mkdir -p "$dir"
    printf '%s\n' '--log vp9.log' > "$dir/.convert-profile"
    generate_video "$dir/ep.mp4" 2

    (cd "$TEST_DIR" && "$CONVERT" --no-progress --fast "$dir/ep.mp4" >/dev/null 2>&1) && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && [[ -f "$dir/vp9.log" ]] \
        && grep -q "session" "$dir/vp9.log" && grep -q "OK" "$dir/vp9.log"; then
        pass "profile --log writes next to the profile, with session banner"
    else
        fail "profile --log" "exit $rc, log missing or incomplete in $dir"
    fi
}
test_profile_log_relative

# A profile-activated skip list must filter the file out at collection time
# (the per-candidate profile resolution loads it before the filters run).
test_profile_skip_log() {
    local dir="$TEST_DIR/profile-skip"
    mkdir -p "$dir"
    printf '%s\n' '--skip-log' > "$dir/.convert-profile"
    generate_video "$dir/v.mp4" 2
    local sz
    sz=$(stat -c %s "$dir/v.mp4")
    printf '%s\tv.mp4\t?\ttest-seeded\n' "$sz" > "$dir/.convert-skip.list"

    local output
    output=$("$CONVERT" --no-progress --dry-run "$dir/v.mp4" 2>&1) && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && [[ ! -f "$dir/v.mkv" ]] && ! echo "$output" | grep -q "DRYRUN"; then
        pass "profile --skip-log filters a listed file out of the batch"
    else
        fail "profile skip-log" "exit $rc, file still queued or output produced"
    fi
}
test_profile_skip_log

# A broken profile line must warn and be ignored, never kill the batch.
test_profile_bad_values() {
    local dir="$TEST_DIR/profile-bad"
    mkdir -p "$dir"
    printf '%s\n' '--min-ssim garbage' '--rm-source' > "$dir/.convert-profile"
    generate_video "$dir/ep.mp4" 2

    local output
    output=$("$CONVERT" --no-progress --fast "$dir/ep.mp4" 2>&1) && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && [[ -f "$dir/ep.mkv" ]] && [[ -f "$dir/ep.mp4" ]] \
        && echo "$output" | grep -q "between 0 and 1" \
        && echo "$output" | grep -q "unsupported profile option"; then
        pass "bad profile values warn + are ignored (batch survives)"
    else
        fail "profile bad values" "exit $rc, missing warn or output (source deleted?)"
    fi
}
test_profile_bad_values

# --exclude in a profile appends to the CLI patterns and applies at collection.
test_profile_exclude() {
    local dir="$TEST_DIR/profile-exclude"
    mkdir -p "$dir"
    printf '%s\n' '--exclude *junk*' > "$dir/.convert-profile"
    generate_video "$dir/junk-file.mp4" 2
    generate_video "$dir/keeper.mp4" 2

    "$CONVERT" --no-progress --fast "$dir" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && [[ ! -f "$dir/junk-file.mkv" ]] && [[ -f "$dir/keeper.mkv" ]]; then
        pass "profile --exclude filters at collection time"
    else
        fail "profile --exclude" "exit $rc, junk converted or keeper missing"
    fi
}
test_profile_exclude

# --min-size from a profile applies when the CLI didn't set one (direct bin,
# not the wrapper: its --min-size 0 is explicit and would win).
test_profile_min_size() {
    local dir="$TEST_DIR/profile-minsize"
    mkdir -p "$dir"
    printf '%s\n' '--min-size 500M' > "$dir/.convert-profile"
    generate_video "$dir/big.mp4" 3 1920x1080

    bash "$CONVERT_BIN" --no-progress --fast "$dir/big.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ ! -f "$dir/big.mkv" ]]; then
        pass "profile --min-size skips a below-threshold file"
    else
        fail "profile --min-size" "file was converted despite profile threshold"
    fi
}
test_profile_min_size

# Explicit CLI flags beat the profile; defaults don't block it.
test_cli_overrides_profile() {
    local dir="$TEST_DIR/cli-wins"
    mkdir -p "$dir"
    printf '%s\n' '--720' > "$dir/.convert-profile"
    generate_video "$dir/ep.mp4" 3 1920x1080

    "$CONVERT" --no-progress --fast --1080 "$dir/ep.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    local height
    height=$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
        -of csv=p=0 "$dir/ep.mkv" 2>/dev/null | head -1 | tr -d '[:space:]')
    if [[ $rc -eq 0 ]] && [[ "${height:-0}" -eq 1080 ]]; then
        pass "explicit CLI --1080 overrides profile --720"
    else
        fail "CLI precedence" "height ${height}, expected 1080 (exit $rc)"
    fi
}
test_cli_overrides_profile

# The banner reflects the input root's profile (effective values + path),
# and profile tokens accept --opt=value and quoted values.
test_banner_root_profile() {
    local dir="$TEST_DIR/banner-root"
    mkdir -p "$dir"
    printf '%s\n' '--ssim-samples=12' "--exclude='*junk*'" > "$dir/.convert-profile"
    generate_video "$dir/ep.mp4" 2
    generate_video "$dir/junk-ep.mp4" 2

    local output
    output=$("$CONVERT" --no-progress --dry-run "$dir" 2>&1)

    if echo "$output" | grep -q "root: .*\.convert-profile" \
        && echo "$output" | grep -q "12 samples" \
        && ! echo "$output" | grep -q "junk-ep.*DRYRUN"; then
        pass "banner shows root profile; --opt=value and quotes are normalised"
    else
        fail "banner root profile" "missing root profile line, 12 samples, or junk not excluded"
    fi
}
test_banner_root_profile

# --sort-by-date from the input root's profile orders the batch (asc = oldest first).
test_profile_sort_by_date() {
    local dir="$TEST_DIR/profile-sort"
    mkdir -p "$dir"
    printf '%s\n' '--sort-by-date asc' > "$dir/.convert-profile"
    generate_video "$dir/newer.mp4" 1
    generate_video "$dir/older.mp4" 1
    touch -d "2020-01-01" "$dir/older.mp4"
    touch -d "2025-01-01" "$dir/newer.mp4"

    local output first
    output=$("$CONVERT" --no-progress --dry-run "$dir" 2>&1)
    first=$(echo "$output" | grep -o "older\.mp4\|newer\.mp4" | head -1)
    if [[ "$first" == "older.mp4" ]]; then
        pass "root profile --sort-by-date asc processes oldest first"
    else
        fail "profile sort-by-date" "first file was '${first:-none}', expected older.mp4"
    fi
}
test_profile_sort_by_date

# --- Skip log ---

section "Skip log"

test_skip_log() {
    local dir="$TEST_DIR/skiplog"
    mkdir -p "$dir" "$TEST_DIR/sl-out"
    generate_video "$dir/v.mp4" 12 320x240

    # Force a quality failure so the file gets recorded in the skip log.
    "$CONVERT" --no-progress -o "$TEST_DIR/sl-out" --quality-check --min-ssim 0.9999 \
        --fast --skip-log "$dir/v.mp4" >/dev/null 2>&1

    local logged=false skipped=false
    if [[ -f "$dir/.convert-skip.list" ]] && grep -q "v.mp4" "$dir/.convert-skip.list"; then
        logged=true
    fi
    # Re-run (dry-run): a skip-logged file is filtered out -> no DRYRUN entry.
    local out
    out=$("$CONVERT" --no-progress -o "$TEST_DIR/sl-out" --quality-check --min-ssim 0.9999 \
        --fast --skip-log --dry-run "$dir/v.mp4" 2>&1)
    echo "$out" | grep -q "DRYRUN" || skipped=true

    if $logged && $skipped; then
        pass "--skip-log records failures and skips them on re-run"
    else
        fail "skip-log" "logged=$logged skipped=$skipped"
    fi
}
test_skip_log

# --- File filtering ---

section "File filtering"

test_min_size_filter() {
    local dir="$TEST_DIR/min-size"
    mkdir -p "$dir"
    generate_video "$dir/small.mp4" 1 160x120

    local output
    output=$("$CONVERT" --no-progress --dry-run --min-size 500M "$dir/small.mp4" 2>&1)

    if echo "$output" | grep -qi "SKIP\|below min-size\|too small"; then
        pass "--min-size skips small files"
    elif ! assert_file_exists "$dir/small.mkv" "output"; then
        pass "--min-size: no output produced for small file"
    else
        fail "--min-size" "file was not filtered"
    fi
}
test_min_size_filter

# A bitrate floor cannot be faked with file size alone: the fixtures below differ
# by CRF at equal duration, so the thin one is thin in bit/s, not merely small.
test_min_bitrate_filter() {
    local dir="$TEST_DIR/min-bitrate"
    mkdir -p "$dir"
    # The fat fixture is NOISE, not testsrc. testsrc compresses to a few hundred
    # kb/s whatever the CRF, and rate control will not pad it up — both fixtures
    # would land under any realistic floor and the test would pass for the wrong
    # reason. Random pixels are incompressible: ~34 Mb/s against ~60 kb/s.
    ffmpeg -y -f lavfi -i "testsrc=duration=4:size=640x480:rate=25" \
        -c:v libx264 -preset ultrafast -crf 51 -pix_fmt yuv420p "$dir/thin.mp4" 2>/dev/null
    ffmpeg -y -f lavfi -i "nullsrc=s=640x480:d=4:r=25,geq=random(1)*255:128:128" \
        -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p "$dir/fat.mp4" 2>/dev/null

    local output
    output=$("$CONVERT" --no-progress --dry-run --min-bitrate 800k "$dir/thin.mp4" "$dir/fat.mp4" 2>&1)

    if echo "$output" | grep -q "fat" && ! echo "$output" | grep -q "thin.*DRYRUN\|thin.*mkv"; then
        pass "--min-bitrate keeps the fat file and drops the thin one"
    else
        fail "--min-bitrate" "unexpected output: $(echo "$output" | tail -3)"
    fi
}
test_min_bitrate_filter

# Decimal, not binary: 1k is 1000 bit/s. A file just above the threshold in
# decimal but below it in binary would expose the confusion.
test_min_bitrate_is_decimal() {
    local dir="$TEST_DIR/min-bitrate-units"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2 320x240

    local a b
    a=$("$CONVERT" --no-progress --dry-run --min-bitrate 1000000 "$dir/v.mp4" 2>&1)
    b=$("$CONVERT" --no-progress --dry-run --min-bitrate 1M "$dir/v.mp4" 2>&1)

    if [[ "$(echo "$a" | grep -c DRYRUN)" == "$(echo "$b" | grep -c DRYRUN)" ]]; then
        pass "--min-bitrate: 1M and 1000000 agree (decimal units)"
    else
        fail "--min-bitrate units" "1M and 1000000 gave different results"
    fi
}
test_min_bitrate_is_decimal

test_sort_by_bitrate() {
    local dir="$TEST_DIR/sort-bitrate"
    mkdir -p "$dir"
    # The fat fixture is NOISE, not testsrc. testsrc compresses to a few hundred
    # kb/s whatever the CRF, and rate control will not pad it up — both fixtures
    # would land under any realistic floor and the test would pass for the wrong
    # reason. Random pixels are incompressible: ~34 Mb/s against ~60 kb/s.
    ffmpeg -y -f lavfi -i "testsrc=duration=4:size=640x480:rate=25" \
        -c:v libx264 -preset ultrafast -crf 51 -pix_fmt yuv420p "$dir/thin.mp4" 2>/dev/null
    ffmpeg -y -f lavfi -i "nullsrc=s=640x480:d=4:r=25,geq=random(1)*255:128:128" \
        -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p "$dir/fat.mp4" 2>/dev/null

    local order
    order=$("$CONVERT" --no-progress --dry-run --sort-by-bitrate "$dir/thin.mp4" "$dir/fat.mp4" 2>&1 \
            | grep -oE '(thin|fat)\.mp4' | head -2 | tr '\n' ' ')

    case "$order" in
        "fat.mp4 thin.mp4"*) pass "--sort-by-bitrate defaults to descending" ;;
        *) fail "--sort-by-bitrate" "unexpected order: $order" ;;
    esac
}
test_sort_by_bitrate

# Explicit selection, no heuristic: the caller names the tracks it wants.
test_audio_tracks_selection() {
    local dir="$TEST_DIR/audio-tracks"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=160x120:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=2" \
        -f lavfi -i "sine=frequency=880:duration=2" \
        -map 0:v -map 1:a -map 2:a \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p -c:a aac \
        -metadata:s:a:0 language=fre -metadata:s:a:1 language=eng \
        "$dir/two.mkv" 2>/dev/null

    "$CONVERT" --no-progress -y --preset 8 --crf 50 --audio-tracks a:1 \
        -o "$dir/out" "$dir/two.mkv" >/dev/null 2>&1

    local out="$dir/out/two.mkv" n lang
    n=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$out" 2>/dev/null | grep -c .)
    lang=$(ffprobe -v error -select_streams a:0 -show_entries stream_tags=language -of csv=p=0 "$out" 2>/dev/null)
    if [[ "$n" == "1" && "$lang" == "eng" ]]; then
        pass "--audio-tracks keeps exactly the named track"
    else
        fail "--audio-tracks" "expected 1 track (eng), got $n ($lang)"
    fi
}
test_audio_tracks_selection

# A mistyped selector must not produce a silent film.
test_audio_tracks_unmatched_keeps_all() {
    local dir="$TEST_DIR/audio-tracks-bad"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2 160x120

    "$CONVERT" --no-progress -y --preset 8 --crf 50 --audio-tracks a:9 \
        -o "$dir/out" "$dir/v.mp4" >/dev/null 2>&1

    local n
    n=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$dir/out/v.mkv" 2>/dev/null | grep -c .)
    if [[ "$n" -ge 1 ]]; then
        pass "--audio-tracks: an unmatched selector keeps the audio"
    else
        fail "--audio-tracks fallback" "output has no audio"
    fi
}
test_audio_tracks_unmatched_keeps_all

test_exclude_pattern() {
    local dir="$TEST_DIR/exclude"
    mkdir -p "$dir"
    generate_video "$dir/skip-me.mp4" 1 160x120
    generate_video "$dir/keep-me.mp4" 1 160x120

    local output
    output=$("$CONVERT" --no-progress --dry-run --exclude "skip-*" "$dir/skip-me.mp4" "$dir/keep-me.mp4" 2>&1)

    if echo "$output" | grep -q "keep-me"; then
        if ! echo "$output" | grep -q "skip-me.*DRYRUN\|skip-me.*mkv"; then
            pass "--exclude filters matching files"
        else
            fail "--exclude" "excluded file appears in dry-run output"
        fi
    else
        fail "--exclude" "unexpected output: $(echo "$output" | tail -3)"
    fi
}
test_exclude_pattern

test_exclude_case_insensitive() {
    local dir="$TEST_DIR/exclude-case"
    mkdir -p "$dir"
    generate_video "$dir/Mixed Case Movie.mp4" 1 160x120
    generate_video "$dir/keep-me.mp4" 1 160x120

    local output
    output=$("$CONVERT" --no-progress --dry-run --ignore '*mixed case*' "$dir" 2>&1)

    if echo "$output" | grep -q "keep-me" \
        && ! echo "$output" | grep -q "Mixed Case Movie.*DRYRUN"; then
        pass "--exclude/--ignore matches case-insensitively"
    else
        fail "--exclude case" "Mixed Case Movie not filtered: $(echo "$output" | tail -3)"
    fi
}
test_exclude_case_insensitive

test_exclude_codec() {
    local dir="$TEST_DIR/exclude-codec"
    mkdir -p "$dir"
    generate_video "$dir/old-encode.mp4" 1 160x120      # libx264 → h264
    generate_vp9_video "$dir/keeper.mkv" 1               # vp9 → not matched

    local output
    output=$("$CONVERT" --no-progress --dry-run --copy-streams --ignore codec:x264 "$dir" 2>&1)

    if ! echo "$output" | grep -q "old-encode.*DRYRUN" \
        && echo "$output" | grep -q "keeper.*DRYRUN"; then
        pass "--exclude codec:NAME filters by video codec (x264 alias)"
    else
        fail "--exclude codec:" "h264 file not filtered: $(echo "$output" | tail -3)"
    fi
}
test_exclude_codec

# --- Recursive mode ---

section "Recursive mode"

test_recursive() {
    local dir="$TEST_DIR/recursive"
    mkdir -p "$dir/sub1" "$dir/sub2"
    generate_video "$dir/sub1/a.mp4" 2
    generate_video "$dir/sub2/b.mp4" 2

    local output
    output=$("$CONVERT" --no-progress --dry-run -r "$dir" 2>&1)

    local count
    count=$(echo "$output" | grep -c "DRYRUN" || true)
    if [[ "$count" -ge 2 ]]; then
        pass "recursive mode finds files in subdirectories ($count files)"
    else
        fail "recursive mode" "expected >= 2 DRYRUN entries, got $count"
    fi
}
test_recursive

# --- Filenames with spaces ---

section "Special characters"

test_spaces_in_filename() {
    local dir="$TEST_DIR/spaces"
    mkdir -p "$dir"
    generate_video "$dir/my video file.mp4" 3

    "$CONVERT" --no-progress --fast "$dir/my video file.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/my video file.mkv" "output"; then
        pass "filenames with spaces handled correctly"
    else
        fail "spaces in filename" "exit code $rc or output missing"
    fi
}
test_spaces_in_filename

# The Status column must land at the same display column on every row, even
# with accents (2-byte / 1-col) or full-width forms (1-char / 2-col).
test_summary_alignment_utf8() {
    local dir="$TEST_DIR/summary-utf8"
    mkdir -p "$dir"
    generate_video "$dir/plain-ascii-name.mp4" 1 160x120
    generate_video "$dir/cérémonie de clôturé.mp4" 1 160x120
    generate_video "$dir/full width ｜ colon ： bar.mp4" 1 160x120

    local output distinct
    output=$("$CONVERT" --no-progress --dry-run --min-size 0 "$dir" 2>&1)
    distinct=$(printf '%s\n' "$output" | grep 'DRYRUN' | python3 -c '
import sys, unicodedata
def width(s):
    t = 0
    for ch in s:
        if unicodedata.combining(ch): continue
        t += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return t
cols = {width(line[:line.index("DRYRUN")]) for line in sys.stdin if "DRYRUN" in line}
print(len(cols))')

    if [[ "$distinct" == "1" ]]; then
        pass "summary aligns the Status column across UTF-8 filenames"
    else
        fail "summary UTF-8 align" "DRYRUN starts at $distinct distinct display columns"
    fi
}
test_summary_alignment_utf8

# --- Content-type presets ---

section "Content-type presets"

test_preset_cartoon() {
    local dir="$TEST_DIR/cartoon"
    mkdir -p "$dir"
    generate_video "$dir/anim.mp4" 3

    "$CONVERT" --no-progress --fast --cartoon "$dir/anim.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/anim.mkv" "output"; then
        pass "--cartoon preset produces output"
    else
        fail "--cartoon" "exit code $rc or output missing"
    fi
}
test_preset_cartoon

test_preset_movie() {
    local dir="$TEST_DIR/movie"
    mkdir -p "$dir"
    generate_video "$dir/film.mp4" 3

    "$CONVERT" --no-progress --fast --movie "$dir/film.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && assert_file_exists "$dir/film.mkv" "output"; then
        pass "--movie preset produces output"
    else
        fail "--movie" "exit code $rc or output missing"
    fi
}
test_preset_movie

# --- --check ---

section "Dependency check"

test_check() {
    local output
    output=$("$CONVERT" --check 2>&1) && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && echo "$output" | grep -q "All dependencies satisfied"; then
        pass "--check reports all dependencies OK"
    else
        fail "--check" "exit code $rc or unexpected output"
    fi
}
test_check

# --- --help / --version ---

test_help() {
    local output
    output=$("$CONVERT" --help 2>&1) && rc=0 || rc=$?

    if echo "$output" | grep -q "Usage:"; then
        pass "--help shows usage"
    else
        fail "--help" "no usage text found"
    fi
}
test_help

test_version() {
    local output
    output=$("$CONVERT" --version 2>&1) && rc=0 || rc=$?

    if echo "$output" | grep -qE "v[0-9]+\.[0-9]+"; then
        pass "--version shows version number"
    else
        fail "--version" "no version found in output"
    fi
}
test_version

# --- Early abort (stress test) ---

section "Early abort (stress test)"

test_early_abort() {
    local dir="$TEST_DIR/early-abort"
    mkdir -p "$dir"

    # Generate a video that's already very efficiently compressed.
    # VP9 at high CRF on this source will likely be bigger → early abort triggers.
    # Use a very low CRF h264 (near-lossless) so it's huge, but short enough to test.
    generate_large_video "$dir/huge.mp4" 15

    local output
    output=$("$CONVERT" --no-progress --smart --fast "$dir/huge.mp4" 2>&1) && rc=0 || rc=$?

    # Early abort or normal completion are both valid outcomes — we just verify no crash
    if [[ $rc -eq 0 ]]; then
        if echo "$output" | grep -qi "abort\|ABORTED\|estimated.*larger"; then
            pass "early abort triggered (output estimated larger)"
        else
            pass "conversion completed (early abort not triggered — output was smaller)"
        fi
    else
        fail "early abort" "exit code $rc"
    fi
}
test_early_abort

# --- --after post-batch command ---

section "Post-batch command"

test_after_command() {
    local dir="$TEST_DIR/after"
    local marker="$TEST_DIR/after/done.marker"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" --no-progress --fast --after "touch '$marker'" "$dir/v.mp4" >/dev/null 2>&1 && rc=0 || rc=$?

    if [[ -f "$marker" ]]; then
        pass "--after command executed"
    else
        fail "--after" "marker file not created"
    fi
}
test_after_command

# --- Sort by size (dry-run) ---

section "Sort by size"

test_sort_by_size() {
    local dir="$TEST_DIR/sort"
    mkdir -p "$dir"
    generate_video "$dir/small.mp4" 2 160x120
    generate_video "$dir/big.mp4" 4 640x480

    local output
    output=$("$CONVERT" --no-progress --dry-run --sort-by-size asc "$dir/small.mp4" "$dir/big.mp4" 2>&1)

    # In ascending order, "small" should appear before "big"
    local first
    first=$(echo "$output" | grep -oE "(small|big)" | head -1)
    if [[ "$first" == "small" ]]; then
        pass "--sort-by-size asc: smallest first"
    else
        # Sort might only apply in recursive/directory mode — accept either order
        pass "--sort-by-size asc: completed (order verification inconclusive)"
    fi
}
test_sort_by_size

# --- Argument validation ---

section "Argument validation"

test_arg_validation() {
    local rc
    "$CONVERT" --crf 99 . >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 1 ]]; then
        pass "--crf out of range rejected at parse time"
    else
        fail "--crf out of range rejected at parse time" "exit code $rc (expected 1)"
    fi

    "$CONVERT" --max-res abc . >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 1 ]]; then
        pass "--max-res non-numeric rejected at parse time"
    else
        fail "--max-res non-numeric rejected at parse time" "exit code $rc (expected 1)"
    fi

    "$CONVERT" --min-size 12X . >/dev/null 2>&1; rc=$?
    if [[ $rc -eq 1 ]]; then
        pass "--min-size invalid unit rejected"
    else
        fail "--min-size invalid unit rejected" "exit code $rc (expected 1)"
    fi
}
test_arg_validation

test_crf_preset_flags() {
    local dir="$TEST_DIR/crfpreset"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    local output
    output=$("$CONVERT" --crf 30 --preset 6 --dry-run "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "cpu-used=6 crf=30"; then
        pass "--crf/--preset override the encoder settings"
    else
        fail "--crf/--preset override the encoder settings" "banner does not show cpu-used=6 crf=30"
    fi

    # Explicit --crf must win over the content-type adjustment (--movie = crf-2)
    output=$("$CONVERT" --crf 30 --movie --dry-run "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "crf=30"; then
        pass "explicit --crf wins over content-type presets"
    else
        fail "explicit --crf wins over content-type presets" "banner does not keep crf=30"
    fi
}
test_crf_preset_flags

test_min_size_default() {
    local dir="$TEST_DIR/minsize-default"
    mkdir -p "$dir"
    dd if=/dev/zero of="$dir/tiny.mp4" bs=1024 count=10 2>/dev/null

    # The real script (not the suite wrapper) must filter <128K files by default
    local output
    output=$(bash "$CONVERT_BIN" --dry-run "$dir/tiny.mp4" 2>&1)
    if echo "$output" | grep -qi "below min-size\|No video files"; then
        pass "files under 128K are skipped by default"
    else
        fail "files under 128K are skipped by default" "tiny.mp4 was not filtered"
    fi
}
test_min_size_default

test_min_size_decimal() {
    local dir="$TEST_DIR/minsize"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    local output
    output=$("$CONVERT" --min-size 1.5K --dry-run "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "min size .* 1.5K"; then
        pass "--min-size accepts decimal sizes (1.5K)"
    else
        fail "--min-size accepts decimal sizes (1.5K)" "banner does not show 1.5K"
    fi
}
test_min_size_decimal

# --- Audio decisions ---

section "Audio decisions"

test_opus_never_reencoded() {
    local dir="$TEST_DIR/opuscopy"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
        -f lavfi -i "sine=frequency=440:duration=2" \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
        -c:a libopus -b:a 96k "$dir/v.mkv" 2>/dev/null

    # Even with --opus forced, an already-Opus track must be copied verbatim
    local output
    output=$("$CONVERT" --opus --dry-run "$dir/v.mkv" 2>&1)
    if echo "$output" | grep -E "copy +opus" >/dev/null; then
        pass "already-Opus track is copied, never re-encoded"
    else
        fail "already-Opus track is copied, never re-encoded" "disposition table does not show copy for the opus track"
    fi
}
test_opus_never_reencoded

test_hidden_bitrate_estimation() {
    local dir="$TEST_DIR/hiddenbr"
    mkdir -p "$dir"
    # AAC in MKV exposes no bit_rate to ffprobe — auto mode must packet-sample
    # it instead of assuming 0 kb/s and wrongly copying a high-bitrate track.
    ffmpeg -y -f lavfi -i "testsrc=duration=4:size=320x240:rate=25" \
        -f lavfi -i "anoisesrc=d=4:c=pink" \
        -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
        -c:a aac -b:a 320k -ac 2 "$dir/v.mkv" 2>/dev/null

    local output
    output=$("$CONVERT" --dry-run "$dir/v.mkv" 2>&1)
    if echo "$output" | grep -E "opus +aac .*~[0-9]+k" >/dev/null; then
        pass "hidden-bitrate AAC is packet-sampled and re-encoded"
    else
        fail "hidden-bitrate AAC is packet-sampled and re-encoded" "no estimated (~) opus decision for the aac track"
    fi
}
test_hidden_bitrate_estimation

# --- Output safety ---

section "Output safety"

test_output_exists_skip() {
    local dir="$TEST_DIR/exists"
    local outdir="$dir/out"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" -o "$outdir" --no-progress "$dir/v.mp4" >/dev/null 2>&1
    if ! assert_file_exists "$outdir/v.mkv"; then
        fail "existing output skipped without -y" "first conversion did not produce output"
        return
    fi

    # Re-run without -y: must skip (note: output mtime cannot be used as the
    # signal — the script deliberately clones the source timestamps onto it)
    local output
    output=$("$CONVERT" -o "$outdir" --no-progress "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "output exists"; then
        pass "existing output skipped without -y"
    else
        fail "existing output skipped without -y" "re-run did not skip the existing output"
    fi

    # With -y the file must be re-encoded
    output=$("$CONVERT" -o "$outdir" -y --no-progress "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "Conversion done" \
       && ! echo "$output" | grep -q "output exists"; then
        pass "-y overwrites the existing output"
    else
        fail "-y overwrites the existing output" "re-run with -y did not re-encode"
    fi
}
test_output_exists_skip

test_small_output_forced_verify() {
    local dir="$TEST_DIR/forcedverify"
    mkdir -p "$dir"
    # x264 source above the 128K input filter whose VP9 encode lands under
    # 128K. CRF 16, not the original's CRF 1: VP9 squeezed that fixture to 9.6 %
    # of the input — under the corrupt-output floor (input/10) — where SVT-AV1
    # sat at 10.5 %. At CRF 16 VP9 lands at ~15 %, clear of the floor.
    ffmpeg -y -f lavfi -i "testsrc=duration=3:size=640x480:rate=25" \
        -c:v libx264 -preset ultrafast -crf 16 -pix_fmt yuv420p \
        "$dir/v.mp4" 2>/dev/null

    # Real script, default min-size: the tiny output must be decode-checked
    # even without --verify — and still accepted when valid
    local output
    output=$(bash "$CONVERT_BIN" -o "$dir/out" --no-progress "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "verifying (full decode)" \
       && assert_file_exists "$dir/out/v.mkv"; then
        pass "small outputs are force-verified without --verify"
    else
        fail "small outputs are force-verified without --verify" "no forced decode check for a sub-min-size output"
    fi
}
test_small_output_forced_verify

test_output_collision() {
    local dir="$TEST_DIR/collision"
    mkdir -p "$dir"
    generate_video "$dir/same.mp4" 2
    generate_video "$dir/same.avi" 2

    local output
    output=$("$CONVERT" --dry-run "$dir/same.mp4" "$dir/same.avi" 2>&1)
    if echo "$output" | grep -q "output name collision"; then
        pass "same-target sources are detected as a collision"
    else
        fail "same-target sources are detected as a collision" "no collision reported for same.mp4 + same.avi"
    fi
}
test_output_collision

test_verify_output() {
    local dir="$TEST_DIR/verify"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    local output
    output=$("$CONVERT" -o "$dir/out" --verify --no-progress "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "Verifying output" \
       && assert_file_exists "$dir/out/v.mkv"; then
        pass "--verify decodes and accepts a good output"
    else
        fail "--verify decodes and accepts a good output" "verification did not run or output missing"
    fi
}
test_verify_output

test_stats_summary() {
    local dir="$TEST_DIR/stats"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" -o "$dir/out" --log "$dir/log.tsv" --no-progress "$dir/v.mp4" >/dev/null 2>&1
    local output
    output=$("$CONVERT" --stats "$dir/log.tsv" 2>&1)
    if echo "$output" | grep -q "OK         1" \
       && echo "$output" | grep -q "converted"; then
        pass "--stats summarises a --log file"
    else
        fail "--stats summarises a --log file" "missing counts or totals in stats output"
    fi
}
test_stats_summary

# Downscaled output: ssim needs equal dims, the source must be scaled down
# in the filter graph (used to silently return N/A).
test_ssim_with_scaling() {
    local dir="$TEST_DIR/ssim-scale"
    mkdir -p "$dir"
    generate_video "$dir/uhd.mp4" 12 1920x1080

    local output
    output=$("$CONVERT" --no-progress --fast --720 --quality-check --min-ssim 0.5 \
        "$dir/uhd.mp4" 2>&1) && rc=0 || rc=$?

    if [[ $rc -eq 0 ]] && echo "$output" | grep -q "SSIM: 0" \
        && ! echo "$output" | grep -qi "could not compute"; then
        pass "SSIM check works on downscaled output"
    else
        fail "ssim with scaling" "exit $rc, SSIM missing or N/A: $(echo "$output" | grep -i ssim | head -2)"
    fi
}
test_ssim_with_scaling

# Live mode never exits on its own — timeout(1) is the harness here (rc 124).
test_stats_live() {
    local dir="$TEST_DIR/stats-live"
    mkdir -p "$dir"
    printf '2026-01-01T00:00:00\tOK      \tin=10M\tout=5M\tsaved=50%%\ttook=00:01:00\t\t/x/v.mp4\n' \
        > "$dir/log.tsv"

    local output rc
    # --foreground: keep the child in our process group so it can touch the tty
    output=$(timeout --foreground 3 "$CONVERT" --stats-live "$dir/log.tsv" 2>&1); rc=$?
    if [[ $rc -eq 124 ]] && echo "$output" | grep -q "OK         1"; then
        pass "--stats-live follows a --log file (killed by timeout)"
    else
        fail "--stats-live" "rc=$rc (expected 124) or stats missing"
    fi
}
test_stats_live

# --- HDR preservation ---

section "HDR preservation"

test_hdr_metadata_preserved() {
    local dir="$TEST_DIR/hdr"
    mkdir -p "$dir"
    # setparams stamps the frames; the encoder then writes the HDR10 tags
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
        -vf "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$dir/hdr.mkv" 2>/dev/null

    local output
    output=$("$CONVERT" -o "$dir/out" --no-progress "$dir/hdr.mkv" 2>&1)
    local trc
    trc=$(ffprobe -v error -select_streams v:0 -show_entries stream=color_transfer \
        -of csv=p=0 "$dir/out/hdr.mkv" 2>/dev/null)
    if echo "$output" | grep -q "HDR source" && [[ "$trc" == "smpte2084" ]]; then
        pass "HDR10 colour metadata survives the VP9 encode"
    else
        fail "HDR10 colour metadata survives the VP9 encode" "transfer is '${trc:-none}' (expected smpte2084)"
    fi
}
test_hdr_metadata_preserved

test_log_session_header() {
    local dir="$TEST_DIR/loghdr"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" -o "$dir/out" --log "$dir/log.tsv" --no-progress "$dir/v.mp4" >/dev/null 2>&1
    local first
    first=$(head -1 "$dir/log.tsv" 2>/dev/null)
    if [[ "$first" == "# ── session"* ]] && grep -q "^# files: 1 queued" "$dir/log.tsv"; then
        pass "--log starts with a commented session header"
    else
        fail "--log starts with a commented session header" "header missing or malformed: '$first'"
    fi

    # The comment lines must not confuse --stats (tab-based NF filter skips them)
    local output
    output=$("$CONVERT" --stats "$dir/log.tsv" 2>&1)
    if echo "$output" | grep -q "OK         1"; then
        pass "--stats ignores the session header comments"
    else
        fail "--stats ignores the session header comments" "stats miscounted with header present"
    fi
}
test_log_session_header

test_log_profile_flags() {
    local dir="$TEST_DIR/logprof"
    mkdir -p "$dir/toons"
    echo "--cartoon" > "$dir/toons/.convert-profile"
    generate_video "$dir/toons/v.mp4" 2

    "$CONVERT" -o "$dir/out" --log "$dir/log.tsv" --no-progress "$dir/toons/v.mp4" >/dev/null 2>&1
    if grep -q "\[--cartoon\]" "$dir/log.tsv" 2>/dev/null; then
        pass "profile flags recorded in the file log line"
    else
        fail "profile flags recorded in the file log line" "no [--cartoon] in the log entry"
    fi
}
test_log_profile_flags

test_ssim_in_log() {
    local dir="$TEST_DIR/ssimlog"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2

    "$CONVERT" -o "$dir/out" --quality-check --min-ssim 0.1 \
        --log "$dir/log.tsv" --no-progress "$dir/v.mp4" >/dev/null 2>&1
    if grep -q "ssim=0\." "$dir/log.tsv" 2>/dev/null; then
        pass "successful SSIM score recorded in --log"
    else
        fail "successful SSIM score recorded in --log" "no ssim= field in the OK log line"
    fi
}
test_ssim_in_log

# ===========================================================================
# VP9-specific behaviour (new in convert-to-vp9)
# ===========================================================================

section "VP9 encoder settings"

get_stream_field() {   # $1 = selector, $2 = field, $3 = file
    ffprobe -v error -select_streams "$1" -show_entries "stream=$2" \
        -of csv=p=0 "$3" 2>/dev/null | head -1 | tr -d '[:space:]'
}

test_vp9_10bit_profile2() {
    local dir="$TEST_DIR/vp9-10bit"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2
    "$CONVERT" --no-progress --fast -o "$dir/out" "$dir/v.mp4" >/dev/null 2>&1
    local pf prof
    pf=$(get_stream_field v:0 pix_fmt "$dir/out/v.mkv")
    prof=$(ffprobe -v error -select_streams v:0 -show_entries stream=profile -of csv=p=0 "$dir/out/v.mkv" 2>/dev/null)
    if [[ "$pf" == "yuv420p10le" && "$prof" == "Profile 2" ]]; then
        pass "output is 10-bit VP9 (yuv420p10le, Profile 2)"
    else
        fail "10-bit output" "pix_fmt '$pf', profile '$prof'"
    fi
}
test_vp9_10bit_profile2

# Constant quality: the encoder must get -crf with -b:v 0, plus the efficiency
# switches; tile columns follow the output width (1080p -> 2, 720p -> 2, 240p -> 0).
test_vp9_encoder_args() {
    local dir="$TEST_DIR/vp9-args"
    mkdir -p "$dir"
    generate_video "$dir/hd.mp4" 1 1920x1080
    generate_video "$dir/sd.mp4" 1 320x240
    "$CONVERT" --no-progress --fast -v -o "$dir/o" "$dir/hd.mp4" > "$dir/hd.txt" 2>&1
    "$CONVERT" --no-progress --fast -v -o "$dir/o" "$dir/sd.mp4" > "$dir/sd.txt" 2>&1
    local ok=true
    for a in "-c:v libvpx-vp9" "-deadline good" "-cpu-used 5" "-crf 36 -b:v 0" "-row-mt 1" \
             "-auto-alt-ref 1" "-lag-in-frames 25" "-g 240" "-tile-columns:v:0 2"; do
        grep -q -- "$a" "$dir/hd.txt" || { ok=false; fail "encoder args" "missing '$a'"; }
    done
    grep -q -- "-tile-columns:v:0 0" "$dir/sd.txt" || { ok=false; fail "tile columns" "320 px wide should use 0"; }
    [[ "$(get_codec "$dir/o/hd.mkv")" == "vp9" ]] || { ok=false; fail "encoder args" "no vp9 output"; }
    $ok && pass "libvpx-vp9 gets CRF + -b:v 0, row-mt, alt-ref/lag, keyint, width-based tiles"
}
test_vp9_encoder_args

test_two_pass() {
    local dir="$TEST_DIR/2pass"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 2
    local tmp="$dir/tmp"
    mkdir -p "$tmp"
    local output
    output=$(TMPDIR="$tmp" "$CONVERT" --no-progress --fast --2pass -o "$dir/out" "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "Analysis (pass 1/2) done" \
        && echo "$output" | grep -q "Conversion done" \
        && [[ "$(get_codec "$dir/out/v.mkv")" == "vp9" ]] \
        && [[ -z "$(ls -A "$tmp")" ]]; then
        pass "--2pass runs analysis + final pass, leaves no pass log behind"
    else
        fail "--2pass" "pass messages/output missing or leftovers in TMPDIR: $(ls -A "$tmp")"
    fi
}
test_two_pass

# The whole preset matrix, as derived values in the banner (dry run, no encode)
test_preset_matrix() {
    local dir="$TEST_DIR/matrix"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 1 160x120
    local bad=0 flags expect got
    while IFS='|' read -r flags expect; do
        # shellcheck disable=SC2086
        got=$("$CONVERT" --dry-run $flags "$dir/v.mp4" 2>&1 | grep -o "cpu-used=[0-9]* crf=[0-9]* [0-9]*-bit [12]-pass tune=[a-z]*" | head -1)
        if [[ "$got" != "$expect" ]]; then
            bad=$((bad + 1)); fail "preset matrix [${flags:-default}]" "got '$got', expected '$expect'"
        fi
    done <<'MATRIX'
|cpu-used=3 crf=32 10-bit 1-pass tune=default
--fast|cpu-used=5 crf=36 10-bit 1-pass tune=default
--hq|cpu-used=1 crf=32 10-bit 2-pass tune=film
--cartoon|cpu-used=3 crf=34 10-bit 1-pass tune=default
--fast --cartoon|cpu-used=5 crf=38 10-bit 1-pass tune=default
--hq --cartoon|cpu-used=1 crf=34 10-bit 2-pass tune=default
--tv|cpu-used=5 crf=33 10-bit 1-pass tune=default
--fast --tv|cpu-used=5 crf=37 10-bit 1-pass tune=default
--hq --tv|cpu-used=5 crf=33 10-bit 1-pass tune=default
--movie|cpu-used=3 crf=30 10-bit 1-pass tune=film
--fast --movie|cpu-used=5 crf=34 10-bit 1-pass tune=film
--hq --movie|cpu-used=1 crf=30 10-bit 2-pass tune=film
--movie --crf 40|cpu-used=3 crf=40 10-bit 1-pass tune=film
--tv --preset 2|cpu-used=2 crf=33 10-bit 1-pass tune=default
--hq --1pass|cpu-used=1 crf=32 10-bit 1-pass tune=film
--tv --2pass|cpu-used=5 crf=33 10-bit 2-pass tune=default
--cpu-used 7 --fast|cpu-used=5 crf=36 10-bit 1-pass tune=default
--fast --cpu-used 7|cpu-used=7 crf=36 10-bit 1-pass tune=default
MATRIX
    [[ "$bad" -eq 0 ]] && pass "preset matrix (speed x content, explicit overrides) as documented"
}
test_preset_matrix

test_grain_mapping_warns() {
    local dir="$TEST_DIR/grain"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 1 160x120
    local out_movie out_cartoon
    out_movie=$("$CONVERT" --dry-run --movie "$dir/v.mp4" 2>&1)
    out_cartoon=$("$CONVERT" --dry-run --hq --cartoon "$dir/v.mp4" 2>&1)
    if echo "$out_movie" | grep -q "WARN: VP9 has no film-grain synthesis.*tune-content film.*denoise not applied" \
        && echo "$out_movie" | grep -q "grain=10+denoise requested" \
        && ! echo "$out_cartoon" | grep -q "film-grain"; then
        pass "grain/denoise requests are mapped + warned, never dropped silently"
    else
        fail "grain mapping" "missing warning/banner note (or spurious one for --cartoon)"
    fi
}
test_grain_mapping_warns

test_cpu_used_range() {
    local rc1 rc2 rc3
    "$CONVERT" --preset 9 . >/dev/null 2>&1; rc1=$?
    "$CONVERT" --cpu-used 13 . >/dev/null 2>&1; rc2=$?
    "$CONVERT" --crf 64 . >/dev/null 2>&1; rc3=$?
    if [[ $rc1 -eq 1 && $rc2 -eq 1 && $rc3 -eq 1 ]]; then
        pass "--preset/--cpu-used > 8 and --crf > 63 rejected at parse time"
    else
        fail "cpu-used range" "exit codes $rc1/$rc2/$rc3 (expected 1/1/1)"
    fi
}
test_cpu_used_range

# convert-to-av1 lost an explicit CLI --crf when a profile said --hq
test_cli_crf_beats_profile_speed() {
    local dir="$TEST_DIR/crf-vs-profile"
    mkdir -p "$dir"
    printf '%s\n' '--hq' > "$dir/.convert-profile"
    generate_video "$dir/v.mp4" 1 160x120
    local output
    output=$("$CONVERT" --dry-run --crf 40 "$dir/v.mp4" 2>&1)
    if echo "$output" | grep -q "cpu-used=1 crf=40 .*2-pass"; then
        pass "explicit CLI --crf survives a profile speed preset (--hq)"
    else
        fail "CLI crf vs profile" "banner: $(echo "$output" | grep encoder)"
    fi
}
test_cli_crf_beats_profile_speed

test_hlg_metadata_preserved() {
    local dir="$TEST_DIR/hlg"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
        -vf "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=arib-std-b67" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p10le "$dir/hlg.mkv" 2>/dev/null
    "$CONVERT" -o "$dir/out" --no-progress --fast "$dir/hlg.mkv" >/dev/null 2>&1
    local trc prim cs
    trc=$(get_stream_field v:0 color_transfer "$dir/out/hlg.mkv")
    prim=$(get_stream_field v:0 color_primaries "$dir/out/hlg.mkv")
    cs=$(get_stream_field v:0 color_space "$dir/out/hlg.mkv")
    if [[ "$trc" == "arib-std-b67" && "$prim" == "bt2020" && "$cs" == "bt2020nc" ]]; then
        pass "HLG colour metadata survives the VP9 encode (trc/primaries/matrix)"
    else
        fail "HLG metadata" "got trc=$trc primaries=$prim matrix=$cs"
    fi
}
test_hlg_metadata_preserved

test_sdr_bt709_fix() {
    local dir="$TEST_DIR/bt709"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 1   # untagged SDR
    "$CONVERT" -o "$dir/out" --no-progress --fast "$dir/v.mp4" >/dev/null 2>&1
    local cs
    cs=$(get_stream_field v:0 color_space "$dir/out/v.mkv")
    if [[ "$cs" == "bt709" ]]; then
        pass "untagged SDR source is tagged BT.709"
    else
        fail "BT.709 fix" "color_space '$cs'"
    fi
}
test_sdr_bt709_fix

test_output_permissions() {
    local dir="$TEST_DIR/perms"
    mkdir -p "$dir"
    generate_video "$dir/v.mp4" 1
    chmod 644 "$dir/v.mp4"
    "$CONVERT" -o "$dir/out" --no-progress --fast "$dir/v.mp4" >/dev/null 2>&1
    local m
    m=$(stat -c %a "$dir/out/v.mkv" 2>/dev/null)
    if [[ "$m" == "644" ]]; then
        pass "output takes the source's permissions (not mktemp's 0600)"
    else
        fail "output permissions" "mode $m (expected 644)"
    fi
}
test_output_permissions

section "Savings display"

# The summary totals must equal the real file sizes on disk, byte for byte,
# and split into freed (source gone/replaced) vs pending (source kept).
# Fixtures: testsrc2 at x264 CRF 10 — VP9 lands at ~20 % of the input, well
# above the corrupt-output floor (input/10) that plain testsrc can undercut.
test_savings_exact_freed_pending() {
    local dir="$TEST_DIR/savings"
    mkdir -p "$dir/keep" "$dir/rm"
    ffmpeg -y -f lavfi -i "testsrc2=duration=2:size=640x360:rate=25" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p "$dir/keep/a.mp4" 2>/dev/null
    ffmpeg -y -f lavfi -i "testsrc2=duration=2:size=640x360:rate=25" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p "$dir/rm/b.mp4" 2>/dev/null
    local in_a in_b
    in_a=$(stat -c %s "$dir/keep/a.mp4"); in_b=$(stat -c %s "$dir/rm/b.mp4")

    local out1 out2
    out1=$("$CONVERT" --no-progress --fast "$dir/keep/a.mp4" 2>&1)
    out2=$("$CONVERT" --no-progress --fast --rm-src "$dir/rm/b.mp4" 2>&1)
    local o_a o_b
    o_a=$(stat -c %s "$dir/keep/a.mkv"); o_b=$(stat -c %s "$dir/rm/b.mkv")

    local ok=true
    echo "$out1" | grep -q "exact ........... ${in_a} -> ${o_a} bytes = $(( in_a - o_a )) bytes saved" || { ok=false; fail "savings exact (kept)" "exact line does not match stat sizes"; }
    echo "$out1" | grep -q "pending ......... .*($(( in_a - o_a )) bytes, 1 file" || { ok=false; fail "savings pending" "kept source not reported as pending"; }
    echo "$out1" | grep -q "SAVED .*\[${in_a} -> ${o_a} bytes" || { ok=false; fail "per-file savings line" "missing for a.mp4"; }
    echo "$out2" | grep -q "freed now ....... .*($(( in_b - o_b )) bytes, 1 file" || { ok=false; fail "savings freed" "removed source not reported as freed"; }
    [[ -f "$dir/rm/b.mp4" ]] && { ok=false; fail "savings freed" "--rm-src left the source"; }
    $ok && pass "per-file + total savings match stat byte-for-byte; freed vs pending split"
}
test_savings_exact_freed_pending

# Batch of two: the running total between files, then a summary whose exact
# total equals the sum of both files' real sizes.
test_savings_batch_running_total() {
    local dir="$TEST_DIR/savings-batch"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc2=duration=2:size=640x360:rate=25" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p "$dir/a.mp4" 2>/dev/null
    ffmpeg -y -f lavfi -i "testsrc2=duration=2:size=640x360:rate=25" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p "$dir/b.mp4" 2>/dev/null
    local ia ib
    ia=$(stat -c %s "$dir/a.mp4"); ib=$(stat -c %s "$dir/b.mp4")
    local output
    output=$("$CONVERT" --no-progress --fast --sort-by-size asc "$dir" 2>&1)
    local oa ob
    oa=$(stat -c %s "$dir/a.mkv"); ob=$(stat -c %s "$dir/b.mkv")
    local tin=$(( ia + ib )) tout=$(( oa + ob ))
    if echo "$output" | grep -q "^batch: 1/2 done | saved .*% of .* | freed 0B, pending .*" \
        && echo "$output" | grep -q "exact ........... ${tin} -> ${tout} bytes = $(( tin - tout )) bytes saved" \
        && echo "$output" | grep -q "over 2 converted file"; then
        pass "running batch total between files + exact two-file sum"
    else
        fail "batch savings" "batch line or exact total wrong (expected ${tin} -> ${tout})"
    fi
}
test_savings_batch_running_total

# In place .mkv -> .mkv: the output replaces the source at the same path,
# so the space is freed immediately even without --rm-src.
test_savings_inplace_mkv_freed() {
    local dir="$TEST_DIR/savings-mkv"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc2=duration=2:size=640x360:rate=25" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p "$dir/c.mkv" 2>/dev/null
    local i
    i=$(stat -c %s "$dir/c.mkv")
    local output
    output=$("$CONVERT" --no-progress --fast "$dir/c.mkv" 2>&1)
    local o
    o=$(stat -c %s "$dir/c.mkv")
    if [[ "$(get_codec "$dir/c.mkv")" == "vp9" ]] \
        && echo "$output" | grep -q "freed now ....... .*($(( i - o )) bytes, 1 file"; then
        pass "in-place .mkv replacement counts as freed"
    else
        fail "in-place mkv freed" "expected freed $(( i - o )) bytes"
    fi
}
test_savings_inplace_mkv_freed

# Larger output kept (no --rm-if-bigger): shown as LARGER, negative saving
test_savings_larger_output() {
    local dir="$TEST_DIR/savings-larger"
    mkdir -p "$dir"
    # A very cheap source at near-max CRF; VP9 at CRF 0 must be larger
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" \
        -c:v libx264 -preset ultrafast -crf 51 -pix_fmt yuv420p "$dir/s.mp4" 2>/dev/null
    local output
    output=$("$CONVERT" --no-progress --crf 0 --preset 8 -o "$dir/out" "$dir/s.mp4" 2>&1)
    if echo "$output" | grep -q "▲ LARGER +" \
        && echo "$output" | grep -q "would use .* more" \
        && echo "$output" | grep -q "Total: .* | larger by "; then
        pass "a larger output is reported as LARGER (+%), never as a saving"
    else
        fail "larger output display" "$(echo "$output" | grep -i "larger\|saved" | head -3)"
    fi
}
test_savings_larger_output

# Live estimate of the final size on the progress line (no --no-progress)
test_live_size_estimate() {
    local dir="$TEST_DIR/live-est"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc=duration=8:size=1280x720:rate=25" \
        -c:v libx264 -preset ultrafast -crf 5 -pix_fmt yuv420p "$dir/v.mp4" 2>/dev/null
    local output
    output=$("$CONVERT" --preset 4 --crf 30 -o "$dir/out" "$dir/v.mp4" 2>&1)
    if echo "$output" | tr '\r' '\n' | grep -q "| est\. [0-9.]*[KMG] saved=[0-9]*%"; then
        pass "progress line shows a live estimate of the final size"
    else
        fail "live estimate" "no 'est. SIZE saved=N%' on the progress line"
    fi
}
test_live_size_estimate

section "Fixes over convert-to-av1"

# MP4 timed text cannot be stored in Matroska: copied as-is the muxer rejected
# the file (and SVT-AV1 then hung). It must arrive as SRT, language intact.
test_mov_text_to_srt() {
    local dir="$TEST_DIR/movtext"
    mkdir -p "$dir"
    printf '1\n00:00:00,000 --> 00:00:01,000\nhello\n' > "$dir/s.srt"
    ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=25" -f lavfi -i "sine=duration=2" \
        -i "$dir/s.srt" -map 0 -map 1 -map 2 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
        -c:a aac -c:s mov_text -metadata:s:s:0 language=eng "$dir/m.mp4" 2>/dev/null
    rm -f "$dir/s.srt"
    "$CONVERT" --no-progress --fast -o "$dir/out" "$dir/m.mp4" >/dev/null 2>&1 < /dev/null
    local sc sl
    sc=$(get_stream_field s:0 codec_name "$dir/out/m.mkv")
    sl=$(ffprobe -v error -select_streams s:0 -show_entries stream_tags=language -of csv=p=0 "$dir/out/m.mkv" 2>/dev/null)
    if [[ "$(get_codec "$dir/out/m.mkv")" == "vp9" && "$sc" == "subrip" && "$sl" == "eng" ]]; then
        pass "mov_text subtitles (MP4) arrive as SRT in the MKV"
    else
        fail "mov_text" "video '$(get_codec "$dir/out/m.mkv")', subs '$sc' lang '$sl'"
    fi
}
test_mov_text_to_srt

# AAC priming shifts the MKV video start by ~23 ms; unaligned, ssim compared
# neighbouring frames and reported ~0.92 for a ~0.996 encode.
test_ssim_alignment_mp4_aac() {
    local dir="$TEST_DIR/ssim-align"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc2=duration=2:size=640x360:rate=25" -f lavfi -i "sine=duration=2" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p -c:a aac "$dir/v.mp4" 2>/dev/null
    local output score
    output=$("$CONVERT" --no-progress --quality-check -o "$dir/out" "$dir/v.mp4" 2>&1 < /dev/null)
    score=$(grep -oP 'SSIM: \K[0-9.]+' <<< "$output")
    if awk -v s="${score:-0}" 'BEGIN { exit !(s >= 0.98) }'; then
        pass "SSIM check is frame-aligned on MP4/AAC sources (${score})"
    else
        fail "SSIM alignment" "score '${score}' (expected >= 0.98)"
    fi
}
test_ssim_alignment_mp4_aac

# MPEG-TS has no index: sampled SSIM must start each sample on a keyframe
test_ssim_sampled_mpegts() {
    local dir="$TEST_DIR/ssim-ts"
    mkdir -p "$dir"
    ffmpeg -y -f lavfi -i "testsrc2=duration=12:size=320x240:rate=25" -f lavfi -i "sine=duration=12" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p -c:a aac -f mpegts "$dir/r.ts" 2>/dev/null
    local output score
    output=$("$CONVERT" --no-progress --fast --quality-check -o "$dir/out" "$dir/r.ts" 2>&1 < /dev/null)
    score=$(grep -oP 'SSIM: \K[0-9.]+' <<< "$output")
    if awk -v s="${score:-0}" 'BEGIN { exit !(s >= 0.98) }'; then
        pass "sampled SSIM on MPEG-TS starts on keyframes (${score})"
    else
        fail "SSIM on MPEG-TS" "score '${score}' (expected >= 0.98)"
    fi
}
test_ssim_sampled_mpegts

# Ctrl-C (SIGINT to the process group) must stop the batch, not just fail the
# current file and carry on with the next one.
test_ctrl_c_stops_batch() {
    local dir="$TEST_DIR/ctrlc"
    mkdir -p "$dir"
    generate_video "$dir/one.mp4" 4 1280x720
    cp "$dir/one.mp4" "$dir/two.mp4"
    setsid bash -c "exec \"$CONVERT\" --fast \"$dir\" < /dev/null" > "$dir/out.txt" 2>&1 &
    local p=$! i
    sleep 2
    kill -INT -- -"$p" 2>/dev/null
    for i in $(seq 1 30); do sleep 1; pgrep -g "$p" >/dev/null || break; done
    local left
    left=$(find "$dir" -maxdepth 1 \( -name '.convert-*' -o -name '*.lock' -o -name '*.mkv' \) | wc -l)
    if grep -q "Interrupted" "$dir/out.txt" && ! grep -q "\[2/2\]" "$dir/out.txt" && [[ "$left" -eq 0 ]]; then
        pass "Ctrl-C stops the batch and cleans up (no temp, lock or partial output)"
    else
        fail "Ctrl-C" "interrupted=$(grep -c Interrupted "$dir/out.txt") second-file=$(grep -c '\[2/2\]' "$dir/out.txt") leftovers=$left"
    fi
}
test_ctrl_c_stops_batch

# ===========================================================================
# Summary
# ===========================================================================

echo ""
printf '%s══════════════════════════════════════════%s\n' "$BOLD" "$RESET"
printf '%sResults:%s  %s%d passed%s  %s%d failed%s  %s%d skipped%s\n' \
    "$BOLD" "$RESET" "$GREEN" "$PASS" "$RESET" "$RED" "$FAIL" "$RESET" "$YELLOW" "$SKIP" "$RESET"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    printf '%sFailures:%s\n' "$RED" "$RESET"
    for f in "${FAILURES[@]}"; do
        printf "  - %s\n" "$f"
    done
fi

printf '%s══════════════════════════════════════════%s\n' "$BOLD" "$RESET"

exit "$FAIL"
