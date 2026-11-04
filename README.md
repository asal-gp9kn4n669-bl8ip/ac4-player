# AC4 Player

A lightweight native **macOS (SwiftUI + Core Audio)** music player for playing **Dolby AC-4 IMS** (`.m4a`, `.mp4`, `.ac4`, `.mka`, `.mkv`) and standard audio files (`.flac`, `.wav`, `.opus`, `.mp3`) **directly in RAM** via [**LibreMPEG**](https://github.com/librempeg/librempeg).

---

## How It Works

1. **Three-Tier Native RAM Audio Engine**:
   - **Tier 1 — In-Process LibreMPEG (`AC4Bridge.c`)**: When built alongside `./librempeg`, links `libavformat.a`, `libavcodec.a`, `libswresample.a`, and `libavutil.a` directly into `AC4Player` to decode AC-4 IMS (`AV_SAMPLE_FMT_FLTP`) in memory at full **48 kHz 32-bit float** precision with zero child processes and exact preroll-trimmed seeking. Also parses raw `.ac4` syncframes (`0xAC40` / `0xAC41`) even on minimal builds without `CONFIG_AC4_DEMUXER`.
   - **Tier 2 — Native Core Audio (`AVAudioFile` + `AVAudioConverter`)**: Decodes standard audio formats (`.flac`, `.wav`, `.mp3`, `.aiff`, AAC/ALAC `.m4a`) directly via macOS Core Audio, even when paired with minimal AC-4-only LibreMPEG builds.
   - **Tier 3 — External LibreMPEG / FFmpeg Subprocess (`stdout` or POSIX `mkfifo`)**: Streams decoded audio from an external `ffmpeg` / `librempeg` binary into the bounded 20-second (~7.7 MB) ring buffer feeding `AVAudioSourceNode`, automatically falling back to a private `0700` POSIX FIFO when the binary was compiled with `--enable-protocol=file` only (without `pipe`).
2. **Instant Native MP4 / `ac-4` Tag & Artwork Scanner**: Reads ISOBMFF (`moov` / `stsd` / `ilst` / `covr`) metadata, track/disc numbers, durations, `ac-4` stream indices, and embedded or folder `cover.jpg` artwork natively in Swift before playback even starts.
3. **Streamlined macOS Player Experience**: Single-pane instant launch, frame-accurate scrubbing seekbar, **0 dB to +6 dB pre-amp** (with one-click `+6.0 dB` boost for quiet AC-4 IMS headroom and soft-ceiling protection), live post-preamp stereo L/R dBFS meters, shuffle & repeat, and macOS Control Center / keyboard media keys / AirPods controls (`MPNowPlayingInfoCenter`).

> **Headphone Tip for AC-4 IMS**: Dolby AC-4 IMS tracks are already pre-rendered with binaural HRTF virtualization for headphones. Keep macOS / AirPods **Spatial Audio set to Off** while listening so Apple does not double-virtualize the binaural soundstage.

---

## Build Modes (Licensing)

Because **LibreMPEG** is licensed under LGPL/GPL and **Dolby AC-4** carries codec patent considerations, `build_app.sh` cleanly separates **personal** builds from **shareable** MIT-only builds:

### 1. Personal In-Process LibreMPEG Build (Auto-detected when `./librempeg` is present)
```bash
./build_app.sh
# or specify another LibreMPEG build tree:
./build_app.sh --librempeg /path/to/librempeg
```
- Statically links `libavformat.a`, `libavcodec.a`, `libswresample.a`, and `libavutil.a` directly into **`AC4 Player.app`** (~2.9 MB) for native 32-bit float AC-4 IMS playback with zero external `ffmpeg` subprocesses.

### 2. Shareable Build (MIT-Clean — Safe to Publish / Distribute)
```bash
./build_app.sh --shareable --zip
```
- Produces **`AC4 Player.app`** (~1.3 MB) and **`AC4-Player-v1.1.0-macOS-arm64.zip`** containing **only** MIT-licensed code and **zero** third-party codec libraries or binaries.
- Users can click **Locate LibreMPEG…** in the toolbar (or `⌘,`) to select their own `librempeg` / `ffmpeg` executable, or place it in `./librempeg/ffmpeg`, `~/Library/Application Support/AC4Player/bin/ffmpeg`, or `/usr/local/bin/librempeg`.

### 3. Personal External CLI Bundle Build
```bash
./build_app.sh --bundle /path/to/your/librempeg/ffmpeg --zip
```
- Embeds your local LibreMPEG `ffmpeg` executable inside `AC4 Player.app/Contents/Resources/bin/ffmpeg` and names the archive **`AC4-Player-v1.1.0-PERSONAL-BUNDLED-macOS-arm64.zip`**.

---

## Requirements

- **macOS 14.0 (Sonoma)** or later on Apple Silicon (`arm64`)
- **LibreMPEG** `ffmpeg` executable (compiled with `ac4` decoder enabled) for AC-4 IMS playback
- **Xcode Command Line Tools** (`xcode-select --install`) if building from source

## License

The **AC4 Player** source code in this repository is released under the [MIT License](LICENSE). LibreMPEG is a separate project licensed under LGPL/GPL by its respective authors and is **not** distributed in shareable builds of this project.

