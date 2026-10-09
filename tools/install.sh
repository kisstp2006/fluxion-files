#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Install Files beside Fluxion Desktop: built as you, as a release build,
# then copied into place as root - the one step that needs it.
#
#   tools/install.sh                    into /usr/local
#   PREFIX=/opt/fluxion tools/install.sh
#   tools/install.sh --uninstall
set -eu
prefix=${PREFIX:-/usr/local}
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--uninstall" ]; then
    sudo rm -f "$prefix/bin/fluxion-files" "$prefix/share/applications/org.fluxion.Files.desktop"
    echo "Files is uninstalled."
    exit 0
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
zig build -Doptimize=ReleaseSafe --prefix "$stage"

sudo install -Dm755 "$stage/bin/fluxion-files" "$prefix/bin/fluxion-files"
sudo install -Dm644 "$stage/share/applications/org.fluxion.Files.desktop" "$prefix/share/applications/org.fluxion.Files.desktop"
# Folders open in Files in a Fluxion session - in the apps that ask the
# system which app opens one too - and in no other desktop: the list read
# for XDG_CURRENT_DESKTOP=Fluxion alone.
list="${XDG_CONFIG_HOME:-$HOME/.config}/fluxion-mimeapps.list"
if ! grep -q '^inode/directory=' "$list" 2>/dev/null; then
    mkdir -p "$(dirname "$list")"
    grep -q '^\[Default Applications\]' "$list" 2>/dev/null || printf '[Default Applications]\n' >> "$list"
    sed -i '/^\[Default Applications\]/a inode/directory=org.fluxion.Files.desktop' "$list"
fi
echo "Files is installed: Super+E and the desktop's folders open it."
