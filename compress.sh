#!/usr/bin/env bash
#
# compress.sh - compress-mp4: Batch video compressor using H.265/HEVC
#
# Converts MP4/MOV/AVI/MKV videos to H.265/HEVC with optional downscaling.
# Supports resume — stop anytime and restart to pick up where you left off.

set -euo pipefail

VERSION="2.5.0"

# --- Defaults ---
CRF=24
PRESET="medium"
MAX_WIDTH=1920
OUTPUT_DIR="converted"
REPLACE=false
DRY_RUN=false
FORCE=false
AUDIO_BITRATE="128k"
SOFTWARE=false
JOBS=1

# --- Colors ---
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# --- State ---
CURRENT_TEMP=""
CURRENT_PROGRESS=""
FFMPEG_PID=""
TOTAL_FILES=0
PROCESSED=0
SKIPPED=0
FAILED=0
TOTAL_ORIGINAL_SIZE=0
TOTAL_COMPRESSED_SIZE=0
START_TIME=""
DRY_RUN_TOTAL=0
DRY_RUN_EST_LOW=0
DRY_RUN_EST_HIGH=0
DRY_RUN_WOULD_CONVERT=0
DRY_RUN_DOWNSCALED=0
INPUT_FILES=()
CHILD_PIDS=()
BARS_ACTIVE=false

# --- Helpers ---

usage() {
    cat <<EOF
Usage: ./compress.sh [OPTIONS] [FILE ...]

Batch compress MP4/MOV/AVI/MKV videos using H.265/HEVC.

If no files are given, all .mp4, .mov, .avi, and .mkv files in the current directory are processed.
If one or more files are given, only those files are processed.
Compressed files are written to an output directory (always as .mp4). The script tracks
completed files, so you can stop it anytime (Ctrl+C) and resume later.

OPTIONS:
    -c, --crf <N>             Quality (0-51, lower = better). Default: 24
    -p, --preset <NAME>       Encoding speed/quality tradeoff. Default: medium
                              ultrafast, superfast, veryfast, faster, fast,
                              medium, slow, slower, veryslow
    -w, --max-width <N>       Max output width in pixels. Default: 1920
                              Videos narrower than this won't be upscaled.
                              Use 0 to keep original resolution.
    -o, --output-dir <DIR>    Output directory. Default: converted
    -a, --audio-bitrate <RATE>  Audio bitrate. Default: 128k
        --replace             Delete originals after successful conversion
        --force               Re-convert all files, ignoring previous completions
        --dry-run             Show what would happen without converting
        --software            Use software encoder (libx265) instead of hardware
    -j, --jobs <N>            Parallel conversions (for hardware encoder). Default: 1
    -h, --help                Show this help
    -v, --version             Show version

EXAMPLES:
    # Default settings (CRF 24, medium, cap at 1080p)
    ./compress.sh

    # Preview what would happen
    ./compress.sh --dry-run

    # Quick test run — fast but larger files
    ./compress.sh --crf 28 --preset ultrafast

    # High quality, slower encoding
    ./compress.sh --crf 20 --preset slow

    # Keep original resolution
    ./compress.sh --max-width 0

    # Try on a single file first
    ./compress.sh my_video.mp4

    # Production: high quality + delete originals when done
    ./compress.sh --crf 22 --preset slow --replace
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--crf)
                [[ -z "${2:-}" ]] && { echo "Error: --crf requires a value" >&2; exit 1; }
                CRF="$2"; shift 2 ;;
            -p|--preset)
                [[ -z "${2:-}" ]] && { echo "Error: --preset requires a value" >&2; exit 1; }
                PRESET="$2"; shift 2 ;;
            -w|--max-width)
                [[ -z "${2:-}" ]] && { echo "Error: --max-width requires a value" >&2; exit 1; }
                MAX_WIDTH="$2"; shift 2 ;;
            -o|--output-dir)
                [[ -z "${2:-}" ]] && { echo "Error: --output-dir requires a value" >&2; exit 1; }
                OUTPUT_DIR="$2"; shift 2 ;;
            -a|--audio-bitrate)
                [[ -z "${2:-}" ]] && { echo "Error: --audio-bitrate requires a value" >&2; exit 1; }
                AUDIO_BITRATE="$2"; shift 2 ;;
            --replace)
                REPLACE=true; shift ;;
            --dry-run)
                DRY_RUN=true; shift ;;
            --force)
                FORCE=true; shift ;;
            --software)
                SOFTWARE=true; shift ;;
            -j|--jobs)
                [[ -z "${2:-}" ]] && { echo "Error: --jobs requires a value" >&2; exit 1; }
                JOBS="$2"; shift 2 ;;
            -h|--help)
                usage; exit 0 ;;
            -v|--version)
                echo "compress.sh v${VERSION}"; exit 0 ;;
            -*)
                echo "Unknown option: $1" >&2
                echo "Use --help for usage information." >&2
                exit 1 ;;
            *)
                INPUT_FILES+=("$1"); shift ;;
        esac
    done
}

