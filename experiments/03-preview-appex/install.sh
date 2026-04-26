#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=Insta360QLExp03.app
DEST="$HOME/Library/Application Support/Insta360QL"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Unregister and remove any prior versions, including exp02
for old in Insta360UTI.app Insta360QLExp02.app Insta360QLExp03.app; do
    if [[ -d "$DEST/$old" ]]; then
        "$LSREG" -u "$DEST/$old" 2>/dev/null || true
        rm -rf "$DEST/$old"
        echo "removed $old"
    fi
done

mkdir -p "$DEST"
cp -R "$APP" "$DEST/"
"$LSREG" -f "$DEST/$APP"

# Register each appex against its extension point
for ext in "$DEST/$APP/Contents/PlugIns/"*.appex; do
    pluginkit -a "$ext"
done

# Reset QL caches
qlmanage -r > /dev/null 2>&1
qlmanage -r cache > /dev/null 2>&1
killall -9 com.apple.quicklook.ThumbnailsAgent 2>/dev/null || true
killall Finder 2>/dev/null || true

echo
echo "=== registered extensions ==="
pluginkit -mAvvv 2>&1 | grep -B1 -A4 "insta360ql.exp03"
echo
echo "Now: System Settings → General → Login Items & Extensions → Quick Look,"
echo "and toggle ON 'Insta360QL Exp03' (both Preview and Thumbnail)."
