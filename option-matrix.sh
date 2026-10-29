#!/usr/bin/env bash
# SC2319: "cond; verdict $?" deliberately records the condition's status.
# SC2016: row commands are single-quoted on purpose — they are shown verbatim
#         in the matrix and expanded only when run() evals them.
# shellcheck disable=SC2319,SC2016
# Option matrix for convert-to-vp9: runs every CLI option at least once on
# synthetic fixtures and checks the result with ffprobe / real file sizes.
# Each row records: option, the exact command that ran, expected, actual, verdict.
#
# Usage:
#   bash option-matrix.sh              # fixtures + all groups + report
#   bash option-matrix.sh GROUP...     # run selected groups (results accumulate)
#   bash option-matrix.sh report       # write TESTMATRIX.md from the results
# Groups: fixtures output files quality batch audio tracks misc logging
# Env: MATRIX_DIR (default /tmp/convert-vp9-matrix) keeps fixtures + results
# between invocations, so groups can run one at a time.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONVERT_BIN="$SCRIPT_DIR/convert-to-vp9.sh"
MATRIX_DIR="${MATRIX_DIR:-/tmp/convert-vp9-matrix}"
FIX="$MATRIX_DIR/fixtures"
RESULTS="$MATRIX_DIR/results.tsv"
REPORT="${MATRIX_REPORT:-$SCRIPT_DIR/TESTMATRIX.md}"
mkdir -p "$FIX"

if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]] && locale -a 2>/dev/null | grep -qix 'c.utf-\?8'; then
    export LC_CTYPE=C.UTF-8
fi

# The commands in the matrix read "convert-to-vp9 ..." exactly as a user types
# them; this function is what runs. NO_COLOR keeps the captured text greppable,
# stdin is detached (ffmpeg must never wait on it), KILL caps a hung encode.
convert-to-vp9() {
    NO_COLOR=1 timeout -s KILL 240 bash "$CONVERT_BIN" "$@" < /dev/null
}

# -- probes -------------------------------------------------------------------
pf()   { ffprobe -v error -select_streams "$1" -show_entries "stream=$2" -of csv=p=0 "$3" 2>/dev/null | tr '\n' ',' | sed 's/,$//'; }
vcodec()   { pf v:0 codec_name "$1"; }
pixfmt()   { pf v:0 pix_fmt "$1"; }
vheight()  { pf v:0 height "$1"; }
nstreams() { ffprobe -v error -select_streams "$1" -show_entries stream=index -of csv=p=0 "$2" 2>/dev/null | grep -c .; }
acodecs()  { pf a codec_name "$1"; }
achans()   { pf a channels "$1"; }
alangs()   { ffprobe -v error -select_streams a -show_entries stream_tags=language -of csv=p=0 "$1" 2>/dev/null | tr '\n' ',' | sed 's/,$//'; }
slangs()   { ffprobe -v error -select_streams s -show_entries stream_tags=language -of csv=p=0 "$1" 2>/dev/null | tr '\n' ',' | sed 's/,$//'; }
fsize()    { stat -c %s "$1" 2>/dev/null || echo 0; }

# -- row bookkeeping ----------------------------------------------------------
GROUP=""; OPT=""; EXP=""; CMD=""; OUT=""; RC=0; W=""
N_PASS=0; N_FAIL=0

