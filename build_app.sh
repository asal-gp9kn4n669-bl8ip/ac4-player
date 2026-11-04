#!/usr/bin/env bash
# Builds AC4 Player.app (native macOS 14+ Apple Silicon SwiftUI player for AC-4 IMS via LibreMPEG).
#
# Modes:
#   1. Personal In-Process LibreMPEG build (default when ./librempeg static .a libraries exist):
#        ./build_app.sh [--librempeg /path/to/librempeg] [--zip]
#      Statically links libavformat.a + libavcodec.a + libswresample.a + libavutil.a directly into
#      AC4Player for native 32-bit float AC-4 IMS decoding in RAM with zero child processes.
#
#   2. Shareable / MIT-clean build (NO bundled third-party codec libraries or binaries):
#        ./build_app.sh --shareable [--zip]
#
#   3. Personal external binary bundle (embeds a LibreMPEG 'ffmpeg' CLI inside Contents/Resources/bin):
#        ./build_app.sh --bundle /path/to/librempeg/ffmpeg [--zip]
#
# NOTE: Do NOT redistribute in-process LibreMPEG or --bundle builds publicly (GPL / AC-4 patent terms).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/AC4 Player.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
VERSION="1.1.0"
export MACOSX_DEPLOYMENT_TARGET=14.0

BUNDLE_BIN=""
LIBREMPEG_DIR=""
FORCE_SHAREABLE=0
MAKE_ZIP=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --librempeg)
            if [[ $# -lt 2 ]]; then
                echo "Error: --librempeg requires a path to your built LibreMPEG source directory." >&2
                exit 1
            fi
            LIBREMPEG_DIR="$2"
            shift 2
            ;;
        --librempeg=*)
            LIBREMPEG_DIR="${1#*=}"
            shift
            ;;
        --shareable)
            FORCE_SHAREABLE=1
            shift
            ;;
        --bundle)
            if [[ $# -lt 2 ]]; then
                echo "Error: --bundle requires a path to your LibreMPEG 'ffmpeg' executable." >&2
                exit 1
            fi
            BUNDLE_BIN="$2"
            shift 2
            ;;
        --bundle=*)
            BUNDLE_BIN="${1#*=}"
            shift
            ;;
        --zip)
            MAKE_ZIP=1
            shift
            ;;
        -h|--help)
            sed -n '2,16p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AC4Player</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.antigravity.ac4player</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AC4 Player</string>
    <key>CFBundleDisplayName</key>
    <string>AC4 Player</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Generate AppIcon.icns if not already present (uses built-in macOS python3 + sips + iconutil)
if [[ ! -f "$RESOURCES_DIR/AppIcon.icns" ]] && [[ -x /usr/bin/python3 ]]; then
    echo "==> Generating AppIcon.icns..."
    TMP_ICON_DIR="$(mktemp -d)"
    ICONSET_DIR="$TMP_ICON_DIR/AppIcon.iconset"
    MASTER_PNG="$TMP_ICON_DIR/master.png"
    mkdir -p "$ICONSET_DIR"
    /usr/bin/python3 - "$MASTER_PNG" <<'PYEOF'
import math, struct, sys, zlib

out_path = sys.argv[1]
N = 512
rows = []
bars = [0.18, 0.34, 0.50, 0.38, 0.56, 0.32, 0.20]
bw = N * 0.056
gap = N * 0.032
tot_w = len(bars) * bw + (len(bars) - 1) * gap
bx0 = (N - tot_w) / 2.0
inset = N * 0.06
rad = N * 0.22
cx = cy = N * 0.5

def inside_rrect(x, y, x0, y0, w, h, r):
    dx = max(x0 + r - x, 0.0, x - (x0 + w - r))
    dy = max(y0 + r - y, 0.0, y - (y0 + h - r))
    return dx * dx + dy * dy <= r * r

