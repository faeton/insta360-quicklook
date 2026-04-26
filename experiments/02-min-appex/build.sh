#!/bin/bash
# Build minimal Insta360QL Exp02 — host stub + Thumbnail.appex only.
set -euo pipefail

cd "$(dirname "$0")"

APP=Insta360QLExp02.app
SDK=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

# Host stub
cat > /tmp/exp02-stub.swift <<'EOF'
import Foundation
exit(0)
EOF
xcrun -sdk macosx swiftc /tmp/exp02-stub.swift -o "$APP/Contents/MacOS/Insta360QLExp02"
cp src/HostInfo.plist "$APP/Contents/Info.plist"

# Thumbnail.appex
APPEX="$APP/Contents/PlugIns/Thumbnail.appex"
mkdir -p "$APPEX/Contents/MacOS"
xcrun -sdk macosx swiftc \
    -module-name Thumbnail \
    -application-extension \
    -framework QuickLookThumbnailing \
    -framework AVFoundation \
    -framework AppKit \
    -framework Foundation \
    -emit-executable \
    -Xlinker -e -Xlinker _NSExtensionMain \
    src/ThumbnailProvider.swift \
    -o "$APPEX/Contents/MacOS/Thumbnail"
cp src/ThumbnailInfo.plist "$APPEX/Contents/Info.plist"

# Sign appex first (deep), then host
codesign --force \
    --sign - \
    --entitlements src/Thumbnail.entitlements \
    --options runtime \
    --timestamp=none \
    "$APPEX"

codesign --force --sign - "$APP"

codesign --verify --deep --strict "$APP" && echo "✓ codesign verified"

echo
echo "=== bundle layout ==="
find "$APP" -type f | sort
echo
ls -lh "$APP/Contents/MacOS/Insta360QLExp02" "$APPEX/Contents/MacOS/Thumbnail"
