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
xcrun swiftc -target "$(uname -m)-apple-macos14.0" "$retroamp_tmp"/Sources/*.swift \
  -o "$retroamp_app/Contents/MacOS/Retroamp" \
  -framework AppKit -framework WebKit -framework Security -framework CryptoKit -framework LocalAuthentication \
  -framework AVFoundation -framework Accelerate -lz
codesign --force --sign - --timestamp=none "$retroamp_app"
codesign --verify --strict "$retroamp_app"
ln -s /Applications "$retroamp_tmp/volume/Applications"
cp "$retroamp_root/README.md" "$retroamp_tmp/volume/README.md"
cp "$retroamp_root/LICENSE" "$retroamp_tmp/volume/LICENSE"
cp "$retroamp_root/NOTICE.md" "$retroamp_tmp/volume/NOTICE.md"
hdiutil create -volname Retroamp -srcfolder "$retroamp_tmp/volume" -format UDZO -ov "$retroamp_output/Retroamp-$retroamp_version.dmg"
printf 'Built %s\n' "$retroamp_output/Retroamp-$retroamp_version.dmg"
