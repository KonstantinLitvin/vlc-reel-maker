#!/usr/bin/env bash
set -euo pipefail

# Installer script for VLC Scene Marker extension
# Installs to Snap VLC and native system VLC extension directories

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_FILE="${REPO_ROOT}/src/scene-marker.lua"

if [ ! -f "${SOURCE_FILE}" ]; then
    echo "❌ Error: Source file not found at ${SOURCE_FILE}"
    exit 1
fi

DEST_DIRS=(
    "${HOME}/snap/vlc/current/.local/share/vlc/lua/extensions"
    "${HOME}/.local/share/vlc/lua/extensions"
)

echo "=================================================="
echo "Installing VLC Scene Marker Extension"
echo "=================================================="

installed_count=0

for dest_dir in "${DEST_DIRS[@]}"; do
    # Check if parent vlc directory exists or if snap/native VLC is present
    parent_dir="$(dirname "${dest_dir}")"
    if [ -d "${parent_dir}" ] || [[ "${dest_dir}" == *"/snap/vlc/"* && -d "${HOME}/snap/vlc" ]]; then
        mkdir -p "${dest_dir}"
        cp -f "${SOURCE_FILE}" "${dest_dir}/scene-marker.lua"
        echo "✅ Installed to: ${dest_dir}/scene-marker.lua"
        installed_count=$((installed_count + 1))
    fi
done

if [ ${installed_count} -eq 0 ]; then
    # Fallback to standard local share
    mkdir -p "${HOME}/.local/share/vlc/lua/extensions"
    cp -f "${SOURCE_FILE}" "${HOME}/.local/share/vlc/lua/extensions/scene-marker.lua"
    echo "✅ Created default directory and installed to: ${HOME}/.local/share/vlc/lua/extensions/scene-marker.lua"
fi

echo "=================================================="
echo "Installation complete!"
echo "Restart VLC, then open: View -> Scene Marker"
echo "=================================================="
