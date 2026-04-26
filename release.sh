#!/bin/bash
# Build a release artifact: clean build + zip + SHA256 + Cask snippet.
# Doesn't push or tag — just produces dist/Insta360QuickLook-vX.Y.Z.zip
# and prints the cask formula for you to paste into homebrew-faeton/tap.
#
# Workflow:
#   1. ./release.sh                  → builds dist/*.zip, prints cask
#   2. git tag vX.Y.Z && git push --tags
#   3. gh release create vX.Y.Z dist/Insta360QuickLook-vX.Y.Z.zip
#   4. paste the printed cask into homebrew-tap/Casks/insta360-quicklook.rb
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' src/HostInfo.plist)
TAG="v$VERSION"
APP=Insta360QuickLook.app
ZIP="Insta360QuickLook-$TAG.zip"

echo "+ building $APP (version $VERSION)"
./build.sh > /dev/null

mkdir -p dist
rm -f "dist/$ZIP"

echo "+ packaging dist/$ZIP"
ditto -c -k --keepParent "$APP" "dist/$ZIP"

SHA=$(shasum -a 256 "dist/$ZIP" | awk '{print $1}')
SIZE=$(ls -lh "dist/$ZIP" | awk '{print $5}')

echo "+ done: dist/$ZIP ($SIZE)"
echo "+ sha256: $SHA"

cat <<EOF

──────────────────────────────────────────────────────────────────────
Next steps:
  git tag $TAG && git push origin $TAG
  gh release create $TAG dist/$ZIP --title "$TAG" --generate-notes

Then paste this into homebrew-faeton/tap/Casks/insta360-quicklook.rb:
──────────────────────────────────────────────────────────────────────

cask "insta360-quicklook" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/faeton/insta360-quicklook/releases/download/v#{version}/Insta360QuickLook-v#{version}.zip"
  name "Insta360 QuickLook"
  desc "Native Quick Look thumbnails and previews for Insta360 .insv/.insp/.lrv"
  homepage "https://github.com/faeton/insta360-quicklook"

  depends_on macos: ">= :ventura"

  app "Insta360QuickLook.app"

  postflight do
    lsreg = "/System/Library/Frameworks/CoreServices.framework/Versions/A/" \\
            "Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
    installed = "#{appdir}/Insta360QuickLook.app"
    system_command lsreg, args: ["-f", installed]
    Dir["#{installed}/Contents/PlugIns/*.appex"].each do |ext|
      system_command "/usr/bin/pluginkit", args: ["-a", ext]
    end
    system_command "/usr/bin/qlmanage", args: ["-r"]
    system_command "/usr/bin/qlmanage", args: ["-r", "cache"]
  end

  uninstall quit: "com.faeton.insta360quicklook"

  zap trash: [
    "~/Library/Application Support/Insta360QL",
    "~/Library/Caches/com.faeton.insta360quicklook",
  ]

  caveats <<~EOS
    One-time setup required:
      System Settings → General → Login Items & Extensions → Quick Look
      Toggle ON "Insta360 QuickLook" (Thumbnail and Preview both appear).
  EOS
end
EOF
