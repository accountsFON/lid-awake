#!/bin/sh
# Installs or updates Lid Awake.
#   curl -fsSL https://raw.githubusercontent.com/accountsFON/lid-awake/main/scripts/install.sh | sh
# Uses a local LidAwake.zip when one sits next to this script or in ../dist
# (local builds and team copies); otherwise downloads the latest GitHub release.
set -e
REPO="accountsFON/lid-awake"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -f "$HERE/LidAwake.zip" ]; then
  ZIP="$HERE/LidAwake.zip"
elif [ -f "$HERE/../dist/LidAwake.zip" ]; then
  ZIP="$HERE/../dist/LidAwake.zip"
else
  echo "Downloading the latest Lid Awake release..."
  curl -fsSL "https://github.com/$REPO/releases/latest/download/LidAwake.zip" -o "$TMP/LidAwake.zip"
  ZIP="$TMP/LidAwake.zip"
fi

DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

# Quitting a running copy also turns normal sleep back on.
pkill -x LidAwake 2>/dev/null && sleep 2 || true
rm -rf "$DEST/Lid Awake.app"
[ "$DEST" = "/Applications" ] && rm -rf "$HOME/Applications/Lid Awake.app"

ditto -x -k "$ZIP" "$DEST"
# The app is ad hoc signed (not notarized), so clear the download quarantine flag.
xattr -dr com.apple.quarantine "$DEST/Lid Awake.app" 2>/dev/null || true
open "$DEST/Lid Awake.app"
echo "Installed $DEST/Lid Awake.app. Look for the moon icon in your menu bar."
