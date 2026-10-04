#!/usr/bin/env bash
set -euo pipefail

# Download static FFmpeg binary into Snap VLC common directory
# This allows VLC (running inside the Ubuntu Snap container) to execute FFmpeg directly

TARGET_DIR="${HOME}/snap/vlc/common/bin"
TARGET_BIN="${TARGET_DIR}/ffmpeg"

echo "=================================================="
echo "Installing static FFmpeg into Snap VLC environment"
echo "Target: ${TARGET_DIR}"
echo "=================================================="

mkdir -p "${TARGET_DIR}"

if [ -f "${TARGET_BIN}" ]; then
    echo "FFmpeg binary already exists at ${TARGET_BIN}"
    "${TARGET_BIN}" -version | head -n 1
    exit 0
fi

echo "Downloading static FFmpeg build (amd64)..."
curl -sL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz | \
    tar -xJ --strip-components=1 -C "${TARGET_DIR}" --wildcards '*/ffmpeg'

chmod +x "${TARGET_BIN}"

echo "=================================================="
echo "Verification:"
"${TARGET_BIN}" -version | head -n 1
echo "=================================================="
echo "✅ Static FFmpeg successfully installed for VLC Snap!"