human_size() {
    local bytes=$1
    if [[ $bytes -ge 1000000000 ]]; then
        printf "%.2f GB" "$(echo "$bytes / 1000000000" | bc -l)"
    elif [[ $bytes -ge 1000000 ]]; then
        printf "%.1f MB" "$(echo "$bytes / 1000000" | bc -l)"
    elif [[ $bytes -ge 1000 ]]; then
        printf "%.1f KB" "$(echo "$bytes / 1000" | bc -l)"
    else
        echo "${bytes} B"
    fi
}

format_duration() {
    local seconds=$1
    local h=$((seconds / 3600))
    local m=$(( (seconds % 3600) / 60 ))
    local s=$((seconds % 60))
    if [[ $h -gt 0 ]]; then
        printf "%dh %02dm %02ds" "$h" "$m" "$s"
    elif [[ $m -gt 0 ]]; then
        printf "%dm %02ds" "$m" "$s"
    else
        printf "%ds" "$s"
    fi
}

file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

probe_field() {
    local file="$1" stream_entry="$2" format_entry="${3:-}"
    if [[ -n "$format_entry" ]]; then
        ffprobe -v quiet -select_streams v:0 \
            -show_entries "stream=${stream_entry}:format=${format_entry}" \
            -of csv=p=0:nk=1 "$file" 2>/dev/null | head -1
    else
        ffprobe -v quiet -select_streams v:0 \
            -show_entries "stream=${stream_entry}" \
            -of csv=p=0 "$file" 2>/dev/null | head -1
    fi
}

# Estimate compressed size range based on CRF and downscale.
# Prints "low_bytes high_bytes" to stdout.
estimate_compression() {
    local orig_size=$1 source_width=$2 source_height=$3

    # CRF-based compression factor (expected output/input ratio for H.264 → H.265)
    local factor_low factor_high
    if   [[ $CRF -le 19 ]]; then factor_low=0.35; factor_high=0.55
    elif [[ $CRF -le 21 ]]; then factor_low=0.28; factor_high=0.48
    elif [[ $CRF -le 23 ]]; then factor_low=0.22; factor_high=0.40
    elif [[ $CRF -le 25 ]]; then factor_low=0.18; factor_high=0.35
    elif [[ $CRF -le 27 ]]; then factor_low=0.15; factor_high=0.30
    elif [[ $CRF -le 30 ]]; then factor_low=0.12; factor_high=0.25
    else                          factor_low=0.08; factor_high=0.20
    fi

    # Apply downscale factor based on pixel count reduction
    if [[ $MAX_WIDTH -gt 0 && "$source_width" != "?" && "$source_height" != "?" \
          && $source_width -gt $MAX_WIDTH ]]; then
        local target_h=$(( source_height * MAX_WIDTH / source_width ))
        local source_px=$(( source_width * source_height ))
        local target_px=$(( MAX_WIDTH * target_h ))
        # Bitrate doesn't scale perfectly linearly with pixels, so use sqrt
        # of pixel ratio as a conservative downscale factor
        local scale
        scale=$(echo "scale=6; sqrt($target_px / $source_px)" | bc -l)
        factor_low=$(echo "scale=6; $factor_low * $scale" | bc -l)
        factor_high=$(echo "scale=6; $factor_high * $scale" | bc -l)
    fi

    local est_low est_high
    est_low=$(echo "scale=0; $orig_size * $factor_low / 1" | bc)
    est_high=$(echo "scale=0; $orig_size * $factor_high / 1" | bc)
    echo "$est_low $est_high"
}

draw_progress() {
    local pct=$1 speed="$2" eta_s="$3" projected="$4"
    local bar_width=30
    local filled=$(( pct * bar_width / 100 ))
    local empty=$(( bar_width - filled ))

    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="\xe2\x96\x88"; done
    for ((i=0; i<empty; i++)); do bar+="\xe2\x96\x91"; done

    local eta_str=""
    if [[ $eta_s -gt 0 ]]; then
        eta_str="ETA $(format_duration "$eta_s")"
    fi

    local size_str=""
    if [[ -n "$projected" && "$projected" -gt 0 ]] 2>/dev/null; then
        size_str="~$(human_size "$projected")"
    fi

    printf "\r  ${bar} %3d%%  %6s  %-14s  %s   " "$pct" "$speed" "$eta_str" "$size_str"
}