begin() {   # OPTION EXPECTED
    OPT="$1"; EXP="$2"; CMD=""; OUT=""; RC=0
    W=$(mktemp -d "$MATRIX_DIR/work.XXXXXX")
    cd "$W" || exit 1
}
fx() { cp "$FIX/$1" "./${2:-$1}"; }   # copy a fixture into the row's workdir
run() {     # COMMAND (shown verbatim in the matrix)
    CMD="$1"
    OUT=$(eval "$1" 2>&1); RC=$?
}
record() {  # VERDICT ACTUAL
    local v="$1" a="$2"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$GROUP" "$OPT" "$CMD" "$EXP" "${a//$'\n'/ }" "$v" >> "$RESULTS"
    if [[ "$v" == PASS ]]; then N_PASS=$((N_PASS + 1)); else N_FAIL=$((N_FAIL + 1)); fi
    printf '  %-4s %-34s %s\n' "$v" "$OPT" "${a:0:110}"
    cd "$MATRIX_DIR" && rm -rf "$W"
}
verdict() { # CONDITION-RC ACTUAL
    if [[ "$1" -eq 0 ]]; then record PASS "$2"; else record FAIL "$2"; fi
}
has() { grep -qE -- "$1" <<< "$OUT"; }
# temp outputs / lock files left in the row's directory
leftovers() { find . -maxdepth 1 \( -name '.convert-*' -o -name '*.lock' \) | wc -l; }
nfiles() { find . -mindepth 1 -maxdepth 1 | wc -l; }

# -- fixtures -----------------------------------------------------------------
g_fixtures() {
    local f=(-y -loglevel error -nostdin)
    local v="testsrc2=duration=2:size=640x360:rate=25"
    local x=(-c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p)
    cd "$FIX" || exit 1
    printf '1\n00:00:00,000 --> 00:00:01,000\nhello\n' > en.srt
    printf '1\n00:00:00,000 --> 00:00:01,000\nbonjour\n' > fr.srt
    ffmpeg "${f[@]}" -f lavfi -i "$v" -f lavfi -i "sine=frequency=440:duration=2" "${x[@]}" -c:a aac -b:a 64k -ac 2 base.mp4
    ffmpeg "${f[@]}" -i base.mp4 -c copy base.mkv
    # eng stereo / fre 5.1 / spa stereo audio + eng/fre embedded SRT
    ffmpeg "${f[@]}" -f lavfi -i "$v" -f lavfi -i "sine=frequency=440:duration=2" \
        -f lavfi -i "sine=frequency=480:duration=2" -f lavfi -i "sine=frequency=500:duration=2" \
        -i en.srt -i fr.srt -map 0:v -map 1:a -map 2:a -map 3:a -map 4 -map 5 "${x[@]}" \
        -c:a aac -b:a 96k -ac:a:0 2 -ac:a:1 6 -b:a:1 384k -ac:a:2 2 -c:s srt \
        -metadata:s:a:0 language=eng -metadata:s:a:1 language=fre -metadata:s:a:2 language=spa \
        -metadata:s:s:0 language=eng -metadata:s:s:1 language=fre multi.mkv
    # MP4 with mov_text subtitles (not storable in MKV as-is)
    ffmpeg "${f[@]}" -f lavfi -i "$v" -f lavfi -i "sine=duration=2" -i en.srt -map 0 -map 1 -map 2 \
        "${x[@]}" -c:a aac -c:s mov_text -metadata:s:s:0 language=eng movtext.mp4
    # 5.1(side) layout — libopus rejects it unless normalised
    ffmpeg "${f[@]}" -f lavfi -i "$v" -f lavfi -i "sine=duration=2" "${x[@]}" \
        -af "aformat=channel_layouts=5.1(side)" -c:a pcm_s16le side51.mkv
    ffmpeg "${f[@]}" -f lavfi -i "testsrc2=duration=2:size=1920x1080:rate=25" -f lavfi -i "sine=duration=2" \
        -c:v libx264 -preset ultrafast -crf 18 -pix_fmt yuv420p -c:a aac hd.mp4
    ffmpeg "${f[@]}" -f lavfi -i "$v" -f lavfi -i "sine=duration=2" "${x[@]}" -c:a aac -f mpegts rec.ts
    # covers: PNG attached_pic in MKV, MJPEG attached_pic in MP4
    ffmpeg "${f[@]}" -f lavfi -i "color=c=red:s=64x64:d=1" -frames:v 1 cover.png
    ffmpeg "${f[@]}" -f lavfi -i "color=c=blue:s=64x64:d=1" -frames:v 1 cover.jpg
    ffmpeg "${f[@]}" -i base.mkv -i cover.png -map 0 -map 1 -c copy -disposition:v:1 attached_pic cover.mkv
    ffmpeg "${f[@]}" -i base.mp4 -i cover.jpg -map 0 -map 1 -c copy -disposition:v:1 attached_pic cover.mp4
    ffmpeg "${f[@]}" -f lavfi -i "$v" -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p10le hi10.mkv
    ffmpeg "${f[@]}" -f lavfi -i "$v" -vf "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=smpte2084" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p10le hdr10.mkv
    ffmpeg "${f[@]}" -f lavfi -i "$v" -vf "setparams=colorspace=bt2020nc:color_primaries=bt2020:color_trc=arib-std-b67" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p10le hlg.mkv
    # 320 kb/s AAC in MKV: no container bitrate -> packet-sampled
    ffmpeg "${f[@]}" -f lavfi -i "$v" -f lavfi -i "anoisesrc=d=2:c=pink" "${x[@]}" -c:a aac -b:a 320k -ac 2 hiaudio.mkv
    ffmpeg "${f[@]}" -f lavfi -i "$v" -f lavfi -i "sine=duration=2" "${x[@]}" -c:a libopus -b:a 96k opus.mkv
    ffmpeg "${f[@]}" -f lavfi -i "$v" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -crf 40 -b:v 0 vp9.mkv
    local e enc=""
    e=$(ffmpeg -hide_banner -encoders 2>/dev/null)
    [[ "$e" == *" libsvtav1 "* ]] && enc=libsvtav1
    [[ -z "$enc" && "$e" == *" libaom-av1 "* ]] && enc=libaom-av1
    case "$enc" in
        libsvtav1)  ffmpeg "${f[@]}" -f lavfi -i "$v" -c:v libsvtav1 -preset 12 -crf 40 av1.mkv ;;
        libaom-av1) ffmpeg "${f[@]}" -f lavfi -i "$v" -c:v libaom-av1 -cpu-used 8 -crf 40 -b:v 0 av1.mkv ;;
    esac
    # bitrate pair: thin (testsrc, CRF 51) vs fat (random noise)
    ffmpeg "${f[@]}" -f lavfi -i "testsrc=duration=4:size=640x480:rate=25" -c:v libx264 -preset ultrafast -crf 51 -pix_fmt yuv420p thin.mp4
    ffmpeg "${f[@]}" -f lavfi -i "nullsrc=s=640x480:d=4:r=25,geq=random(1)*255:128:128" -c:v libx264 -preset ultrafast -crf 20 -pix_fmt yuv420p fat.mp4
    # 12 s clip: long enough for sampled SSIM (>= 10 s) and the skip key
    ffmpeg "${f[@]}" -f lavfi -i "testsrc2=duration=12:size=320x240:rate=25" -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p long.mp4
    # cheap 720p source: VP9 at CRF 0 must come out larger (early abort)
    ffmpeg "${f[@]}" -f lavfi -i "testsrc=duration=8:size=1280x720:rate=25" -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p cheap.mp4
    cd "$MATRIX_DIR" || exit 1
    local n
    n=$(find "$FIX" -maxdepth 1 -type f \( -name '*.mp4' -o -name '*.mkv' -o -name '*.ts' \) | wc -l)
    echo "  fixtures: $n media files in $FIX (AV1 fixture encoder: ${enc:-none})"
}

# -- output -------------------------------------------------------------------
g_output() {
    local c p prof ac
    begin "(no options)" "VP9 Profile 2 10-bit MKV next to source, source kept, 64k AAC copied"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 a.mp4'
    c=$(vcodec a.mkv); p=$(pixfmt a.mkv); prof=$(pf v:0 profile a.mkv); ac=$(acodecs a.mkv)
    [[ $RC -eq 0 && $c == vp9 && $p == yuv420p10le && $prof == "Profile 2" && -f a.mp4 && $ac == aac ]]
    verdict $? "rc=$RC $c $p $prof audio=$ac source-kept=$([[ -f a.mp4 ]] && echo yes || echo no)"

    begin "-o, --output-dir DIR" "out/a.mkv (VP9), nothing written next to the source"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 -o out a.mp4'
    c=$(vcodec out/a.mkv)
    [[ $RC -eq 0 && $c == vp9 && ! -e a.mkv ]]; verdict $? "rc=$RC out/a.mkv=$c ./a.mkv=$([[ -e a.mkv ]] && echo exists || echo absent)"

    begin "--in-place" "a.mkv next to the source"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --in-place a.mp4'
    c=$(vcodec a.mkv)
    [[ $RC -eq 0 && $c == vp9 ]]; verdict $? "rc=$RC a.mkv=$c"

    begin "--in-place + -o" "rejected: mutually exclusive, exit 1"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --in-place -o out a.mp4'
    [[ $RC -eq 1 ]] && has "mutually exclusive"; verdict $? "rc=$RC $(grep -o 'ERROR.*' <<< "$OUT")"

    begin "(no -y) existing output" "skipped, existing file untouched"
    fx base.mp4 a.mp4; mkdir out; echo x > out/a.mkv
    run 'convert-to-vp9 -o out a.mp4'
    [[ $(fsize out/a.mkv) -eq 2 ]] && has "output exists"; verdict $? "out/a.mkv size=$(fsize out/a.mkv) $(grep -o 'output exists[^)]*)' <<< "$OUT" | head -1)"

    begin "-y, --overwrite" "existing output replaced by the VP9 encode"
    fx base.mp4 a.mp4; mkdir out; echo x > out/a.mkv
    run 'convert-to-vp9 -y -o out a.mp4'
    c=$(vcodec out/a.mkv)
    [[ $c == vp9 && $(fsize out/a.mkv) -gt 2 ]]; verdict $? "out/a.mkv=$c size=$(fsize out/a.mkv)"

    begin "(guard) output name collision" "second source mapping to a.mkv is skipped"
    fx base.mp4 a.mp4; fx rec.ts a.ts
    run 'convert-to-vp9 --dry-run a.mp4 a.ts'
    has "output name collision"; verdict $? "$(grep -o 'a.ts .*collision' <<< "$OUT" | head -1)"

    begin "(error) unknown option" "exit 1 with 'Unknown option'"
    run 'convert-to-vp9 --bogus a.mp4'
    [[ $RC -eq 1 ]] && has "Unknown option: --bogus"; verdict $? "rc=$RC"
}

