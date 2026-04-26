#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP=Insta360QLExp02.app
DEST="$HOME/Library/Application Support/Insta360QL"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

echo "=== unregistering old stub Insta360UTI.app (if present) ==="
if [[ -d "$DEST/Insta360UTI.app" ]]; then
    "$LSREG" -u "$DEST/Insta360UTI.app" 2>/dev/null || true
    rm -rf "$DEST/Insta360UTI.app"
    echo "removed stub"
fi

echo "=== removing old exp02 instance ==="
"$LSREG" -u "$DEST/$APP" 2>/dev/null || true
rm -rf "$DEST/$APP"

mkdir -p "$DEST"
cp -R "$APP" "$DEST/"
echo "copied to $DEST/$APP"

echo "=== registering ==="
"$LSREG" -f "$DEST/$APP"

echo "=== resetting QL caches ==="
qlmanage -r 2>&1 | tail -1
qlmanage -r cache 2>&1 | tail -1
killall -9 quicklookd 2>/dev/null || true
killall -9 com.apple.quicklook.ThumbnailsAgent 2>/dev/null || true

echo
echo "=== verifying registration ==="
echo "--- pluginkit ---"
pluginkit -mAvvv 2>&1 | grep -B1 -A2 "com.faeton.insta360ql.exp02" || echo "NOT FOUND in pluginkit"
echo
echo "--- lsregister UTI ---"
"$LSREG" -dump 2>/dev/null | grep -A8 "com.insta360.insv" | head -30

echo
echo "Now: open System Settings → General → Login Items & Extensions → Quick Look,"
echo "and toggle ON 'Insta360QL Exp02' if not already on."
