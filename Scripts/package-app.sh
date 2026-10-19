#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARM64_TRIPLE="arm64-apple-macosx14.0"
X86_64_TRIPLE="x86_64-apple-macosx14.0"
APP_VERSION="${APP_VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
TMP_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/retroncommander-release.XXXXXX")"
trap 'rm -rf "$TMP_BUILD"' EXIT

swift build --triple "$ARM64_TRIPLE" --scratch-path "$ROOT/.build-arm64" --configuration release
swift build --triple "$X86_64_TRIPLE" --scratch-path "$ROOT/.build-x86_64" --configuration release

ARM64_PRODUCTS="$ROOT/.build-arm64/out/Products/Release"
X86_64_PRODUCTS="$ROOT/.build-x86_64/out/Products/Release"
# Build both helper architectures from the included, version-pinned 7-Zip source.
for arch in arm64 x86_64; do
  src="$TMP_BUILD/7zip-$arch"
  mkdir -p "$src"
  tar -xJf "$ROOT/ThirdParty/7zip-26.04/7z2604-src.tar.xz" -C "$src"
  make -C "$src/CPP/7zip/Bundles/Alone2" -f makefile.gcc \
    CC=clang CXX=clang++ IS_X64=1 "MY_ARCH=-arch $arch"
  helper="$src/CPP/7zip/Bundles/Alone2/_o/7zz"
  if [[ "$("$helper" i)" != *"7-Zip (z) 26.04"* ]]; then
    echo "The $arch 7-Zip helper build is not version 26.04." >&2
    exit 1
  fi
done
ARM64_7ZIP="$TMP_BUILD/7zip-arm64/CPP/7zip/Bundles/Alone2/_o/7zz"
X86_64_7ZIP="$TMP_BUILD/7zip-x86_64/CPP/7zip/Bundles/Alone2/_o/7zz"

APP="$ROOT/.build/Retron Commander.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
lipo -create \
  "$ARM64_PRODUCTS/RetronCommander" \
  "$X86_64_PRODUCTS/RetronCommander" \
  -output "$APP/Contents/MacOS/RetronCommander"
cp -R "$ARM64_PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/RetronCommander"
cp -R "$ARM64_PRODUCTS/RetronCommander_RetronCommander.bundle" "$APP/Contents/Resources/"
lipo -create "$ARM64_7ZIP" "$X86_64_7ZIP" -output "$APP/Contents/Resources/7zz"
chmod 755 "$APP/Contents/Resources/7zz"
cp -R "$ROOT/ThirdParty/7zip-26.04" "$APP/Contents/Resources/7zip-source"
cp "$ROOT/ThirdParty/Sparkle-LICENSE.txt" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/Third-Party-Notices.md"
ICONSET="$TMP_BUILD/RetronCommander.iconset"
mkdir -p "$ICONSET"
for entry in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${entry%% *}"
  name="${entry#* }"
  sips -z "$size" "$size" "$ROOT/Assets/RetronCommander-Icon.png" --out "$ICONSET/$name" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>RetronCommander</string>
  <key>CFBundleIdentifier</key><string>com.konzertblock.RetronCommander</string>
  <key>CFBundleName</key><string>Retron Commander</string>
  <key>CFBundleDisplayName</key><string>Retron Commander</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Find SMB file servers when you open Network Neighborhood.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Display and manage files in Downloads when a file panel is opened there.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Display and manage files in Documents when a file panel is opened there.</string>
  <key>NSDesktopFolderUsageDescription</key><string>Display and manage files on the Desktop when a file panel is opened there.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Display and manage files on removable drives shown in the file panels.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Display and manage files on network volumes opened in the file panels.</string>
  <key>NSBonjourServices</key><array><string>_smb._tcp</string></array>
</dict>
</plist>
PLIST
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://github.com/konzertblock/retron-commander/releases/latest/download/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-shGleniRlAxwMP7QMDL9iEWgXQJaVFiV6A5LiusfLB4=}"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Created $APP"