# -- file management, early abort, guards ---------------------------------------
g_files() {
    begin "--smart, --keep-best-version" "smaller VP9 kept, source removed, SSIM checked"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --smart a.mp4'
    [[ $(vcodec a.mkv) == vp9 && ! -e a.mp4 ]] && has "SSIM: 0\.[0-9]+"
    verdict $? "a.mkv=$(vcodec a.mkv) a.mp4=$([[ -e a.mp4 ]] && echo kept || echo removed) $(grep -o 'SSIM: [0-9.]*' <<< "$OUT")"

    begin "--smart (output larger)" "KEPT_SRC: larger output discarded, source kept"
    fx thin.mp4 t.mp4
    run 'convert-to-vp9 --smart --min-size 0 --crf 0 --preset 8 --no-early-abort t.mp4'
    [[ -f t.mp4 && ! -e t.mkv ]] && has "KEPT_SRC"; verdict $? "t.mp4=$([[ -f t.mp4 ]] && echo kept) t.mkv=$([[ -e t.mkv ]] && echo exists || echo absent) $(grep -o 'KEPT_SRC' <<< "$OUT" | head -1)"

    begin "--rm-source, --rm-src" "source removed after a smaller output"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --rm-src a.mp4'
    [[ $(vcodec a.mkv) == vp9 && ! -e a.mp4 ]]; verdict $? "a.mkv=$(vcodec a.mkv) a.mp4=$([[ -e a.mp4 ]] && echo kept || echo removed)"

    begin "--rm-if-bigger" "RM_OUT: larger output removed, source kept"
    fx thin.mp4 t.mp4
    run 'convert-to-vp9 --rm-if-bigger --min-size 0 --crf 0 --preset 8 --no-early-abort t.mp4'
    [[ -f t.mp4 && ! -e t.mkv ]] && has "RM_OUT"; verdict $? "t.mkv=$([[ -e t.mkv ]] && echo exists || echo absent) $(grep -o 'RM_OUT.*' <<< "$OUT" | head -1)"

    begin "--early-abort-threshold PCT" "ABORTED at ~10 %: estimated output >= input"
    fx thin.mp4 t.mp4
    run 'convert-to-vp9 --rm-if-bigger --min-size 0 --crf 0 --preset 8 --early-abort-threshold 10 t.mp4'
    [[ ! -e t.mkv ]] && has "Early abort: estimated output" && has "ABORTED"
    verdict $? "$(grep -o 'Early abort: [^(]*([^)]*)' <<< "$OUT" | head -1)"

    begin "--no-early-abort" "same file runs to the end (RM_OUT, no early abort)"
    fx thin.mp4 t.mp4
    run 'convert-to-vp9 --rm-if-bigger --min-size 0 --crf 0 --preset 8 --early-abort-threshold 10 --no-early-abort t.mp4'
    ! has "Early abort" && has "RM_OUT"; verdict $? "early-abort=$(has 'Early abort' && echo yes || echo no) $(grep -o 'RM_OUT' <<< "$OUT" | head -1)"

    begin "(guard) disk space" "skipped when free space < input (df shimmed to 1000 B)"
    fx base.mp4 a.mp4; mkdir bin
    printf '#!/bin/sh\necho "Filesystem 1-blocks Used Available Capacity Mounted"\necho "/dev/x 1000 0 1000 0%% /"\n' > bin/df; chmod +x bin/df
    run 'PATH="$PWD/bin:$PATH" convert-to-vp9 a.mp4'
    [[ ! -e a.mkv ]] && has "insufficient disk space"; verdict $? "$(grep -o 'Insufficient free space[^:]*' <<< "$OUT" | head -1)"

    begin "(lock) live lock" "LOCKED: file held by a running PID is skipped"
    fx base.mp4 a.mp4; echo "pid=$$,start=now" > a.mp4.lock
    run 'convert-to-vp9 a.mp4'
    [[ ! -e a.mkv ]] && has "LOCKED"; verdict $? "$(grep -o 'File locked by PID [0-9]*' <<< "$OUT")"

    begin "(lock) stale lock" "dead PID: lock removed, conversion proceeds"
    fx base.mp4 a.mp4; echo "pid=999999,start=old" > a.mp4.lock
    run 'convert-to-vp9 a.mp4'
    [[ $(vcodec a.mkv) == vp9 && ! -e a.mp4.lock ]] && has "Stale lock removed"; verdict $? "a.mkv=$(vcodec a.mkv) lock=$([[ -e a.mp4.lock ]] && echo left || echo removed)"
}

# -- encoder presets ----------------------------------------------------------
# -v prints the ffmpeg command line: the encoder arguments are checked there,
# the encode itself with ffprobe.
preset_row() {  # OPTION FLAGS EXPECT-REGEX... (all must appear in the -v output)
    local opt="$1" flags="$2"; shift 2
    begin "$opt" "$*"
    fx base.mp4 a.mp4
    run "convert-to-vp9 -v $flags a.mp4"
    local ok=0 r miss=""
    for r in "$@"; do grep -qE -- "$r" <<< "$OUT" || { ok=1; miss+=" !$r"; }; done
    [[ $(vcodec a.mkv) == vp9 ]] || { ok=1; miss+=" !vp9-output"; }
    verdict $ok "$(grep -oE 'cpu-used=[0-9]+ crf=[0-9]+ [0-9]+-bit [12]-pass tune=[a-z]+' <<< "$OUT" | head -1); out=$(vcodec a.mkv)$miss"
}

g_quality() {
    preset_row "--crf N" "--crf 20" "-crf 20 -b:v 0"
    preset_row "--preset N" "--preset 6" "-cpu-used 6 "
    preset_row "--cpu-used N" "--cpu-used 7" "-cpu-used 7 "
    preset_row "--fast" "--fast" "-cpu-used 5 -crf 36"
    preset_row "--sd" "--sd" "-cpu-used 5 -crf 36"
    preset_row "--hq" "--hq" "-cpu-used 1 -crf 32" "-pass 2" "Analysis \(pass 1/2\) done" "-tune-content film" "audio .* copy"
    preset_row "--cartoon" "--cartoon" "-cpu-used 3 -crf 34" "-tune-content default"
    preset_row "--tv" "--tv" "-cpu-used 5 -crf 33"
    preset_row "--movie" "--movie" "-cpu-used 3 -crf 30" "-tune-content film" "WARN: VP9 has no film-grain synthesis"
    preset_row "--fast --cartoon" "--fast --cartoon" "-cpu-used 5 -crf 38"
    preset_row "--hq --movie" "--hq --movie" "-cpu-used 1 -crf 30" "-pass 2" "-tune-content film"
    preset_row "--tv --hq" "--tv --hq" "-cpu-used 5 -crf 33" "1-pass"
    preset_row "--movie --crf N (explicit wins)" "--movie --crf 40" "-crf 40 " "-tune-content film"
    preset_row "--2pass, --two-pass" "--fast --2pass" "-pass 2 -passlogfile" "Analysis \(pass 1/2\) done"
    preset_row "--1pass, --one-pass" "--hq --1pass" "1-pass" "-cpu-used 1 -crf 32"

    begin "--crf / --preset ranges" "--crf 64 and --preset 9 rejected (exit 1)"
    run 'convert-to-vp9 --crf 64 x.mp4; echo "rc1=$?"; convert-to-vp9 --preset 9 x.mp4; echo "rc2=$?"'
    has "rc1=1" && has "rc2=1"; verdict $? "$(grep -o 'rc[12]=[0-9]*' <<< "$OUT" | tr '\n' ' ')"
}

