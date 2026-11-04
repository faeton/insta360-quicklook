#!/bin/bash
# Build, sign, notarize and staple a release, then zip it and print the cask.
# Doesn't tag or publish, so nothing here is public.
#
#   SIGN_ID          Developer ID Application identity (found automatically if unset)
#   NOTARY_PROFILE   notarytool keychain profile
#   TAG              release tag, such as v0.2.0-beta.1 (default: v<plist version>)
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' src/HostInfo.plist)
TAG="${TAG:-v$VERSION}"
APP=Insta360QuickLook.app
ZIP="dist/Insta360QuickLook-$TAG.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-porter-notarization}"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

if [[ -z "${SIGN_ID:-}" ]]; then
    SIGN_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -1)
fi
if [[ -z "$SIGN_ID" ]]; then
    echo "✗ no Developer ID Application identity found" >&2
    exit 1
fi
export SIGN_ID

# The built app is registered as soon as it exists. Don't leave a second copy around.
trap '"$LSREG" -u "$PWD/$APP" 2>/dev/null || true; rm -rf "$APP"' EXIT

tests/run.sh > /dev/null
echo "+ tests passed"

echo "+ building $APP ($TAG), signed by $SIGN_ID"
./build.sh > /dev/null

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "+ notarizing"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-zip so the stapled ticket is in what people download.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose=2 "$APP"

SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "+ done: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "+ sha256: $SHA"

cat <<EOF

──────────────────────────────────────────────────────────────────────
To publish:
  git tag $TAG && git push origin $TAG
  gh release create $TAG $ZIP --title "$TAG"   # add --prerelease for a test build

Cask for the tap (installs only once the disable! line is gone):
──────────────────────────────────────────────────────────────────────

cask "insta360-quicklook" do
  version "${TAG#v}"
  sha256 "$SHA"

  url "https://github.com/faeton/insta360-quicklook/releases/download/v#{version}/Insta360QuickLook-v#{version}.zip"
  name "Insta360 QuickLook"
  desc "Quick Look thumbnails and previews for Insta360 and DJI 360 video"
  homepage "https://github.com/faeton/insta360-quicklook"

  depends_on macos: :ventura

  app "Insta360QuickLook.app"

  uninstall quit: "com.faeton.insta360quicklook"

  zap trash: "~/Library/Caches/com.faeton.insta360quicklook"

  caveats "Open Insta360 QuickLook once to register its Quick Look extensions."
end
EOF
