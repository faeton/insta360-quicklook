#!/bin/bash
# Build Insta360QuickLook.app — host app + Thumbnail.appex + Preview.appex.
# No Xcode project; pure swiftc + iconutil + codesign.
#
# Output: ./Insta360QuickLook.app.
# Sign: ad-hoc by default, which is enough for personal use. Set SIGN_ID to a
# Developer ID identity for a build that can be notarized (see release.sh).
set -euo pipefail
cd "$(dirname "$0")"

APP=Insta360QuickLook.app
SDK=$(xcrun --sdk macosx --show-sdk-path)
SIGN_ID="${SIGN_ID:--}"
if [[ "$SIGN_ID" == "-" ]]; then TIMESTAMP=--timestamp=none; else TIMESTAMP=--timestamp; fi

# Regenerate icon if missing
if [[ ! -f icon/AppIcon.icns ]]; then
    echo "+ generating AppIcon.icns"
    swift icon/make-icon.swift > /dev/null
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

# Host app: registers the extensions when opened and shows their status.
xcrun -sdk macosx swiftc -parse-as-library -framework AppKit \
    -framework UniformTypeIdentifiers \
    src/HostApp.swift -o "$APP/Contents/MacOS/Insta360QuickLook"
cp src/HostInfo.plist "$APP/Contents/Info.plist"
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ---- shared appex builder -----------------------------------------------
build_appex() {
    local name="$1"
    local module="$2"
    local sources
    read -r -a sources <<< "$3"
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
    #   ProxyResolver.swift and TrailerReader.swift compiled into both modules
    #   (shared logic)
    xcrun -sdk macosx swiftc \
        -module-name "$module" \
        -application-extension \
        "${fwflags[@]}" \
        -framework Foundation \
        -emit-executable \
        -Xlinker -e -Xlinker _NSExtensionMain \
        "${sources[@]}" \
        src/ProxyResolver.swift \
        src/TrailerReader.swift \
        -o "$APPEX/Contents/MacOS/$name"

    cp "$plist" "$APPEX/Contents/Info.plist"

    # iCloud-synced checkouts (Desktop & Documents in iCloud) get a
    # com.apple.FinderInfo xattr stamped on fresh directories, which codesign
    # rejects as "resource fork, Finder information, or similar detritus".
    /usr/bin/xattr -cr "$APPEX"

    codesign --force --sign "$SIGN_ID" \
        --entitlements "$entitlements" \
        --options runtime \
        "$TIMESTAMP" \
        "$APPEX"
}

build_appex Thumbnail Thumbnail src/ThumbnailProvider.swift src/ThumbnailInfo.plist src/Thumbnail.entitlements \
    QuickLookThumbnailing AVFoundation AppKit

build_appex Preview Preview "src/PreviewViewController.swift src/PanoramaView.swift" src/PreviewInfo.plist src/Preview.entitlements \
    QuickLookUI AVKit AppKit Metal MetalKit

/usr/bin/xattr -cr "$APP"
codesign --force --sign "$SIGN_ID" --options runtime "$TIMESTAMP" "$APP"
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