for y in range(N):
    row = bytearray([0])
    ty = y / (N - 1)
    for x in range(N):
        if not inside_rrect(x + 0.5, y + 0.5, inset, inset, N - 2 * inset, N - 2 * inset, rad):
            row += b"\x00\x00\x00\x00"
            continue
        tx = x / (N - 1)
        t = 0.55 * tx + 0.45 * ty
        r = int(34 + 58 * (1 - abs(t - 0.5) * 1.4) + 10 * tx)
        g = int(20 + 72 * t)
        b = int(78 + 115 * (0.4 + 0.6 * t))
        dist = math.hypot(x + 0.5 - cx, y + 0.5 - cy) / N
        for ring_r in (0.28, 0.37):
            if abs(dist - ring_r) < 0.009:
                r = min(255, int(r * 0.72 + 210 * 0.28))
                g = min(255, int(g * 0.72 + 185 * 0.28))
                b = min(255, int(b * 0.72 + 255 * 0.28))
        rel_x = (x + 0.5) - bx0
        if 0 <= rel_x <= tot_w:
            slot = int(rel_x // (bw + gap))
            if 0 <= slot < len(bars):
                sx = bx0 + slot * (bw + gap)
                bh = N * bars[slot]
                sy = (N - bh) / 2.0
                if sx <= x + 0.5 <= sx + bw and sy <= y + 0.5 <= sy + bh:
                    if inside_rrect(x + 0.5, y + 0.5, sx, sy, bw, bh, bw * 0.5):
                        r, g, b = 246, 242, 255
        row += bytes((max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)), 255))
    rows.append(bytes(row))

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

raw = b"".join(rows)
png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 6, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(raw, 6))
    + chunk(b"IEND", b"")
)
with open(out_path, "wb") as f:
    f.write(png)
PYEOF
    for entry in \
        "16:icon_16x16.png" "32:icon_16x16@2x.png" \
        "32:icon_32x32.png" "64:icon_32x32@2x.png" \
        "128:icon_128x128.png" "256:icon_128x128@2x.png" \
        "256:icon_256x256.png" "512:icon_256x256@2x.png" \
        "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
        px="${entry%%:*}"
        fname="${entry#*:}"
        /usr/bin/sips -s format png -z "$px" "$px" "$MASTER_PNG" --out "$ICONSET_DIR/$fname" >/dev/null 2>&1
    done
    /usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns" || true
    rm -rf "$TMP_ICON_DIR"
fi

# Resolve build mode: In-Process Static LibreMPEG vs Bundled CLI vs Shareable MIT-clean
USE_NATIVE_LIBREMPEG=0
if [[ "$FORCE_SHAREABLE" -eq 0 ]] && [[ -z "$BUNDLE_BIN" ]]; then
    if [[ -z "$LIBREMPEG_DIR" ]] && [[ -d "$SCRIPT_DIR/librempeg" ]]; then
        LIBREMPEG_DIR="$SCRIPT_DIR/librempeg"
    fi
    if [[ -n "$LIBREMPEG_DIR" ]]; then
        LIBREMPEG_DIR="$(cd "$LIBREMPEG_DIR" && pwd)"
        if [[ -f "$LIBREMPEG_DIR/libavformat/libavformat.a" ]] && \
           [[ -f "$LIBREMPEG_DIR/libavcodec/libavcodec.a" ]] && \
           [[ -f "$LIBREMPEG_DIR/libswresample/libswresample.a" ]] && \
           [[ -f "$LIBREMPEG_DIR/libavutil/libavutil.a" ]]; then
            USE_NATIVE_LIBREMPEG=1
        else
            echo "Warning: Complete static archives (.a) not found in $LIBREMPEG_DIR; building without in-process decoder." >&2
        fi
    fi
fi

rm -rf "$RESOURCES_DIR/bin"
if [[ "$USE_NATIVE_LIBREMPEG" -eq 1 ]]; then
    echo "==> [PERSONAL IN-PROCESS BUILD] Statically linking LibreMPEG from: $LIBREMPEG_DIR"
    echo "    Native 32-bit float AC-4 IMS decoder linked directly into AC4Player (zero child processes)."
    echo "    NOTE: Keep this build for personal use (LibreMPEG GPL / AC-4 patent terms)."
elif [[ -n "$BUNDLE_BIN" ]]; then
    if [[ ! -f "$BUNDLE_BIN" ]]; then
        echo "Error: LibreMPEG binary not found at: $BUNDLE_BIN" >&2
        exit 1
    fi
    echo "==> [PERSONAL BUNDLED BUILD] Bundling LibreMPEG binary from: $BUNDLE_BIN"
    mkdir -p "$RESOURCES_DIR/bin"
    cp "$BUNDLE_BIN" "$RESOURCES_DIR/bin/ffmpeg"
    chmod +x "$RESOURCES_DIR/bin/ffmpeg"
    echo "    WARNING: This build embeds a third-party decoder binary. Keep for personal use only."