# -- video handling -----------------------------------------------------------
g_video() {
    local h c
    begin "--max-res, --max-h HEIGHT" "640x360 source scaled to 240p"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --max-res 240 a.mp4'
    h=$(vheight a.mkv); [[ $h == 240 ]]; verdict $? "height=$h"

    begin "--max-h (alias)" "--max-h 300 -> 300p"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --max-h 300 a.mp4'
    h=$(vheight a.mkv); [[ $h == 300 ]]; verdict $? "height=$h"

    begin "--720, --720p" "1080p source scaled to 720p, tile-columns 2"
    fx hd.mp4 h.mp4
    run 'convert-to-vp9 -v --fast --720 h.mp4'
    h=$(vheight h.mkv); [[ $h == 720 ]] && has "tile-columns:v:0 2"; verdict $? "height=$h $(grep -o 'tile-columns:v:0 [0-9]' <<< "$OUT")"

    begin "--1080, --1080p" "1080p source not scaled (already <= 1080)"
    fx hd.mp4 h.mp4
    run 'convert-to-vp9 --fast --1080p h.mp4'
    h=$(vheight h.mkv); [[ $h == 1080 ]] && ! has "Scaling:"; verdict $? "height=$h"

    begin "--quality-check" "SSIM computed and printed, output accepted"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --quality-check a.mp4'
    has "SSIM: 0\.9[0-9]+" && [[ -f a.mkv ]]; verdict $? "$(grep -o 'SSIM: [0-9.]* (min: [0-9.]*)' <<< "$OUT")"

    begin "--min-ssim VALUE" "0.9999 -> output rejected (FAILED), source untouched"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --min-ssim 0.9999 a.mp4'
    [[ ! -e a.mkv && -f a.mp4 ]] && has "Quality too low"; verdict $? "$(grep -o 'Quality too low (SSIM=[^)]*)' <<< "$OUT")"

    begin "--ssim-samples N" "12 s clip sampled at 3 points"
    fx long.mp4 l.mp4
    run 'convert-to-vp9 --ssim-samples 3 l.mp4'
    has "SSIM sampling 3/3" && has "SSIM: 0\.[0-9]+"; verdict $? "$(grep -o '3 samples' <<< "$OUT" | head -1); $(grep -o 'SSIM: [0-9.]*' <<< "$OUT")"

    begin "--verify" "full decode of the output before acceptance"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --verify a.mp4'
    has "Verifying output \(full decode\)" && [[ $(vcodec a.mkv) == vp9 ]]; verdict $? "verify=$(has 'Verifying output' && echo ran) out=$(vcodec a.mkv)"

    begin "(10-bit source)" "10-bit H.264 -> yuv420p10le VP9 Profile 2"
    fx hi10.mkv s.mkv
    run 'convert-to-vp9 -o out s.mkv'
    [[ $(pixfmt out/s.mkv) == yuv420p10le ]]; verdict $? "$(pixfmt out/s.mkv) $(pf v:0 profile out/s.mkv)"

    begin "(HDR10 source)" "transfer smpte2084, primaries bt2020, matrix bt2020nc kept"
    fx hdr10.mkv s.mkv
    run 'convert-to-vp9 -o out s.mkv'
    local t pr cs; t=$(pf v:0 color_transfer out/s.mkv); pr=$(pf v:0 color_primaries out/s.mkv); cs=$(pf v:0 color_space out/s.mkv)
    [[ $t == smpte2084 && $pr == bt2020 && $cs == bt2020nc ]] && has "HDR source"; verdict $? "trc=$t prim=$pr matrix=$cs"

    begin "(HLG source)" "transfer arib-std-b67 kept"
    fx hlg.mkv s.mkv
    run 'convert-to-vp9 -o out s.mkv'
    t=$(pf v:0 color_transfer out/s.mkv); [[ $t == arib-std-b67 ]]; verdict $? "trc=$t prim=$(pf v:0 color_primaries out/s.mkv)"

    begin "(SDR untagged)" "tagged BT.709 (matrix/primaries/transfer)"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 a.mp4'
    cs=$(pf v:0 color_space a.mkv); t=$(pf v:0 color_transfer a.mkv); [[ $cs == bt709 && $t == bt709 ]]; verdict $? "matrix=$cs trc=$t"

    begin "(MPEG-TS source)" "timestamp fix flags applied, VP9 MKV"
    fx rec.ts r.ts
    run 'convert-to-vp9 -v r.ts'
    has "\+genpts\+igndts" && [[ $(vcodec r.mkv) == vp9 ]]; verdict $? "fix-flags=$(has 'genpts' && echo yes) out=$(vcodec r.mkv) dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 r.mkv)"

    begin "(cover art, MKV/PNG)" "cover copied as 2nd video stream (never encoded), main video VP9"
    fx cover.mkv c.mkv
    run 'convert-to-vp9 -o out c.mkv'
    c=$(pf v codec_name out/c.mkv); [[ $c == vp9,png ]]; verdict $? "video streams=$c"

    begin "(cover art, MP4/MJPEG)" "MJPEG cover copied as 2nd video stream; attached_pic flag dropped by ffmpeg's MKV muxer (same in convert-to-av1)"
    fx cover.mp4 c.mp4
    run 'convert-to-vp9 c.mp4'
    c=$(pf v codec_name c.mkv); [[ $c == vp9,mjpeg ]]; verdict $? "video streams=$c attached_pic=$(ffprobe -v error -select_streams v:1 -show_entries stream_disposition=attached_pic -of csv=p=0 c.mkv)"
}

# -- batch selection ----------------------------------------------------------
order_of() { grep -oE "$1" <<< "$OUT" | awk '!s[$0]++' | tr '\n' ' ' | sed 's/ $//'; }