print_header() {
    echo -e "${BOLD}${BLUE}"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │                compress-mp4 v${VERSION}                        │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
    if $SOFTWARE; then
        echo -e "  ${DIM}Codec:${NC}      H.265 (HEVC) via libx265 (software)"
        echo -e "  ${DIM}CRF:${NC}        ${BOLD}${CRF}${NC}"
        echo -e "  ${DIM}Preset:${NC}     ${BOLD}${PRESET}${NC}"
    else
        local vtq_display
        vtq_display=$(( 100 - (CRF * 100 / 51) ))
        [[ $vtq_display -lt 1 ]] && vtq_display=1
        [[ $vtq_display -gt 100 ]] && vtq_display=100
        echo -e "  ${DIM}Codec:${NC}      H.265 (HEVC) via VideoToolbox (hardware)"
        echo -e "  ${DIM}CRF:${NC}        ${BOLD}${CRF}${NC} (VT quality: ${vtq_display})"
    fi
    if [[ $MAX_WIDTH -gt 0 ]]; then
        echo -e "  ${DIM}Max width:${NC}  ${BOLD}${MAX_WIDTH}px${NC}"
    else
        echo -e "  ${DIM}Max width:${NC}  ${BOLD}original${NC}"
    fi
    echo -e "  ${DIM}Audio:${NC}      AAC @ ${BOLD}${AUDIO_BITRATE}${NC}"
    echo -e "  ${DIM}Output:${NC}     ${BOLD}${OUTPUT_DIR}/${NC}"
    if [[ $JOBS -gt 1 ]]; then
        echo -e "  ${DIM}Jobs:${NC}       ${BOLD}${JOBS}${NC} parallel"
    fi
    if $REPLACE; then
        echo -e "  ${DIM}Replace:${NC}    ${RED}${BOLD}yes — originals will be deleted${NC}"
    fi
    if $DRY_RUN; then
        echo -e ""
        echo -e "  ${YELLOW}${BOLD}>>> DRY RUN — no files will be modified <<<${NC}"
    fi
    echo ""
}

print_separator() {
    echo -e "${DIM}  ──────────────────────────────────────────────────────────${NC}"
}

print_summary() {
    local remaining=$((TOTAL_FILES - PROCESSED - SKIPPED - FAILED))

    echo -e "\n${BOLD}${BLUE}"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │                        Summary                          │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo -e "${NC}"
    echo -e "  ${DIM}Total files:${NC}   ${TOTAL_FILES}"
    echo -e "  ${DIM}Converted:${NC}     ${GREEN}${PROCESSED}${NC}"
    [[ $SKIPPED -gt 0 ]] && echo -e "  ${DIM}Skipped:${NC}       ${CYAN}${SKIPPED}${NC} (already done)"
    [[ $FAILED -gt 0 ]]  && echo -e "  ${DIM}Failed:${NC}        ${RED}${FAILED}${NC}"
    [[ $remaining -gt 0 ]] && echo -e "  ${DIM}Remaining:${NC}     ${YELLOW}${remaining}${NC}"

    if [[ $TOTAL_ORIGINAL_SIZE -gt 0 && $TOTAL_COMPRESSED_SIZE -gt 0 ]]; then
        local saved=$((TOTAL_ORIGINAL_SIZE - TOTAL_COMPRESSED_SIZE))
        local pct
        pct=$(printf "%.1f" "$(echo "$TOTAL_COMPRESSED_SIZE * 100 / $TOTAL_ORIGINAL_SIZE" | bc -l)")
        echo ""
        echo -e "  ${DIM}Original:${NC}      $(human_size $TOTAL_ORIGINAL_SIZE)"
        echo -e "  ${DIM}Compressed:${NC}    $(human_size $TOTAL_COMPRESSED_SIZE)"
        echo -e "  ${DIM}Saved:${NC}         ${GREEN}$(human_size $saved)${NC} (compressed to ${GREEN}${pct}%${NC} of original)"
    fi

    if $DRY_RUN && [[ $DRY_RUN_TOTAL -gt 0 ]]; then
        local saved_low=$((DRY_RUN_TOTAL - DRY_RUN_EST_HIGH))
        local saved_high=$((DRY_RUN_TOTAL - DRY_RUN_EST_LOW))
        local pct_low pct_high
        pct_low=$(printf "%.0f" "$(echo "$DRY_RUN_EST_LOW * 100 / $DRY_RUN_TOTAL" | bc -l)")
        pct_high=$(printf "%.0f" "$(echo "$DRY_RUN_EST_HIGH * 100 / $DRY_RUN_TOTAL" | bc -l)")
        echo ""
        echo -e "  ${DIM}To convert:${NC}    ${DRY_RUN_WOULD_CONVERT} file(s)"
        [[ $DRY_RUN_DOWNSCALED -gt 0 ]] && \
            echo -e "  ${DIM}Will downscale:${NC} ${DRY_RUN_DOWNSCALED} file(s) (wider than ${MAX_WIDTH}px)"
        echo -e "  ${DIM}Original:${NC}      $(human_size $DRY_RUN_TOTAL)"
        echo -e "  ${DIM}Estimated:${NC}     $(human_size $DRY_RUN_EST_LOW) – $(human_size $DRY_RUN_EST_HIGH) (${GREEN}${pct_low}–${pct_high}%${NC} of original)"
        echo -e "  ${DIM}Est. savings:${NC}  ${GREEN}$(human_size $saved_low) – $(human_size $saved_high)${NC}"
        echo ""
        echo -e "  ${DIM}* Estimates based on typical H.265 compression ratios."
        echo -e "    Actual results vary with video content (motion, detail, etc.).${NC}"
    fi

    if [[ -n "$START_TIME" ]]; then
        local elapsed=$(( $(date +%s) - START_TIME ))
        echo -e "  ${DIM}Elapsed:${NC}       $(format_duration $elapsed)"
    fi
    echo ""
}

