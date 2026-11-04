#!/bin/bash
# Build Insta360QuickLook.app — host stub + Thumbnail.appex + Preview.appex.
# No Xcode project; pure swiftc + iconutil + codesign.
#
# Output: ./Insta360QuickLook.app (~200 KB).
# Sign: ad-hoc (no Developer ID needed for personal use).
set -euo pipefail
cd "$(dirname "$0")"

APP=Insta360QuickLook.app
SDK=$(xcrun --sdk macosx --show-sdk-path)

# Regenerate icon if missing
if [[ ! -f icon/AppIcon.icns ]]; then
    echo "+ generating AppIcon.icns"
    swift icon/make-icon.swift > /dev/null
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

# Host stub (LSUIElement: never appears in Dock; only there so the bundle
# is a valid .app for LaunchServices to register the appex's UTIs).
cat > /tmp/insta360ql-stub.swift <<'EOF'
import Foundation
exit(0)
EOF
xcrun -sdk macosx swiftc /tmp/insta360ql-stub.swift -o "$APP/Contents/MacOS/Insta360QuickLook"
cp src/HostInfo.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ---- shared appex builder -----------------------------------------------
build_appex() {
    local name="$1"
    local module="$2"
    local principal_source="$3"
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

    # Tahoe gotchas baked in:
    #   -application-extension       — silences extension-context warnings
    #   -Xlinker -e _NSExtensionMain — direct-call system entry, avoids
    #                                  recursion through Swift's auto-main
    #   no main.swift, no top-level statements anywhere
    #   ProxyResolver.swift compiled into both modules (shared logic)
    xcrun -sdk macosx swiftc \
        -module-name "$module" \
        -application-extension \
        "${fwflags[@]}" \
        -framework Foundation \
        -emit-executable \
        -Xlinker -e -Xlinker _NSExtensionMain \
        "$principal_source" \
        src/ProxyResolver.swift \
        -o "$APPEX/Contents/MacOS/$name"

    cp "$plist" "$APPEX/Contents/Info.plist"

    # iCloud-synced checkouts (Desktop & Documents in iCloud) get a
    # com.apple.FinderInfo xattr stamped on fresh directories, which codesign
    # rejects as "resource fork, Finder information, or similar detritus".
    /usr/bin/xattr -cr "$APPEX"

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

/usr/bin/xattr -cr "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ codesign verified"

echo
echo "=== bundle ==="
find "$APP" -type f | sort
echo
ls -lh "$APP/Contents/MacOS/Insta360QuickLook" \
       "$APP/Contents/PlugIns/Thumbnail.appex/Contents/MacOS/Thumbnail" \
       "$APP/Contents/PlugIns/Preview.appex/Contents/MacOS/Preview"
echo
echo "Built. Run ./install.sh to install."
