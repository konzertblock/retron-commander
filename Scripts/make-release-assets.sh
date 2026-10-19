#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
RELEASE_TAG="${RELEASE_TAG:-v$APP_VERSION}"
DOWNLOAD_PREFIX="https://github.com/konzertblock/retron-commander/releases/download/$RELEASE_TAG/"
RELEASE_DIR="$ROOT/.build/release/$APP_VERSION"
ARCHIVES_DIR="$RELEASE_DIR/archives"
APPCAST_WORK="$(mktemp -d "$RELEASE_DIR/appcast.XXXXXX")"

Scripts/package-app.sh
mkdir -p "$ARCHIVES_DIR"
ARCHIVE="$ARCHIVES_DIR/Retron-Commander-$APP_VERSION-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent ".build/Retron Commander.app" "$ARCHIVE"
"$SPARKLE_BIN/sign_update" --account retron-commander "$ARCHIVE"
cp "$ARCHIVE" "$APPCAST_WORK/"
"$SPARKLE_BIN/generate_appcast" --account retron-commander \
  --download-url-prefix "$DOWNLOAD_PREFIX" "$APPCAST_WORK"
cp "$APPCAST_WORK/appcast.xml" "$RELEASE_DIR/appcast.xml"
echo "Release assets are ready in $RELEASE_DIR"
