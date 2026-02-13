# compress-mp4

Batch compress MP4 files using H.265/HEVC encoding. Built for archiving YouTube video backups after upload — shrink your local copies significantly while keeping good visual quality.

In testing, a 1 GB 4K video compressed down to **74 MB** (7.4% of original) with default settings — and still looked great.

## Features

- **H.265/HEVC encoding** with 4K to 1080p downscaling — up to 95% size reduction
- **Resumable** — stop anytime with Ctrl+C, run again to pick up where you left off
- **Progress bar** — shows percentage, encoding speed, ETA, and projected file size
- **Safe by default** — writes to a `converted/` subdirectory, originals untouched
- **Dry run with estimates** — preview what would happen and estimated space savings
- **Tunable** — adjust quality, speed, resolution, and audio bitrate via flags
- **Single file or batch** — pass specific files or process the whole directory

## Requirements

- **ffmpeg** with libx265 support
- **macOS** or **Linux**

Install ffmpeg on macOS:

```bash
brew install ffmpeg
```

## Quick Start

1. Copy `compress.sh` into a directory full of `.mp4` files
2. Make it executable: `chmod +x compress.sh`
3. Run it:

```bash
./compress.sh
```

Compressed files appear in `./converted/`. Originals are not modified.

### What the defaults do

