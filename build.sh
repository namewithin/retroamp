#!/bin/sh
set -eu
retroamp_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
retroamp_output=${RETROAMP_OUTPUT_DIR:-"$retroamp_root/dist"}
retroamp_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$retroamp_root/BundleResources/Info.plist")
retroamp_tmp=$(mktemp -d "${TMPDIR:-/tmp}/retroamp-build.XXXXXX")
trap 'rm -rf "$retroamp_tmp"' EXIT HUP INT TERM
retroamp_app="$retroamp_tmp/volume/Retroamp.app"
mkdir -p "$retroamp_app/Contents/MacOS" "$retroamp_app/Contents/Resources" "$retroamp_tmp/Sources" "$retroamp_output"
cp -X "$retroamp_root"/Sources/*.swift "$retroamp_tmp/Sources/"
cp -X "$retroamp_root/BundleResources/Info.plist" "$retroamp_app/Contents/Info.plist"
cp -X "$retroamp_root/BundleResources/Retroamp.icns" "$retroamp_app/Contents/Resources/Retroamp.icns"
cp -X "$retroamp_root/BundleResources/Webamp-MIT.txt" "$retroamp_app/Contents/Resources/Webamp-MIT.txt"
cp -X "$retroamp_root/LICENSE" "$retroamp_app/Contents/Resources/LICENSE.txt"
cp -X "$retroamp_root/NOTICE.md" "$retroamp_app/Contents/Resources/NOTICE.md"
mkdir -p "$retroamp_app/Contents/Helpers/Retroamp Source.app/Contents/MacOS"
retroamp_helper="$retroamp_app/Contents/Helpers/Retroamp Source.app"
cat > "$retroamp_helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.retroamp.stream.source</string><key>CFBundleName</key><string>Retroamp Source</string><key>CFBundleExecutable</key><string>Source</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>LSMinimumSystemVersion</key><string>14.2</string></dict></plist>
PLIST
xcrun swiftc -O -whole-module-optimization -parse-as-library -target "$(uname -m)-apple-macos14.2" "$retroamp_root/Helper/Source.swift" "$retroamp_root/Sources/StreamLifecycle.swift" "$retroamp_root/Sources/StreamFrames.swift" -o "$retroamp_helper/Contents/MacOS/Source" -framework AppKit -framework WebKit
codesign --force --sign - --timestamp=none "$retroamp_helper"
retroamp_digest=$(shasum -a 256 "$retroamp_helper/Contents/MacOS/Source" | cut -d ' ' -f 1)
printf 'let streamHelperSHA256="%s"\n' "$retroamp_digest" > "$retroamp_tmp/Sources/StreamDigest.swift"
xcrun clang -O2 -std=c11 -target "$(uname -m)-apple-macos14.2" -c "$retroamp_root/Sources/AudioRing.c" -o "$retroamp_tmp/AudioRing.o"
xcrun swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos14.2" -import-objc-header "$retroamp_root/Sources/AudioRing.h" "$retroamp_tmp"/Sources/*.swift \
  -o "$retroamp_app/Contents/MacOS/Retroamp" \
  -framework AppKit -framework WebKit -framework Security -framework CryptoKit -framework LocalAuthentication \
  -framework AVFoundation -framework Accelerate -framework MediaPlayer -framework CoreAudio "$retroamp_tmp/AudioRing.o" -lz
codesign --force --sign - --timestamp=none "$retroamp_app"
codesign --verify --strict --deep "$retroamp_app"
if [ -n "${RETROAMP_APP_DIR:-}" ]; then
  mkdir -p "$RETROAMP_APP_DIR"
  ditto --norsrc --noextattr "$retroamp_app" "$RETROAMP_APP_DIR/Retroamp.app"
fi
if [ "${RETROAMP_SKIP_DMG:-0}" = 1 ]; then exit 0; fi
ln -s /Applications "$retroamp_tmp/volume/Applications"
cp "$retroamp_root/README.md" "$retroamp_tmp/volume/README.md"
mkdir -p "$retroamp_tmp/volume/docs/images"
cp "$retroamp_root"/docs/images/*.png "$retroamp_tmp/volume/docs/images/"
cp "$retroamp_root/docs/VALIDATION.md" "$retroamp_tmp/volume/docs/VALIDATION.md"
cp "$retroamp_root/LICENSE" "$retroamp_tmp/volume/LICENSE"
cp "$retroamp_root/NOTICE.md" "$retroamp_tmp/volume/NOTICE.md"
hdiutil create -volname Retroamp -srcfolder "$retroamp_tmp/volume" -format UDZO -ov "$retroamp_output/Retroamp-$retroamp_version.dmg"
printf 'Built %s\n' "$retroamp_output/Retroamp-$retroamp_version.dmg"