g_batch() {
    begin "-r, --recursive" "file in a subdirectory found (and not without -r)"
    mkdir -p d/sub; fx base.mp4 d/sub/a.mp4
    run 'convert-to-vp9 --dry-run -r d; convert-to-vp9 --dry-run d'
    [[ $(grep -c "a.mp4 .*DRYRUN" <<< "$OUT") -eq 1 ]] && has "No video files found"; verdict $? "with -r: $(grep -c 'DRYRUN' <<< "$OUT") queued; without: none"

    begin "--sort-by-size [asc|desc]" "asc: small first; desc (default): big first"
    fx thin.mp4 small.mp4; fx base.mp4 big.mp4
    run 'convert-to-vp9 --dry-run --min-size 0 --sort-by-size asc big.mp4 small.mp4; convert-to-vp9 --dry-run --min-size 0 --sort-by-size small.mp4 big.mp4'
    local o; o=$(grep -oE "▸ (\[[0-9]/2\] )?(small|big)" <<< "$OUT" | grep -oE "small|big" | tr '\n' ' ')
    [[ "$o" == "small big big small " ]]; verdict $? "order: $o"

    begin "--sort-by-date [asc|desc]" "asc: oldest first"
    fx base.mp4 new.mp4; fx base.mp4 old.mp4; touch -d 2020-01-01 old.mp4; touch -d 2025-01-01 new.mp4
    run 'convert-to-vp9 --dry-run --sort-by-date asc new.mp4 old.mp4'
    o=$(grep -oE "▸ \[[0-9]/2\] (old|new)" <<< "$OUT" | grep -oE "old|new" | tr '\n' ' ')
    [[ "$o" == "old new " ]]; verdict $? "order: $o"

    begin "--sort-by-bitrate [asc|desc]" "default desc: noise (fat) before testsrc (thin)"
    fx thin.mp4; fx fat.mp4
    run 'convert-to-vp9 --dry-run --min-size 0 --sort-by-bitrate thin.mp4 fat.mp4'
    o=$(grep -oE "▸ \[[0-9]/2\] (thin|fat)" <<< "$OUT" | grep -oE "thin|fat" | tr '\n' ' ')
    [[ "$o" == "fat thin " ]]; verdict $? "order: $o"

    begin "--min-size SIZE" "820K file skipped with --min-size 1M"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 -v --dry-run --min-size 1M a.mp4'
    has "Skipped \(too small: 838K < 1.0M\)" && has "No video files found"; verdict $? "$(grep -o 'Skipped (too small[^)]*)' <<< "$OUT")"

    begin "--min-bitrate RATE" "800k: thin dropped, fat kept"
    fx thin.mp4; fx fat.mp4
    run 'convert-to-vp9 --dry-run --min-size 0 --min-bitrate 800k thin.mp4 fat.mp4'
    has "thin.mp4 .*below min-bitrate" && has "fat.mp4 .*DRYRUN"; verdict $? "thin=$(grep -oE 'thin.mp4 +[A-Z]+' <<< "$OUT" | awk '{print $2}') fat=$(grep -oE 'fat.mp4 +[A-Z]+' <<< "$OUT" | awk '{print $2}')"

    begin "--exclude PATTERN" "'skip-*' excluded, keep-me queued"
    fx base.mp4 skip-me.mp4; fx base.mp4 keep-me.mp4
    run "convert-to-vp9 --dry-run --exclude 'skip-*' skip-me.mp4 keep-me.mp4"
    has "skip-me.mp4 .*excluded" && has "keep-me.mp4 .*DRYRUN"; verdict $? "skip-me=excluded:$(has 'skip-me.mp4 .*excluded' && echo yes) keep-me=$(grep -oE 'keep-me.mp4 +[A-Z]+' <<< "$OUT" | awk '{print $2}')"

    begin "--ignore PATTERN (case-insensitive)" "'*SKIP*' matches skip-me.mp4"
    fx base.mp4 skip-me.mp4; fx base.mp4 keep-me.mp4
    run "convert-to-vp9 --dry-run --ignore '*SKIP*' skip-me.mp4 keep-me.mp4"
    has "skip-me.mp4 .*excluded" && has "keep-me.mp4 .*DRYRUN"; verdict $? "skip-me excluded=$(has 'skip-me.mp4 .*excluded' && echo yes || echo no)"

    begin "--exclude codec:NAME" "codec:x264 drops the H.264 file; codec:vp9 drops the VP9 file"
    fx base.mp4 h.mp4; fx vp9.mkv v.mkv
    run 'convert-to-vp9 --dry-run --exclude codec:x264 h.mp4 v.mkv; convert-to-vp9 --dry-run --exclude codec:vp9 h.mp4 v.mkv'
    [[ $(grep -c "h.mp4 .*excluded" <<< "$OUT") -eq 1 && $(grep -c "v.mkv .*excluded" <<< "$OUT") -eq 1 ]]; verdict $? "h.mp4 excluded $(grep -c 'h.mp4 .*excluded' <<< "$OUT")x, v.mkv excluded $(grep -c 'v.mkv .*excluded' <<< "$OUT")x"

    begin "--skip-log" "SSIM failure recorded in .convert-skip.list, skipped on re-run"
    mkdir d; fx base.mp4 d/a.mp4
    run 'convert-to-vp9 --min-ssim 0.9999 --skip-log d; convert-to-vp9 -v --dry-run --skip-log d'
    grep -q "a.mp4" d/.convert-skip.list 2>/dev/null && has "In skip-log \(previously not worth converting\)" && ! has "DRYRUN"
    verdict $? "list: $(cut -f2,4 d/.convert-skip.list 2>/dev/null | tr '\t' ' '); re-run: $(grep -o 'In skip-log[^:]*' <<< "$OUT" | head -1)"

    begin "--skip-log=FILE" "entry written to the named list"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --min-ssim 0.9999 --skip-log=my.list a.mp4'
    grep -q "a.mp4" my.list 2>/dev/null; verdict $? "my.list: $(cut -f2,4 my.list 2>/dev/null | tr '\t' ' ')"

    begin "--dry-run" "stream table + DRYRUN, no file written"
    fx multi.mkv m.mkv
    run 'convert-to-vp9 --dry-run --langs fr,en m.mkv'
    [[ $(nfiles) -eq 1 ]] && has "DRYRUN" && has "✗ skip"; verdict $? "files in dir after run: $(nfiles)"

    begin "--after CMD" "command runs after the batch"
    fx base.mp4 a.mp4
    run "convert-to-vp9 --after 'touch done.marker' a.mp4"
    [[ -f done.marker ]]; verdict $? "marker=$([[ -f done.marker ]] && echo created || echo missing)"

    begin "(skip) VP9 source" "already VP9 -> skipped, file untouched"
    fx vp9.mkv v.mkv; local s0; s0=$(fsize v.mkv)
    run 'convert-to-vp9 --min-size 0 v.mkv'
    has "already VP9" && [[ $(fsize v.mkv) -eq $s0 ]]; verdict $? "$(grep -o 'Already VP9[^:]*' <<< "$OUT")"

    if [[ -f "$FIX/av1.mkv" ]]; then
        begin "(skip) AV1 source" "already AV1 -> skipped by default"
        fx av1.mkv v.mkv
        run 'convert-to-vp9 --min-size 0 v.mkv'
        has "already AV1" && [[ $(vcodec v.mkv) == av1 ]]; verdict $? "$(grep -o 'Already AV1 ([^)]*)' <<< "$OUT")"

        begin "--convert-av1" "AV1 source re-encoded to VP9"
        fx av1.mkv v.mkv
        run 'convert-to-vp9 --min-size 0 --convert-av1 -o out v.mkv'
        [[ $(vcodec out/v.mkv) == vp9 ]]; verdict $? "out=$(vcodec out/v.mkv)"
    fi
}