| Setting | Default | Effect |
|---------|---------|--------|
| Codec | H.265 (HEVC) | Modern codec with much better compression than H.264 |
| CRF | 24 | Good quality — hard to distinguish from the original (see [CRF](#crf---crf)) |
| Preset | medium | Balanced encoding speed vs quality (see [Presets](#presets---preset)) |
| Max width | 1920px | 4K videos downscaled to 1080p; 1080p and smaller untouched |
| Audio | AAC @ 128k | Re-encoded audio, good quality for speech and music |
| Output | `./converted/` | Originals are never modified |

With these defaults, expect roughly:
- **4K source** → ~7% of original size (93% reduction)
- **1080p source** → ~25-35% of original size (codec change only, no downscaling)

## Usage

```
./compress.sh [OPTIONS] [FILE ...]
```

If no files are given, all `.mp4` files in the current directory are processed. If one or more files are given, only those are processed.

### Options

| Flag | Default | Description |
|------|---------|-------------|
| `-c, --crf <N>` | `24` | Quality level (0–51). Lower = better quality, larger files. |
| `-p, --preset <NAME>` | `medium` | Encoding speed vs quality tradeoff. |
| `-w, --max-width <N>` | `1920` | Cap output width in pixels. Use `0` to keep original resolution. |
| `-o, --output-dir <DIR>` | `converted` | Where compressed files are written. |
| `-a, --audio-bitrate <RATE>` | `128k` | Audio bitrate for AAC encoding. |
| `--replace` | off | Delete the original file after successful conversion. |
| `--force` | off | Re-convert all files, even if previously completed. |
| `--dry-run` | off | Show what would happen without converting. Includes estimated sizes. |
| `-h, --help` | | Show help. |
| `-v, --version` | | Show version. |

## Understanding the Settings

The two main knobs are **CRF** (quality) and **preset** (speed). Here's how they interact, based on real testing.

### CRF (`--crf`)

CRF (Constant Rate Factor) is the main quality control. It tells the encoder: "target this perceptual quality level, and use whatever bitrate is needed."

- **Lower CRF** = higher quality, larger files
- **Higher CRF** = lower quality, smaller files
- The scale is 0–51, where 0 is lossless and 51 is the worst possible quality
- Each +4 CRF roughly **halves** the file size

The "right" CRF depends on your content. Videos with lots of fine detail, fast motion, or grain need a lower CRF. Talking-head or screencast content compresses very well and tolerates a higher CRF.

**Benchmarks** (same 4K source, `--preset medium`, downscaled to 1080p):

| CRF | Output Size | % of Original | Encode Time | What you'll notice |
|-----|-------------|---------------|-------------|-------------------|
| 20 | 145 MB | 14.5% | 3m 42s | Excellent — only noticeable in A/B comparisons. Good if you might re-edit later. |
| **24** | **74 MB** | **7.4%** | **2m 44s** | **Default. Hard to tell from the original. Best tradeoff for backups.** |
| 28 | 37 MB | 3.7% | 2m 19s | Some softening on detailed scenes. Good for "just in case" backups. |
| 32 | 20 MB | 2.0% | 2m 03s | Visible quality loss. Only for aggressive space saving. |

**How to choose:**

- **"I might re-edit these"**: CRF 20 — preserves quality for future editing
- **"Good backup"**: CRF 24 (default) — you'd have to look carefully to spot differences
- **"Saving space matters most"**: CRF 28 — half the size of CRF 24, still decent quality
- **"How small can I go?"**: CRF 32 — 50x compression from a 4K original, but you'll see it

### Presets (`--preset`)

The preset controls how much CPU time the encoder spends analyzing each frame. With H.265 (x265), **this works differently than you might expect:**

- **Faster presets** = faster encoding, **smaller files**, but **lower quality**
- **Slower presets** = slower encoding, **larger files**, but **higher quality**

This is counterintuitive and different from H.264. The reason: slower x265 presets enable more sophisticated quality analysis tools (adaptive quantization, SAO, RDOQ, more reference frames). The encoder "sees" more detail and spends more bits preserving it. Faster presets miss some detail, so they use fewer bits — producing smaller but slightly lower quality output.

**Benchmarks** (same 4K source, CRF 24, downscaled to 1080p):

| Preset | Output Size | % of Original | Encode Time |
|--------|-------------|---------------|-------------|
| `ultrafast` | 59 MB | 5.9% | 1m 05s |
| `veryfast` | 67 MB | 6.7% | 1m 44s |
| `fast` | 67 MB | 6.7% | 2m 46s |
| **`medium`** | **74 MB** | **7.4%** | **2m 44s** |
| `slow` | 88 MB | 8.8% | 9m 10s |
| `slower` | — | — | ~38m* |

> \* `slower` was cancelled after 10 minutes at 28% complete (0.08x speed). Not practical for most use cases.

Available presets (fastest to slowest): `ultrafast`, `superfast`, `veryfast`, `faster`, `fast`, `medium`, `slow`, `slower`, `veryslow`, `placebo`.

**How to choose:**

- **Maximum space savings**: `fast` or `ultrafast` — smallest files, fastest encoding. Quality is still very good for backups.
- **Balanced (default)**: `medium` — slightly higher quality than `fast` at a similar speed.
- **Maximum quality**: `slow` — preserves the most detail but produces larger files and takes 3-4x longer.

**Key insight:** If your primary goal is saving disk space, slower presets are counterproductive — they produce larger files. Use `fast` or `medium` and adjust CRF to control the size/quality tradeoff.

### Test setup

All benchmarks in this document used the same source and hardware:

- **Source:** 953 MB 4K (3840x2160) H.264 video, 2 minutes 39 seconds
- **Hardware:** MacBook Air, Apple M3 (4 performance + 4 efficiency cores), 24 GB RAM
- **Encoding is CPU-bound** — RAM and storage speed have minimal impact. A desktop CPU with more cores (M3 Pro/Max, Intel i9, Ryzen 9) will encode significantly faster.

Results vary with content. Use `--dry-run` to get estimates for your specific files.

## Examples

```bash
# Preview what would happen (with space saving estimates)
./compress.sh --dry-run

# Try a single file first
./compress.sh my_video.mp4

# Default: CRF 24, medium preset, 4K → 1080p
./compress.sh

# Compare different CRF values on one file
./compress.sh --crf 20 --force my_video.mp4
./compress.sh --crf 28 --force my_video.mp4

# Keep original resolution (no downscaling)
./compress.sh --max-width 0

# Maximum compression: lower CRF + fast preset
./compress.sh --crf 28 --preset fast

# Delete originals after successful conversion
./compress.sh --replace

# Custom output directory
./compress.sh --output-dir ~/Archives/compressed
```

## Finding Your Sweet Spot

1. **Dry run** — see what will be processed and estimated savings:
   ```bash
   ./compress.sh --dry-run
   ```
   Try different flags to compare estimates:
   ```bash
   ./compress.sh --dry-run --crf 28
   ./compress.sh --dry-run --crf 20 --max-width 0
   ```

2. **Test one file** — pick a representative video and try a few CRF values:
   ```bash
   ./compress.sh --crf 24 my_video.mp4
   ./compress.sh --crf 28 --force my_video.mp4
   ```

3. **Compare quality** — open the original and converted version side by side. Check scenes with fast motion, fine detail, or gradients.

4. **Batch run** — once you've found settings you like:
   ```bash
   ./compress.sh --crf 24
   ```
   You can stop anytime with Ctrl+C and resume later. The script picks up where it left off.

## How Resume Works

The script tracks completed files in `converted/.done`. When you run it again:

- Files listed in `.done` that exist in the output directory are **skipped**
- Partially converted files (from an interrupted run) are automatically **deleted and re-started**
- Use `--force` to **re-convert everything**, ignoring the completion log
- To start completely fresh, delete the `converted/` directory

## Notes

- Only processes `.mp4` files in the **current directory** (not subdirectories)
- You can also pass specific files as arguments: `./compress.sh video1.mp4 video2.mp4`
- Output uses `-tag:v hvc1` for Apple/QuickTime compatibility
- Output uses `-movflags +faststart` for better streaming/playback
- Audio is re-encoded to AAC regardless of the original codec
- Videos narrower than `--max-width` are not upscaled
- File sizes are shown in decimal units (MB/GB) to match macOS Finder
