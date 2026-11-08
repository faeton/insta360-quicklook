#!/bin/bash
# Install Insta360QuickLook.app → ~/Library/Application Support/Insta360QL/.
# Unregisters any previous version, registers the new one with LaunchServices,
# registers each .appex with pluginkit, resets Quick Look caches.
#
# After install: open System Settings → General →
#   Login Items & Extensions → Quick Look, and toggle ON "Insta360 QuickLook".
# (Required once. macOS does not let install scripts toggle this.)
set -euo pipefail
cd "$(dirname "$0")"

APP=Insta360QuickLook.app
DEST="$HOME/Library/Application Support/Insta360QL"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

if [[ ! -d "$APP" ]]; then
    echo "✗ $APP not found. Run ./build.sh first." >&2
    exit 1
fi

echo "+ removing prior versions (stub, experiments, current)"
for old in Insta360UTI.app Insta360QLExp02.app Insta360QLExp03.app Insta360QuickLook.app; do
    if [[ -d "$DEST/$old" ]]; then
        "$LSREG" -u "$DEST/$old" 2>/dev/null || true
        rm -rf "$DEST/$old"
    fi
done

mkdir -p "$DEST"
cp -R "$APP" "$DEST/"
echo "+ installed to $DEST/$APP"

"$LSREG" -f "$DEST/$APP"
for ext in "$DEST/$APP/Contents/PlugIns/"*.appex; do
    pluginkit -a "$ext"
done
# Same rule as HostApp.applyFallback: the public.data fallback is for macOS 26 and earlier (#4).
if (( $(sw_vers -productVersion | cut -d. -f1) < 27 )); then fallback=use; else fallback=ignore; fi
pluginkit -e "$fallback" -i com.faeton.insta360quicklook.thumbnail-fallback
echo "+ registered with LaunchServices and pluginkit (public.data fallback: $fallback)"

qlmanage -r > /dev/null 2>&1
qlmanage -r cache > /dev/null 2>&1
killall -9 com.apple.quicklook.ThumbnailsAgent 2>/dev/null || true
killall Finder 2>/dev/null || true
echo "+ reset Quick Look caches and restarted Finder"

echo
echo "=== registered extensions ==="
pluginkit -mAvvv 2>&1 | grep -B1 -A4 "insta360quicklook" | head -20

cat <<EOF

──────────────────────────────────────────────────────────────────────
One-time setup:
  System Settings → General → Login Items & Extensions → Quick Look
  Toggle ON "Insta360 QuickLook" (both Thumbnail and Preview appear).
──────────────────────────────────────────────────────────────────────
EOF