# -- audio --------------------------------------------------------------------
g_audio() {
    local a ch
    begin "--copy-audio" "320k AAC kept as AAC"
    fx hiaudio.mkv s.mkv
    run 'convert-to-vp9 --copy-audio -o out s.mkv'
    a=$(acodecs out/s.mkv); [[ $a == aac ]]; verdict $? "audio=$a"

    begin "--opus" "all 3 tracks Opus, 5.1 keeps 6 channels (no downmix)"
    fx multi.mkv m.mkv
    run 'convert-to-vp9 --opus -o out m.mkv'
    a=$(acodecs out/m.mkv); ch=$(achans out/m.mkv); [[ $a == opus,opus,opus && $ch == 2,6,2 ]]; verdict $? "codecs=$a channels=$ch"

    begin "--auto-audio (default)" "hidden-bitrate 320k AAC packet-sampled (~k) -> Opus"
    fx hiaudio.mkv s.mkv
    run 'convert-to-vp9 --auto-audio -o out s.mkv'
    a=$(acodecs out/s.mkv); [[ $a == opus ]] && has "~[0-9]+k"; verdict $? "audio=$a estimate=$(grep -oE '~[0-9]+k' <<< "$OUT" | head -1)"

    begin "--audio-threshold KB/S" "threshold 400: 320k AAC copied; threshold 50: 64k AAC -> Opus"
    fx hiaudio.mkv s.mkv; fx base.mp4 a.mp4
    run 'convert-to-vp9 --audio-threshold 400 -o out s.mkv; convert-to-vp9 --audio-threshold 50 -o out a.mp4'
    [[ $(acodecs out/s.mkv) == aac && $(acodecs out/a.mkv) == opus ]]; verdict $? "s.mkv=$(acodecs out/s.mkv) a.mkv=$(acodecs out/a.mkv)"

    begin "(Opus source) + --opus" "already-Opus track copied, never re-encoded"
    fx opus.mkv o.mkv
    run 'convert-to-vp9 --opus -o out o.mkv'
    has "✓ copy +opus" && [[ $(acodecs out/o.mkv) == opus ]]; verdict $? "table: $(grep -oE '(✓ copy|↻ opus) +opus' <<< "$OUT" | head -1)"

    begin "(5.1(side) PCM) + --opus" "layout normalised for libopus, 6 channels"
    fx side51.mkv s.mkv
    run 'convert-to-vp9 --opus -o out s.mkv'
    a=$(acodecs out/s.mkv); ch=$(achans out/s.mkv); [[ $a == opus && $ch == 6 ]]; verdict $? "codec=$a channels=$ch layout=$(pf a channel_layout out/s.mkv)"
}

# -- track selection, subtitles, profiles --------------------------------------
g_tracks() {
    begin "--langs LIST" "fr,en: audio eng,fre + subs eng,fre (spa dropped)"
    fx multi.mkv m.mkv
    run 'convert-to-vp9 --langs fr,en -o out m.mkv'
    [[ $(alangs out/m.mkv) == eng,fre && $(slangs out/m.mkv) == eng,fre ]]; verdict $? "audio=$(alangs out/m.mkv) subs=$(slangs out/m.mkv)"

    begin "--audio-langs LIST" "fr: audio fre only, subs untouched"
    fx multi.mkv m.mkv
    run 'convert-to-vp9 --audio-langs fr -o out m.mkv'
    [[ $(alangs out/m.mkv) == fre && $(slangs out/m.mkv) == eng,fre ]]; verdict $? "audio=$(alangs out/m.mkv) subs=$(slangs out/m.mkv)"

    begin "--sub-langs LIST" "en: subs eng only, all 3 audio kept"
    fx multi.mkv m.mkv
    run 'convert-to-vp9 --sub-langs en -o out m.mkv'
    [[ $(alangs out/m.mkv) == eng,fre,spa && $(slangs out/m.mkv) == eng ]]; verdict $? "audio=$(alangs out/m.mkv) subs=$(slangs out/m.mkv)"

    begin "--audio-langs (no match)" "de: nothing matches -> all audio kept + warning"
    fx multi.mkv m.mkv
    run 'convert-to-vp9 --audio-langs de -o out m.mkv'
    [[ $(alangs out/m.mkv) == eng,fre,spa ]] && has "keeping all audio"; verdict $? "audio=$(alangs out/m.mkv)"

    begin "--audio-tracks LIST" "a:2 -> spa only; 1,3 (absolute) -> eng,spa"
    fx multi.mkv m.mkv; fx multi.mkv n.mkv
    run 'convert-to-vp9 --audio-tracks a:2 -o out m.mkv; convert-to-vp9 --audio-tracks 1,3 -o out n.mkv'
    [[ $(alangs out/m.mkv) == spa && $(alangs out/n.mkv) == eng,spa ]]; verdict $? "a:2 -> $(alangs out/m.mkv); 1,3 -> $(alangs out/n.mkv)"

    begin "--audio-tracks (unmatched)" "a:9 -> all audio kept + warning"
    fx multi.mkv m.mkv
    run 'convert-to-vp9 --audio-tracks a:9 -o out m.mkv'
    [[ $(nstreams a out/m.mkv) -eq 3 ]] && has "No audio track matched"; verdict $? "audio tracks=$(nstreams a out/m.mkv)"

    begin "--copy-streams" "remux: H.264 kept, --langs fr,en filter applied"
    fx multi.mkv m.mkv
    run 'convert-to-vp9 --copy-streams --langs fr,en -o out m.mkv'
    [[ $(vcodec out/m.mkv) == h264 && $(alangs out/m.mkv) == eng,fre ]] && has "Remux only"; verdict $? "video=$(vcodec out/m.mkv) audio=$(alangs out/m.mkv)"

    begin "--remux (on a VP9 source)" "not skipped as VP9: remuxed in place, still VP9"
    fx vp9.mkv v.mkv
    run 'convert-to-vp9 --remux --min-size 0 v.mkv'
    ! has "already VP9" && has "Remux only" && [[ $(vcodec v.mkv) == vp9 ]]; verdict $? "status=$(grep -oE 'v.mkv +[A-Z]+' <<< "$OUT" | awk '{print $2}') codec=$(vcodec v.mkv)"

    begin "(mov_text subs in MP4)" "converted to SRT (MKV cannot hold mov_text), language kept"
    fx movtext.mp4 t.mp4
    run 'convert-to-vp9 t.mp4'
    [[ $(pf s codec_name t.mkv) == subrip && $(slangs t.mkv) == eng ]] && has "↻ srt"; verdict $? "subs=$(pf s codec_name t.mkv) lang=$(slangs t.mkv)"

    begin "(mov_text) + --copy-streams" "remux works too: video h264, subs subrip"
    fx movtext.mp4 t.mp4
    run 'convert-to-vp9 --copy-streams t.mp4'
    [[ $(vcodec t.mkv) == h264 && $(pf s codec_name t.mkv) == subrip ]]; verdict $? "video=$(vcodec t.mkv) subs=$(pf s codec_name t.mkv)"

    begin "(sidecar .srt merge, default)" "a.srt + a.fr.srt muxed as 2 subtitle tracks"
    fx base.mp4 a.mp4; cp "$FIX/en.srt" a.srt; cp "$FIX/fr.srt" a.fr.srt
    run 'convert-to-vp9 a.mp4'
    [[ $(nstreams s a.mkv) -eq 2 ]]; verdict $? "subtitle tracks=$(nstreams s a.mkv)"

    begin "--no-merge-subs" "sidecar .srt not muxed"
    fx base.mp4 a.mp4; cp "$FIX/en.srt" a.srt
    run 'convert-to-vp9 --no-merge-subs a.mp4'
    [[ $(nstreams s a.mkv) -eq 0 ]]; verdict $? "subtitle tracks=$(nstreams s a.mkv)"

    begin "--rm-src (sidecars)" "merged .srt removed with the source, .txt kept + embedded"
    fx base.mp4 a.mp4; cp "$FIX/en.srt" a.srt; echo "A test description" > a.txt
    run 'convert-to-vp9 --rm-src a.mp4'
    local d; d=$(ffprobe -v error -show_entries format_tags=description -of csv=p=0 a.mkv)
    [[ ! -e a.srt && ! -e a.mp4 && -f a.txt && "$d" == "A test description" ]]; verdict $? "srt=$([[ -e a.srt ]] && echo kept || echo removed) txt=$([[ -e a.txt ]] && echo kept) description='$d'"

    begin ".convert-profile" "--crf 40 from the folder's profile reaches the encoder"
    mkdir d; fx base.mp4 d/a.mp4; echo "--crf 40" > d/.convert-profile
    run 'convert-to-vp9 -v d/a.mp4'
    has "-crf 40 -b:v 0" && [[ $(vcodec d/a.mkv) == vp9 ]]; verdict $? "$(grep -oE -- '-crf [0-9]+ -b:v 0' <<< "$OUT" | head -1)"

    begin "--no-profile" "profile ignored: default -crf 32"
    mkdir d; fx base.mp4 d/a.mp4; echo "--crf 40" > d/.convert-profile
    run 'convert-to-vp9 -v --no-profile d/a.mp4'
    has "-crf 32 -b:v 0"; verdict $? "$(grep -oE -- '-crf [0-9]+ -b:v 0' <<< "$OUT" | head -1)"

    begin ".convert-profile --hq vs CLI --crf" "CLI --crf 40 survives the profile's --hq"
    mkdir d; fx base.mp4 d/a.mp4; echo "--hq" > d/.convert-profile
    run 'convert-to-vp9 --dry-run --crf 40 d/a.mp4'
    has "cpu-used=1 crf=40"; verdict $? "$(grep -oE 'cpu-used=[0-9]+ crf=[0-9]+ [^ ]+ [^ ]+' <<< "$OUT" | head -1)"
}

