#!/bin/bash
# Insta360QL Exp03: host stub + Thumbnail.appex + Preview.appex (NSViewController-based).
set -euo pipefail
cd "$(dirname "$0")"

APP=Insta360QLExp03.app
SDK=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

# Host stub
cat > /tmp/exp03-stub.swift <<'EOF'
import Foundation
exit(0)
EOF
xcrun -sdk macosx swiftc /tmp/exp03-stub.swift -o "$APP/Contents/MacOS/Insta360QLExp03"
cp src/HostInfo.plist "$APP/Contents/Info.plist"

build_appex() {
    local name="$1"
    local module="$2"
    local source="$3"
    local plist="$4"
    local entitlements="$5"
    shift 5
    local frameworks=("$@")

    local APPEX="$APP/Contents/PlugIns/${name}.appex"
    mkdir -p "$APPEX/Contents/MacOS"

    local fwflags=()
    for f in "${frameworks[@]}"; do
        fwflags+=("-framework" "$f")
    done

    xcrun -sdk macosx swiftc \
        -module-name "$module" \
        -application-extension \
        "${fwflags[@]}" \
        -framework Foundation \
        -emit-executable \
        -Xlinker -e -Xlinker _NSExtensionMain \
        "$source" \
        -o "$APPEX/Contents/MacOS/$name"

    cp "$plist" "$APPEX/Contents/Info.plist"

    codesign --force --sign - \
        --entitlements "$entitlements" \
        --options runtime \
        --timestamp=none \
        "$APPEX"
}

build_appex Thumbnail Thumbnail src/ThumbnailProvider.swift src/ThumbnailInfo.plist src/Thumbnail.entitlements \
    QuickLookThumbnailing AVFoundation AppKit

build_appex Preview Preview src/PreviewViewController.swift src/PreviewInfo.plist src/Preview.entitlements \
    QuickLookUI AVKit AppKit

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ codesign verified"

echo
echo "=== bundle ==="
find "$APP" -type f | sort