else
    echo "==> [SHAREABLE BUILD] Building MIT-clean app bundle (no third-party codec libraries or binaries)."
fi

TMP_BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_BUILD_DIR"' EXIT

BRIDGE_OBJ="$TMP_BUILD_DIR/AC4Bridge.o"
EXTRA_LINK_ARGS=()
TARGET_TRIPLE="arm64-apple-macos14.0"

if [[ "$USE_NATIVE_LIBREMPEG" -eq 1 ]]; then
    echo "==> Compiling C bridge (AC4Bridge.c) against LibreMPEG headers..."
    /usr/bin/clang \
        -O3 \
        -Wall -Wextra \
        -target "$TARGET_TRIPLE" \
        -DAC4_ENABLE_NATIVE_LIBREMPEG=1 \
        -I"$LIBREMPEG_DIR" \
        -c "$SCRIPT_DIR/AC4Bridge.c" \
        -o "$BRIDGE_OBJ"

    EXTRA_LINK_ARGS=(
        "$LIBREMPEG_DIR/libavformat/libavformat.a"
        "$LIBREMPEG_DIR/libavcodec/libavcodec.a"
        "$LIBREMPEG_DIR/libswresample/libswresample.a"
        "$LIBREMPEG_DIR/libavutil/libavutil.a"
        -lz
        -liconv
        -lbz2
        -framework CoreMedia
        -framework CoreVideo
        -framework AudioToolbox
        -framework VideoToolbox
        -framework Security
        -Xlinker -dead_strip
        -Xlinker -dead_strip_dylibs
        -Xlinker -w
    )
else
    echo "==> Compiling C bridge stub (AC4Bridge.c)..."
    /usr/bin/clang \
        -O3 \
        -Wall -Wextra \
        -target "$TARGET_TRIPLE" \
        -DAC4_ENABLE_NATIVE_LIBREMPEG=0 \
        -c "$SCRIPT_DIR/AC4Bridge.c" \
        -o "$BRIDGE_OBJ"

    EXTRA_LINK_ARGS=(
        -Xlinker -dead_strip
    )
fi

echo "==> Compiling AC4 Player.app..."
/usr/bin/swiftc \
    -O \
    -target "$TARGET_TRIPLE" \
    -parse-as-library \
    -import-objc-header "$SCRIPT_DIR/AC4Bridge.h" \
    -module-cache-path /tmp/swift-module-cache \
    -framework SwiftUI \
    -framework AppKit \
    -framework AVFoundation \
    -framework MediaPlayer \
    -framework UniformTypeIdentifiers \
    "$SCRIPT_DIR/AC4PlayerApp.swift" \
    "$BRIDGE_OBJ" \
    "${EXTRA_LINK_ARGS[@]}" \
    -o "$MACOS_DIR/AC4Player"

chmod +x "$MACOS_DIR/AC4Player"

if [[ -n "${CODESIGN_IDENTITY:-}" ]] && [[ -x /usr/bin/codesign ]]; then
    echo "==> Signing app bundle (${CODESIGN_IDENTITY})..."
    /usr/bin/codesign --force --sign "$CODESIGN_IDENTITY" "$APP_DIR"
fi

touch "$APP_DIR"
echo "Successfully built: $APP_DIR"
du -sh "$APP_DIR"

if [[ "$MAKE_ZIP" -eq 1 ]]; then
    if [[ "$USE_NATIVE_LIBREMPEG" -eq 1 ]] || [[ -n "$BUNDLE_BIN" ]]; then
        ZIP_PATH="$SCRIPT_DIR/AC4-Player-v${VERSION}-PERSONAL-BUNDLED-macOS-arm64.zip"
    else
        ZIP_PATH="$SCRIPT_DIR/AC4-Player-v${VERSION}-macOS-arm64.zip"
    fi
    echo "==> Creating archive: $ZIP_PATH"
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
    du -sh "$ZIP_PATH"
fi