# -- logging, progress, savings, misc ------------------------------------------
g_logging() {
    begin "-l, --log FILE" "TSV log: session header (libvpx-vp9) + OK line"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --log run.log a.mp4'
    grep -q "^# ── session .*convert-to-vp9" run.log && grep -q "encoder: libvpx-vp9" run.log && grep -qP "\tOK " run.log
    verdict $? "$(grep -P '\tOK' run.log | cut -f2-5 | tr '\t' ' ')"

    begin "--stats FILE" "report: OK 1, converted totals"
    printf '2026-01-01T00:00:00\tOK      \tin=10M\tout=4M\tsaved=60%%\ttook=00:01:00\t\t/x/v.mp4\n' > run.log
    run 'convert-to-vp9 --stats run.log'
    has "OK +1" && has "converted \.+ 10M -> 4M \(saved 6M, 60%\)"; verdict $? "$(grep -o 'converted .*' <<< "$OUT")"

    begin "--stats-live FILE" "follows the log until killed (timeout rc 124)"
    printf '2026-01-01T00:00:00\tOK      \tin=10M\tout=4M\tsaved=60%%\ttook=00:01:00\t\t/x/v.mp4\n' > run.log
    run 'NO_COLOR=1 timeout 4 bash "$CONVERT_BIN" --stats-live run.log < /dev/null; echo "rc=$?"'
    has "rc=124" && has "OK +1"; verdict $? "$(grep -o 'rc=[0-9]*' <<< "$OUT") stats=$(has 'OK +1' && echo shown)"

    begin "-v, --verbose" "debug lines incl. the full ffmpeg command"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 -v a.mp4'
    has "\[debug\] CMD: ffmpeg"; verdict $? "$(grep -c '\[debug\]' <<< "$OUT") debug lines"

    begin "--no-progress" "no progress bar"
    fx base.mp4 a.mp4
    run 'convert-to-vp9 --no-progress a.mp4'
    ! has "\[ *[0-9]+%\]"; verdict $? "bar lines=$(grep -cE '\[ *[0-9]+%\]' <<< "$OUT")"

    begin "(progress, live estimate)" "progress bar with 'est. SIZE saved=N%'"
    fx hd.mp4 h.mp4
    run 'convert-to-vp9 --fast h.mp4'
    local est; est=$(tr '\r' '\n' <<< "$OUT" | grep -oE 'est\. [0-9.]+[KMG]? (saved|larger)=[+0-9]+%' | tail -1)
    [[ -n "$est" ]]; verdict $? "last estimate: $est; final: $(grep -oE 'SAVED [^ ]+ \([0-9.]+%\)' <<< "$OUT")"

    begin "(savings) per file + batch + total" "exact byte totals == stat sizes; freed/pending split"
    mkdir keep; fx base.mp4 keep/a.mp4; fx base.mkv keep/b.mkv
    local ia ib; ia=$(fsize keep/a.mp4); ib=$(fsize keep/b.mkv)
    run 'convert-to-vp9 --sort-by-size asc keep'
    local oa ob; oa=$(fsize keep/a.mkv); ob=$(fsize keep/b.mkv)
    local tin=$((ia + ib)) tout=$((oa + ob))
    has "exact \.+ ${tin} -> ${tout} bytes = $((tin - tout)) bytes saved" \
        && has "freed now \.+ .*\($((ib - ob)) bytes, 1 file" \
        && has "pending \.+ .*\($((ia - oa)) bytes, 1 file" \
        && has "^batch: 1/2 done \| saved"
    verdict $? "stat: ${tin} -> ${tout} (saved $((tin - tout)) = freed $((ib - ob)) + pending $((ia - oa))); printed: $(grep -o 'exact .*' <<< "$OUT")"

    begin "NO_COLOR" "TTY: ANSI colours by default, none with NO_COLOR=1"
    fx base.mp4 a.mp4
    run 'script -qec "bash \"$CONVERT_BIN\" --dry-run a.mp4" /dev/null > col.txt; NO_COLOR=1 script -qec "bash \"$CONVERT_BIN\" --dry-run a.mp4" /dev/null > nocol.txt'
    local c1 c2; c1=$(grep -c $'\033\[0;3' col.txt); c2=$(grep -c $'\033\[0;3' nocol.txt)
    [[ $c1 -gt 0 && $c2 -eq 0 ]]; verdict $? "coloured lines: default=$c1 NO_COLOR=$c2"

    begin "(key >) skip current file" "'>' on the TTY skips the running encode"
    fx hd.mp4 h.mp4
    run '(sleep 3; printf ">") | script -qec "bash \"$CONVERT_BIN\" h.mp4" /dev/null > key.txt; cat key.txt'
    has "Skipped by user" && [[ ! -e h.mkv && $(leftovers) -eq 0 ]]; verdict $? "$(grep -o 'Skipped by user' <<< "$OUT" | head -1); leftovers=$(leftovers)"

    begin "(Ctrl-C) interrupt cleanup" "SIGINT to the process group: batch stops (2nd file never starts), temp/lock/pass log removed, source intact"
    mkdir b; fx hd.mp4 b/one.mp4; fx hd.mp4 b/two.mp4; local s0; s0=$(fsize b/one.mp4)
    run 'setsid bash -c "NO_COLOR=1 bash \"$CONVERT_BIN\" --hq b < /dev/null" > int.txt 2>&1 & p=$!; sleep 3; kill -INT -- -$p; for i in $(seq 1 30); do sleep 1; pgrep -g $p > /dev/null || break; done; tr "\r" "\n" < int.txt'
    local pl lo; pl=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'convert-*-2pass-*' | wc -l)
    lo=$(find b -maxdepth 1 \( -name '.convert-*' -o -name '*.lock' -o -name '*.mkv' \) | wc -l)
    [[ $(fsize b/one.mp4) -eq $s0 && $lo -eq 0 && $pl -eq 0 ]] && has "Interrupted" && ! has "\[2/2\]"
    verdict $? "Interrupted=$(has Interrupted && echo yes) 2nd-file-started=$(has '\[2/2\]' && echo yes || echo no) leftovers=$lo tmp-passlogs=$pl source=$([[ $(fsize b/one.mp4) -eq $s0 ]] && echo intact)"

    begin "--check" "libvpx-vp9 (10-bit) and libopus reported OK"
    run 'convert-to-vp9 --check'
    [[ $RC -eq 0 ]] && has "libvpx-vp9 OK .*10-bit OK" && has "libopus +OK"; verdict $? "$(grep -o 'libvpx-vp9 OK.*' <<< "$OUT")"

    begin "-h, --help" "usage for convert-to-vp9 incl. --2pass/--cpu-used"
    run 'convert-to-vp9 -h; convert-to-vp9 --help'
    [[ $(grep -c "Usage: convert-to-vp9" <<< "$OUT") -eq 2 ]] && has "--2pass" && has "--cpu-used"; verdict $? "$(grep -c 'Usage: convert-to-vp9' <<< "$OUT") usage blocks"

    begin "--version" "convert-to-vp9 v1.0.0"
    run 'convert-to-vp9 --version'
    has "^convert-to-vp9 v1\.0\.0$"; verdict $? "$OUT"
}