# --- Cleanup on interrupt ---

cleanup() {
    echo ""
    echo -e "  ${YELLOW}Interrupted!${NC}"

    if [[ $JOBS -gt 1 ]]; then
        # Clear progress bars if active
        if $BARS_ACTIVE; then
            local bar_lines=$((JOBS + 1))
            printf "\033[${bar_lines}A"
            for ((s=0; s<=JOBS; s++)); do printf "\033[2K\n"; done
            BARS_ACTIVE=false
        fi
        # Kill all active child processes
        for pid in "${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}"; do
            kill "$pid" 2>/dev/null || true
        done
        for pid in "${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}"; do
            wait "$pid" 2>/dev/null || true
        done
        # Clean up any leftover temp files
        for tmp in "${OUTPUT_DIR}"/*.tmp.mp4; do
            [[ -f "$tmp" ]] || continue
            rm -f "$tmp" "${tmp}.progress" "${tmp}.err"
        done
    else
        if [[ -n "$FFMPEG_PID" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
            kill "$FFMPEG_PID" 2>/dev/null || true
            wait "$FFMPEG_PID" 2>/dev/null || true
        fi

        # Clear progress bar line
        printf "\r%80s\r" ""

        if [[ -n "$CURRENT_PROGRESS" && -f "$CURRENT_PROGRESS" ]]; then
            rm -f "$CURRENT_PROGRESS"
        fi

        if [[ -n "$CURRENT_TEMP" ]]; then
            rm -f "$CURRENT_TEMP" "${CURRENT_TEMP}.err"
            [[ -f "$CURRENT_TEMP" ]] || echo -e "  ${DIM}Cleaned up incomplete file${NC}"
        fi
    fi

    print_summary
    echo -e "  ${CYAN}Run the script again to resume where you left off.${NC}"
    echo ""
    exit 130
}

trap cleanup SIGINT SIGTERM

# --- Core ---

convert_file() {
    local input="$1"
    local output="$2"
    local temp="${output}.tmp.mp4"
    local filename
    filename=$(basename "$input")

    # Probe video info
    local width height duration_s codec orig_size
    width=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input" 2>/dev/null || echo "?")
    height=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input" 2>/dev/null || echo "?")
    duration_s=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$input" 2>/dev/null || echo "0")
    codec=$(ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$input" 2>/dev/null || echo "?")
    orig_size=$(file_size "$input")

    # Format duration for display
    local dur_display="?"
    if [[ "$duration_s" != "0" && "$duration_s" != "?" && "$duration_s" != "N/A" ]]; then
        local dur_int=${duration_s%%.*}
        dur_display=$(format_duration "$dur_int")
    fi

    echo -e "  ${DIM}File:${NC}        ${BOLD}${filename}${NC}"
    echo -e "  ${DIM}Resolution:${NC}  ${width}x${height}"
    echo -e "  ${DIM}Duration:${NC}    ${dur_display}"
    echo -e "  ${DIM}Codec:${NC}       ${codec}"
    echo -e "  ${DIM}Size:${NC}        $(human_size "$orig_size")"

    if $DRY_RUN; then
        DRY_RUN_WOULD_CONVERT=$((DRY_RUN_WOULD_CONVERT + 1))
        DRY_RUN_TOTAL=$((DRY_RUN_TOTAL + orig_size))

        local will_downscale=false
        if [[ $MAX_WIDTH -gt 0 && "$width" != "?" && $width -gt $MAX_WIDTH ]]; then
            will_downscale=true
            DRY_RUN_DOWNSCALED=$((DRY_RUN_DOWNSCALED + 1))
        fi

        local est est_low est_high
        est=$(estimate_compression "$orig_size" "$width" "$height")
        est_low=${est% *}
        est_high=${est#* }
        DRY_RUN_EST_LOW=$((DRY_RUN_EST_LOW + est_low))
        DRY_RUN_EST_HIGH=$((DRY_RUN_EST_HIGH + est_high))

        local pct_low pct_high
        pct_low=$(printf "%.0f" "$(echo "$est_low * 100 / $orig_size" | bc -l)")
        pct_high=$(printf "%.0f" "$(echo "$est_high * 100 / $orig_size" | bc -l)")

        echo ""
        if $will_downscale; then
            local target_h=$(( height * MAX_WIDTH / width ))
            echo -e "  ${DIM}Downscale:${NC}   ${width}x${height} -> ${MAX_WIDTH}x${target_h}"
        fi
        echo -e "  ${DIM}Estimated:${NC}   $(human_size "$est_low") – $(human_size "$est_high") (${GREEN}${pct_low}–${pct_high}%${NC} of original)"
        return 0
    fi

    echo ""

    # Build scale filter
    local vf_args=()
    if [[ $MAX_WIDTH -gt 0 ]]; then
        vf_args=(-vf "scale='min(${MAX_WIDTH},iw)':-2")
    fi

    rm -f "$temp"
    CURRENT_TEMP="$temp"
    local progress_file="${temp}.progress"
    CURRENT_PROGRESS="$progress_file"
    local conv_start
    conv_start=$(date +%s)

    # Get total duration in microseconds for progress calculation
    local total_us=0
    if [[ "$duration_s" != "0" && "$duration_s" != "?" && "$duration_s" != "N/A" ]]; then
        total_us=$(echo "scale=0; ${duration_s} * 1000000 / 1" | bc)
    fi

    # Run ffmpeg in background with machine-readable progress output
    # Stderr goes to a log file so interrupt noise doesn't leak to terminal
    local error_log="${temp}.err"
    # Build encoder args
    local encoder_args=()
    if $SOFTWARE; then
        encoder_args=(
            -c:v libx265 -crf "$CRF" -preset "$PRESET"
            -x265-params log-level=error
            -tag:v hvc1
        )
    else
        # Map CRF (0-51, lower=better) to VideoToolbox quality (1-100, higher=better)
        local vtq
        vtq=$(( 100 - (CRF * 100 / 51) ))
        [[ $vtq -lt 1 ]] && vtq=1
        [[ $vtq -gt 100 ]] && vtq=100
        encoder_args=(
            -c:v hevc_videotoolbox -q:v "$vtq"
            -tag:v hvc1
        )
    fi

    ffmpeg -loglevel error -progress "$progress_file" -i "$input" \
        "${encoder_args[@]}" \
        ${vf_args[@]+"${vf_args[@]}"} \
        -c:a aac -b:a "$AUDIO_BITRATE" \
        -movflags +faststart \
        -n \
        "$temp" </dev/null >"$error_log" 2>&1 &

    FFMPEG_PID=$!

    # Poll progress file and draw progress bar
    while kill -0 "$FFMPEG_PID" 2>/dev/null; do
        if [[ -f "$progress_file" && $total_us -gt 0 ]]; then
            local cur_us speed cur_bytes
            eval "$(awk -F= '
                /^out_time_us/{us=$2}
                /^speed/{sp=$2}
                /^total_size/{sz=$2}
                END{printf "cur_us=%d speed=\"%s\" cur_bytes=%d", us+0, sp, sz+0}
            ' "$progress_file" 2>/dev/null)"
            speed=${speed// /}

            if [[ -n "$cur_us" && "$cur_us" != "0" ]]; then
                local pct=$(( cur_us * 100 / total_us ))
                [[ $pct -gt 100 ]] && pct=100

                local eta=0
                local elapsed=$(( $(date +%s) - conv_start ))
                if [[ $pct -gt 0 && $elapsed -gt 0 ]]; then
                    eta=$(( elapsed * (100 - pct) / pct ))
                fi

                local projected=0
                if [[ $pct -gt 2 && $cur_bytes -gt 0 ]]; then
                    projected=$(( cur_bytes * 100 / pct ))
                fi

                draw_progress "$pct" "${speed:-?}" "$eta" "$projected"
            fi
        fi
        sleep 1
    done

    wait "$FFMPEG_PID"
    local exit_code=$?
    FFMPEG_PID=""

    # Clear progress bar line and clean up progress file
    printf "\r%80s\r" ""
    rm -f "$progress_file"
    CURRENT_PROGRESS=""

    if [[ $exit_code -ne 0 ]]; then
        # Show error log for real failures (not interrupts)
        if [[ $exit_code -ne 130 && $exit_code -ne 255 ]]; then
            if [[ -s "$error_log" ]]; then
                echo -e "  ${RED}ffmpeg error:${NC}"
                cat "$error_log" >&2
            else
                echo -e "  ${RED}ffmpeg exited with code ${exit_code} (no error output)${NC}"
            fi
        fi
        rm -f "$temp" "$error_log"
        CURRENT_TEMP=""
        return 1
    fi

    rm -f "$error_log"
    mv "$temp" "$output"
    CURRENT_TEMP=""

    # Report results
    local new_size conv_elapsed
    new_size=$(file_size "$output")
    conv_elapsed=$(( $(date +%s) - conv_start ))

    local pct="?"
    local saved=0
    if [[ $orig_size -gt 0 ]]; then
        pct=$(printf "%.1f" "$(echo "$new_size * 100 / $orig_size" | bc -l)")
        saved=$((orig_size - new_size))
    fi

    echo ""
    echo -e "  ${GREEN}Done${NC} in $(format_duration $conv_elapsed)"
    echo -e "  ${DIM}New size:${NC}    $(human_size "$new_size") (${GREEN}${pct}%${NC} of original, saved ${GREEN}$(human_size $saved)${NC})"

    TOTAL_ORIGINAL_SIZE=$((TOTAL_ORIGINAL_SIZE + orig_size))
    TOTAL_COMPRESSED_SIZE=$((TOTAL_COMPRESSED_SIZE + new_size))

    if $REPLACE; then
        rm "$input"
        echo -e "  ${YELLOW}Original deleted${NC}"
    fi

    # Record completion
    echo "$filename" >> "${OUTPUT_DIR}/.done"
}

# Worker function for parallel mode — runs in subshell, no display output
run_conversion() {
    local input="$1"
    local output="$2"
    local result_file="$3"
    local temp="${output}.tmp.mp4"
    local error_log="${temp}.err"

    rm -f "$temp"

    local orig_size
    orig_size=$(file_size "$input")

    # Build scale filter
    local vf_args=()
    if [[ $MAX_WIDTH -gt 0 ]]; then
        vf_args=(-vf "scale='min(${MAX_WIDTH},iw)':-2")
    fi

    # Build encoder args
    local encoder_args=()
    if $SOFTWARE; then
        encoder_args=(
            -c:v libx265 -crf "$CRF" -preset "$PRESET"
            -x265-params log-level=error
            -tag:v hvc1
        )
    else
        local vtq
        vtq=$(( 100 - (CRF * 100 / 51) ))
        [[ $vtq -lt 1 ]] && vtq=1
        [[ $vtq -gt 100 ]] && vtq=100
        encoder_args=(
            -c:v hevc_videotoolbox -q:v "$vtq"
            -tag:v hvc1
        )
    fi

    ffmpeg -loglevel error -progress "${temp}.progress" -i "$input" \
        "${encoder_args[@]}" \
        ${vf_args[@]+"${vf_args[@]}"} \
        -c:a aac -b:a "$AUDIO_BITRATE" \
        -movflags +faststart \
        -n \
        "$temp" </dev/null >"$error_log" 2>&1
    local exit_code=$?

    rm -f "${temp}.progress"

    if [[ $exit_code -ne 0 ]]; then
        rm -f "$temp" "$error_log"
        echo "fail $orig_size 0" > "$result_file"
        return 1
    fi

    rm -f "$error_log"
    mv "$temp" "$output"

    local new_size
    new_size=$(file_size "$output")
    echo "ok $orig_size $new_size" > "$result_file"

    if $REPLACE; then
        rm "$input"
    fi

    echo "$(basename "$input")" >> "${OUTPUT_DIR}/.done"
}

main() {
    parse_args "$@"

    # Preflight checks
    if ! command -v ffmpeg &>/dev/null; then
        echo "Error: ffmpeg is not installed." >&2
        echo "Install with: brew install ffmpeg" >&2
        exit 1
    fi
    if ! command -v ffprobe &>/dev/null; then
        echo "Error: ffprobe is not installed." >&2
        echo "Install with: brew install ffmpeg" >&2
        exit 1
    fi

    # Determine which files to process
    local files=()
    if [[ ${#INPUT_FILES[@]} -gt 0 ]]; then
        for f in "${INPUT_FILES[@]}"; do
            if [[ ! -f "$f" ]]; then
                echo "Error: file not found: $f" >&2
                exit 1
            fi
            files+=("$f")
        done
    else
        for f in *.mp4 *.mov *.avi *.mkv *.MOV *.MP4 *.AVI *.MKV; do
            [[ -f "$f" ]] || continue
            [[ "$f" == *.tmp.mp4 ]] && continue
            files+=("$f")
        done
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No video files (.mp4, .mov, .avi, .mkv) found in the current directory.${NC}"
        exit 0
    fi

    TOTAL_FILES=${#files[@]}

    # Prepare output directory
    mkdir -p "$OUTPUT_DIR"

    # Clean up leftover temp files from interrupted runs
    local cleaned=0
    for tmp in "${OUTPUT_DIR}"/*.tmp.mp4; do
        [[ -f "$tmp" ]] || continue
        rm -f "$tmp"
        cleaned=$((cleaned + 1))
    done
    [[ $cleaned -gt 0 ]] && echo -e "${DIM}  Cleaned up ${cleaned} incomplete file(s) from previous run${NC}\n"

    # Ensure done-log exists
    local done_file="${OUTPUT_DIR}/.done"
    touch "$done_file"

    print_header
    echo -e "  Found ${BOLD}${TOTAL_FILES}${NC} video file(s)"

    START_TIME=$(date +%s)

    local index=0

    if [[ $JOBS -gt 1 ]] && ! $DRY_RUN; then
        # --- Parallel mode with progress bars ---
        local results_dir="${OUTPUT_DIR}/.results"
        rm -rf "$results_dir"
        mkdir -p "$results_dir"

        # Build processing queue (skip already-done files)
        local -a pq_file=() pq_output=() pq_name=() pq_dur=() pq_idx=()

        for file in "${files[@]}"; do
            index=$((index + 1))
            local filename output_name
            filename=$(basename "$file")
            output_name="${filename%.*}.mp4"
            local output="${OUTPUT_DIR}/${output_name}"

            if ! $FORCE && grep -qxF "$filename" "$done_file" 2>/dev/null && [[ -f "$output" ]]; then
                echo -e "  ${CYAN}Skipped${NC} ${filename} (already converted)"
                SKIPPED=$((SKIPPED + 1))
                continue
            fi

            # Probe duration for progress calculation
            local dur_s
            dur_s=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null || echo "0")
            local total_us=0
            if [[ "$dur_s" != "0" && "$dur_s" != "?" && "$dur_s" != "N/A" ]]; then
                total_us=$(echo "scale=0; ${dur_s} * 1000000 / 1" | bc)
            fi

            pq_file+=("$file")
            pq_output+=("$output")
            pq_name+=("$filename")
            pq_dur+=("$total_us")
            pq_idx+=("$index")
        done

        local pq_len=${#pq_file[@]}

        if [[ $pq_len -gt 0 ]]; then
            # Slot state arrays (indexed by slot 0..JOBS-1)
            local -a sl_pid=() sl_name=() sl_pf=() sl_dur=() sl_start=() sl_rf=() sl_done=()
            for ((s=0; s<JOBS; s++)); do
                sl_pid[$s]=""
                sl_name[$s]=""
                sl_pf[$s]=""
                sl_dur[$s]=0
                sl_start[$s]=0
                sl_rf[$s]=""
                sl_done[$s]=""
            done

            local pq_pos=0 active=0

            # Reserve lines for progress bars + overall status
            local bar_lines=$((JOBS + 1))
            echo ""
            for ((s=0; s<bar_lines; s++)); do echo ""; done
            BARS_ACTIVE=true

            while [[ $active -gt 0 || $pq_pos -lt $pq_len ]]; do
                # --- Check for completed jobs ---
                for ((s=0; s<JOBS; s++)); do
                    [[ -z "${sl_pid[$s]}" ]] && continue

                    if [[ -f "${sl_rf[$s]}" ]] || ! kill -0 "${sl_pid[$s]}" 2>/dev/null; then
                        wait "${sl_pid[$s]}" 2>/dev/null || true
                        active=$((active - 1))

                        local r_elapsed=$(($(date +%s) - sl_start[$s]))
                        if [[ -f "${sl_rf[$s]}" ]]; then
                            local r_status r_orig r_new
                            read -r r_status r_orig r_new < "${sl_rf[$s]}"
                            if [[ "$r_status" == "ok" ]]; then
                                PROCESSED=$((PROCESSED + 1))
                                TOTAL_ORIGINAL_SIZE=$((TOTAL_ORIGINAL_SIZE + r_orig))
                                TOTAL_COMPRESSED_SIZE=$((TOTAL_COMPRESSED_SIZE + r_new))
                                local r_pct="?"
                                local r_saved=0
                                if [[ $r_orig -gt 0 ]]; then
                                    r_pct=$(printf "%.1f" "$(echo "$r_new * 100 / $r_orig" | bc -l)")
                                    r_saved=$((r_orig - r_new))
                                fi
                                sl_done[$s]="${GREEN}Done${NC} $(format_duration $r_elapsed) — $(human_size $r_new) (${GREEN}${r_pct}%${NC}, saved ${GREEN}$(human_size $r_saved)${NC})"
                            else
                                FAILED=$((FAILED + 1))
                                sl_done[$s]="${RED}Failed${NC}"
                            fi
                        else
                            FAILED=$((FAILED + 1))
                            sl_done[$s]="${RED}Failed${NC}"
                        fi

                        sl_pid[$s]=""
                    fi
                done

                # --- Fill empty slots from queue ---
                while [[ $active -lt $JOBS && $pq_pos -lt $pq_len ]]; do
                    # Find a free slot (prefer one without a "done" message)
                    local slot=-1
                    for ((s=0; s<JOBS; s++)); do
                        if [[ -z "${sl_pid[$s]}" && -z "${sl_done[$s]}" ]]; then
                            slot=$s; break
                        fi
                    done
                    if [[ $slot -lt 0 ]]; then
                        for ((s=0; s<JOBS; s++)); do
                            [[ -z "${sl_pid[$s]}" ]] && { slot=$s; break; }
                        done
                    fi
                    [[ $slot -lt 0 ]] && break

                    ( run_conversion "${pq_file[$pq_pos]}" "${pq_output[$pq_pos]}" \
                        "${results_dir}/${pq_idx[$pq_pos]}.result" ) &

                    sl_pid[$slot]=$!
                    sl_name[$slot]="${pq_name[$pq_pos]}"
                    sl_pf[$slot]="${pq_output[$pq_pos]}.tmp.mp4.progress"
                    sl_dur[$slot]="${pq_dur[$pq_pos]}"
                    sl_start[$slot]=$(date +%s)
                    sl_rf[$slot]="${results_dir}/${pq_idx[$pq_pos]}.result"
                    sl_done[$slot]=""
                    active=$((active + 1))
                    pq_pos=$((pq_pos + 1))

                    # Update CHILD_PIDS for cleanup handler
                    CHILD_PIDS=()
                    for ((s2=0; s2<JOBS; s2++)); do
                        [[ -n "${sl_pid[$s2]}" ]] && CHILD_PIDS+=("${sl_pid[$s2]}")
                    done
                done

                # --- Draw progress bars + overall status ---
                printf "\033[${bar_lines}A"
                for ((s=0; s<JOBS; s++)); do
                    printf "\r"
                    if [[ -n "${sl_pid[$s]:-}" ]]; then
                        # Active slot — draw progress bar
                        local p_name="${sl_name[$s]}"
                        [[ ${#p_name} -gt 18 ]] && p_name="${p_name:0:15}..."
                        local pf="${sl_pf[$s]}"
                        local p_total="${sl_dur[$s]}"

                        local p_pct=0 p_spd="..." p_eta="" p_proj=""
                        if [[ -f "$pf" && $p_total -gt 0 ]]; then
                            local p_cus=0 p_sp="" p_cb=0
                            eval "$(awk -F= '
                                /^out_time_us/{us=$2}
                                /^speed/{sp=$2}
                                /^total_size/{sz=$2}
                                END{printf "p_cus=%d p_sp=\"%s\" p_cb=%d", us+0, sp, sz+0}
                            ' "$pf" 2>/dev/null)" 2>/dev/null || true
                            p_sp=${p_sp// /}

                            if [[ $p_cus -gt 0 ]]; then
                                p_pct=$((p_cus * 100 / p_total))
                                [[ $p_pct -gt 100 ]] && p_pct=100
                                p_spd="${p_sp:-?}"

                                local p_el=$(($(date +%s) - sl_start[$s]))
                                if [[ $p_pct -gt 0 && $p_el -gt 0 ]]; then
                                    local p_eta_s=$((p_el * (100 - p_pct) / p_pct))
                                    [[ $p_eta_s -gt 0 ]] && p_eta="ETA $(format_duration $p_eta_s)"
                                fi

                                if [[ $p_pct -gt 2 && $p_cb -gt 0 ]]; then
                                    p_proj="~$(human_size $((p_cb * 100 / p_pct)))"
                                fi
                            fi
                        fi

                        # Draw compact bar
                        local bw=20
                        local filled=$((p_pct * bw / 100))
                        local empty=$((bw - filled))
                        local bar=""
                        local i
                        for ((i=0; i<filled; i++)); do bar+="\xe2\x96\x88"; done
                        for ((i=0; i<empty; i++)); do bar+="\xe2\x96\x91"; done

                        printf "  ${DIM}%-18s${NC} ${bar} %3d%%  %6s  %-14s %s" \
                            "$p_name" "$p_pct" "$p_spd" "$p_eta" "$p_proj"
                    elif [[ -n "${sl_done[$s]:-}" ]]; then
                        # Completed slot — show result
                        local d_name="${sl_name[$s]}"
                        [[ ${#d_name} -gt 18 ]] && d_name="${d_name:0:15}..."
                        printf "  ${DIM}%-18s${NC} %b" "$d_name" "${sl_done[$s]}"
                    fi
                    printf "\033[K\n"
                done

                # Overall status line
                printf "\r"
                local done_count=$((PROCESSED + FAILED + SKIPPED))
                local elapsed=$(($(date +%s) - START_TIME))
                printf "  ${DIM}Overall:${NC} ${BOLD}%d${NC}/${BOLD}%d${NC} done" "$done_count" "$TOTAL_FILES"
                [[ $FAILED -gt 0 ]] && printf "  ${RED}%d failed${NC}" "$FAILED"
                [[ $elapsed -gt 0 ]] && printf "  ${DIM}(%s elapsed)${NC}" "$(format_duration $elapsed)"
                printf "\033[K\n"

                sleep 0.5
            done

            # Clear progress area
            printf "\033[${bar_lines}A"
            for ((s=0; s<bar_lines; s++)); do printf "\033[2K\n"; done
            BARS_ACTIVE=false

            CHILD_PIDS=()
            rm -rf "$results_dir"
        fi
    else
        # --- Sequential mode ---
        for file in "${files[@]}"; do
            index=$((index + 1))
            local filename output_name
            filename=$(basename "$file")
            output_name="${filename%.*}.mp4"
            local output="${OUTPUT_DIR}/${output_name}"

            echo ""
            print_separator
            echo -e "\n  ${BOLD}[${index}/${TOTAL_FILES}]${NC}"

            # Check if already converted
            if ! $FORCE && grep -qxF "$filename" "$done_file" 2>/dev/null && [[ -f "$output" ]]; then
                echo -e "  ${DIM}File:${NC}        ${filename}"
                echo -e "  ${CYAN}Skipped (already converted)${NC}"
                SKIPPED=$((SKIPPED + 1))
                continue
            fi

            if convert_file "$file" "$output"; then
                PROCESSED=$((PROCESSED + 1))
            else
                echo -e "\n  ${RED}Failed to convert: ${filename}${NC}"
                FAILED=$((FAILED + 1))
            fi
        done
    fi

    echo ""
    print_separator
    print_summary
}

main "$@"