# -- report -------------------------------------------------------------------
report() {
    [[ -f "$RESULTS" ]] || { echo "no results in $RESULTS"; exit 1; }
    local p f
    p=$(awk -F'\t' '$6=="PASS"' "$RESULTS" | wc -l); f=$(awk -F'\t' '$6!="PASS"' "$RESULTS" | wc -l)
    {
        echo "# convert-to-vp9 — option test matrix"
        echo ""
        echo "Generated by \`option-matrix.sh\` on $(date -Iseconds) with $(ffmpeg -version | sed -n 1p | cut -d' ' -f1-3)."
        echo "Every row ran the command shown (in a fresh directory holding copies of the"
        echo "synthetic fixtures) and checked the result with ffprobe or real file sizes."
        echo ""
        echo "**Result: ${p} passed, ${f} failed.**"
        echo ""
        echo "| # | Option | Command | Expected | Actual | Result |"
        echo "|---|---|---|---|---|---|"
        awk -F'\t' '{
            for (i = 1; i <= 6; i++) gsub(/\|/, "\\|", $i)
            printf "| %d | `%s` | `%s` | %s | %s | %s |\n", NR, $2, $3, $4, $5, ($6 == "PASS" ? "✅ pass" : "❌ FAIL")
        }' "$RESULTS"
        echo ""
        echo "## Not covered by this matrix"
        echo ""
        echo "- GitLab CI (\`.gitlab-ci.yml\`) — not run on GitLab (no runner available). Checked locally: YAML parses; the jobs' check commands (bash -n, shellcheck 0.9.0 as shipped by Ubuntu 24.04 and 0.11.0, --check, test.sh, option-matrix.sh) pass on Ubuntu 24.04, the image's base. The apt-get install step itself was not exercised."
        echo "- The disk-space guard is tested with a shimmed \`df\` (no real full filesystem)."
        echo "- Real broadcast material (DVB teletext/PGS subtitles, interlaced TV, real HDR10 mastering metadata) — fixtures are synthetic."
        echo "- Visual quality judgement — SSIM only."
    } > "$REPORT"
    echo "report: $REPORT (${p} passed, ${f} failed)"
}

ALL_GROUPS=(output files quality video batch audio tracks logging)

run_group() {
    GROUP="$1"
    declare -F "g_$1" >/dev/null || { echo "unknown group: $1"; exit 2; }
    # Re-running a group replaces its rows instead of duplicating them
    if [[ -f "$RESULTS" ]]; then
        awk -F'\t' -v g="$1" '$1 != g' "$RESULTS" > "$RESULTS.tmp" && mv "$RESULTS.tmp" "$RESULTS"
    fi
    printf '\n== %s\n' "$1"
    "g_$1"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cd "$MATRIX_DIR" || exit 1
    case "${1:-all}" in
        all)
            rm -f "$RESULTS"
            GROUP=fixtures; g_fixtures
            for g in "${ALL_GROUPS[@]}"; do run_group "$g"; done
            report ;;
        report) report ;;
        fixtures) g_fixtures ;;
        *) for g in "$@"; do run_group "$g"; done ;;
    esac
    printf '\nthis run: %d passed, %d failed\n' "$N_PASS" "$N_FAIL"
    exit $(( N_FAIL > 0 ))
fi
