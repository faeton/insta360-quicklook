# Insta360 Quick Look — Implementation Plan

> Native macOS Quick Look App Extension that adds **Space-bar preview** and **Finder thumbnails** for Insta360 files (`.insv`, `.insp`, `.lrv`) on macOS Sequoia (15) and Tahoe (26).

## Why this exists

### The user-visible bug
On macOS Sequoia/Tahoe, pressing Space on an Insta360 file in Finder either does nothing or shows a generic icon. There are several layered reasons:

1. **Unknown extensions** — `.insv`, `.insp`, `.lrv` are not recognized by macOS out of the box, so files resolve to dynamic UTIs (`dyn.ah62d4rv4ge80w5xxs2` etc.). LaunchServices can't route them to any preview handler.
2. **Insta360 Studio's bundled QL extension is broken** — `/Applications/Insta360 Studio.app/Contents/PlugIns/QuickLookHost.app` ships modern `Preview.appex` + `Thumbnail.appex`, but:
   - `QuickLookHost.app` is buried under `PlugIns/` of Studio. LaunchServices only scans top-level `.app` bundles in `/Applications`, `~/Applications`, etc., so it never sees the host and never registers the appex.
   - The appex declares only `dyn.*` UTIs in `QLSupportedContentTypes`. Since Sequoia, Apple's Quick Look daemon does not route through `dyn.*` UTIs to third-party extensions (security tightening). So even if the host were discovered, the extension wouldn't activate for real `.insv` files.
3. **Apple's built-in QuickTime thumbnailer refuses HEVC `.insv`** — even after we declare `.insv` as `public.mpeg-4`-conformant via `UTExportedTypeDeclarations` (so the file is properly typed and Apple's built-in handlers take over), QuickTime's sandboxed thumbnail process refuses HEVC streams whose `pix_fmt = yuvj420p` and `color_range = pc` (full-range YUV — what action cameras emit). Same bug hits GoPro and DJI HEVC. CLI `qlmanage -t` works because it runs in a less-restricted context. Finder doesn't.
4. **Legacy `.qlgenerator` plugin is dead** — Apple removed loading of the old `.qlgenerator` API in Sequoia. Insta360's own legacy plugin (`/Library/QuickLook/QLInsta360Picture.qlgenerator`) was non-functional; we deleted it.

### What our previous workaround does and doesn't fix

Current state in user's system (`~/Library/Application Support/Insta360QL/Insta360UTI.app`): a stub `.app` whose `Info.plist` declares two static UTIs:
- `com.insta360.insv` → conforms to `public.mpeg-4`, tags `[insv, lrv]`
- `com.insta360.insp` → conforms to `public.jpeg`, tags `[insp]`

This:
- ✅ Fixes JPEG `.insp` previews (Apple's Preview thumbnailer handles them).
- ✅ Fixes H.264 `.insv` and `.lrv` previews (Apple's QuickTime thumbnailer handles them).
- ❌ Doesn't fix HEVC `.insv` previews — the H.264/HEVC codec gate inside quicklookd is upstream of UTI routing.

## What this project builds

A proper, ad-hoc-signed Quick Look App Extension bundle that:

1. Declares the same UTIs as our existing stub (so we replace the stub entirely — single source of truth).
2. Provides a `Thumbnail.appex` that generates thumbnails using `AVAssetImageGenerator` from our own (less-sandboxed) extension process, bypassing Apple's HEVC-pix_fmt rejection. For `.insp`, just decodes the JPEG.
3. Provides a `Preview.appex` that hands the URL back to the system with the proper `contentType` so the system's built-in AVKit player (which has fewer restrictions for *playback* than the thumbnail generator) can render Space-press preview.
4. Optionally (v2) renders a custom info overlay: filename, duration, codec, GPS coords from EXIF, timecode, dual-fisheye visualization.

Distribution: single `Insta360QuickLook.app` dragged to `/Applications` (or `~/Library/Application Support/Insta360QL/`). User enables in *System Settings → General → Login Items & Extensions → Quick Look* (one-time).

## Why not just patch existing tools

| Option | Why rejected |
|---|---|
| Edit `Insta360 Studio.app/Contents/Info.plist` to add UTI declarations | Breaks codesign of Studio (Gatekeeper warnings, trust prompts). Wiped on every Studio update. |
| Promote Insta360's bundled `QuickLookHost.app` to `/Applications` and patch its appex `QLSupportedContentTypes` | Same — breaks codesign, wiped on Studio update. Plus Insta360's appex is a black box; if their bundled provider is buggy (which it likely is, since they abandoned it), we inherit the bugs. |
| Use [Marginal/QLVideo](https://github.com/Marginal/QLVideo) (uses ffmpeg) | Heavy dependency (~30 MB ffmpeg libs bundled), needs UTI patch for our extensions, doesn't handle `.insp`. Fine fallback but heavier than necessary — Apple's AVFoundation handles HEVC fine in our extension's context. |
| Re-encode HEVC `.insv` to fix `pix_fmt` | Modifies source files. Even with `-c copy -bsf:v hevc_metadata`, headers change → Insta360 Studio / Premiere may have edge cases. Not worth it. |
| Symlinks `file.insv → file.insv.mp4` | Tested earlier — Finder resolves the symlink and sees `.insv` extension on the target. Doesn't help. |

## Reference implementation: QLMarkdown by sbarex

User already has [QLMarkdown 1.5.0](https://github.com/sbarex/QLMarkdown) installed in `/Applications/QLMarkdown.app`. Its bundle structure is exactly what we'll mirror:

```
QLMarkdown.app/
├── Contents/
│   ├── Info.plist              ← CFBundleDocumentTypes (LSHandlerRank=None) + Sparkle config
│   ├── MacOS/QLMarkdown        ← stub host app (for opening Settings UI)
│   ├── PlugIns/
│   │   └── Markdown QL Extension.appex/
│   │       └── Contents/Info.plist  ← NSExtensionPointIdentifier=com.apple.quicklook.preview
│   │                                  QLSupportedContentTypes=[public.markdown, ...]
│   └── Frameworks/Sparkle.framework  (autoupdate; we'll skip this for v1)
```

QLMarkdown declares 16 content types (markdown, rmarkdown, typora, daring fireball, etc.) — proves the pattern is robust and accepted by macOS for cases like ours where one extension claims multiple semantic types.

## Architecture

### Bundle layout

```
Insta360QuickLook.app/                         # ~150 KB total
├── Contents/
│   ├── Info.plist                             # see "Host Info.plist" below
│   ├── MacOS/Insta360QuickLook                # stub binary (1-line shell or empty Swift)
│   ├── Resources/
│   │   └── AppIcon.icns                       # cosmetic; copy from Insta360 Studio
│   └── PlugIns/
│       ├── Thumbnail.appex/
│       │   ├── Contents/Info.plist            # NSExtensionPointIdentifier=com.apple.quicklook.thumbnail
│       │   ├── Contents/MacOS/Thumbnail       # Swift binary
│       │   └── Contents/_CodeSignature/
│       └── Preview.appex/
│           ├── Contents/Info.plist            # NSExtensionPointIdentifier=com.apple.quicklook.preview
│           ├── Contents/MacOS/Preview         # Swift binary
│           └── Contents/_CodeSignature/
```

### Host `Info.plist` keys

```xml
CFBundleIdentifier         = com.faeton.insta360quicklook
CFBundleName               = Insta360 QuickLook
CFBundleDisplayName        = Insta360 QuickLook
CFBundleExecutable         = Insta360QuickLook
CFBundleVersion            = 1
CFBundleShortVersionString = 0.1
LSMinimumSystemVersion     = 13.0          # broad compat; 15+ is the real target
LSUIElement                = true          # never appears in Dock/menu

UTExportedTypeDeclarations = [
    {
        UTTypeIdentifier        = com.insta360.insv
        UTTypeDescription       = Insta360 Panoramic Video
        UTTypeConformsTo        = [public.mpeg-4, public.movie]
        UTTypeTagSpecification  = {
            public.filename-extension = [insv, lrv]
            public.mime-type          = [video/mp4]
        }
    },
    {
        UTTypeIdentifier        = com.insta360.insp
        UTTypeDescription       = Insta360 Panoramic Image
        UTTypeConformsTo        = [public.jpeg, public.image]
        UTTypeTagSpecification  = {
            public.filename-extension = [insp]
            public.mime-type          = [image/jpeg]
        }
    },
]

CFBundleDocumentTypes = [
    {
        CFBundleTypeName    = Insta360 Panoramic Video
        CFBundleTypeRole    = Viewer
        LSItemContentTypes  = [com.insta360.insv]
        LSHandlerRank       = None         # don't claim to be the default opener (Studio is)
    },
    { ...same for insp... },
]
```

### Thumbnail.appex `Info.plist` (NSExtension keys)

```xml
NSExtension = {
    NSExtensionPointIdentifier = com.apple.quicklook.thumbnail
    NSExtensionPrincipalClass  = $(PRODUCT_MODULE_NAME).ThumbnailProvider
    NSExtensionAttributes = {
        QLSupportedContentTypes        = [com.insta360.insv, com.insta360.insp]
        QLThumbnailMinimumDimension    = 32
    }
}
```

### Preview.appex `Info.plist`

```xml
NSExtension = {
    NSExtensionPointIdentifier = com.apple.quicklook.preview
    NSExtensionPrincipalClass  = $(PRODUCT_MODULE_NAME).PreviewProvider
    NSExtensionAttributes = {
        QLSupportedContentTypes  = [com.insta360.insv, com.insta360.insp]
        QLIsDataBasedPreview     = false
        QLSupportsSearchableItems = false
    }
}
```

## Code

### `src/Thumbnail.swift`

```swift
import QuickLookThumbnailing
import AVFoundation
import AppKit

class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let ext = url.pathExtension.lowercased()
        let size = request.maximumSize

        if ext == "insp" {
            // Plain JPEG — direct decode via NSImage
            guard let img = NSImage(contentsOf: url),
                  let rep = img.representations.first else {
                handler(nil, NSError(domain: "Insta360QL", code: 1))
                return
            }
            let pxSize = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
                let aspect = pxSize.width / pxSize.height
                let drawSize = aspect > size.width / size.height
                    ? NSSize(width: size.width, height: size.width / aspect)
                    : NSSize(width: size.height * aspect, height: size.height)
                let origin = NSPoint(
                    x: (size.width - drawSize.width) / 2,
                    y: (size.height - drawSize.height) / 2
                )
                img.draw(in: NSRect(origin: origin, size: drawSize))
                return true
            }), nil)
            return
        }

        // .insv / .lrv — extract first frame via AVAssetImageGenerator.
        // This runs in our extension's context, NOT the strict quicklookd
        // sandbox, so HEVC with pix_fmt=yuvj420p is decoded normally.
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        // Cap dimensions to save decode work
        gen.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        do {
            let cg = try gen.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
            handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
                let ctx = NSGraphicsContext.current!.cgContext
                let imgAspect = CGFloat(cg.width) / CGFloat(cg.height)
                let frameAspect = size.width / size.height
                let rect: CGRect
                if imgAspect > frameAspect {
                    let h = size.width / imgAspect
                    rect = CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
                } else {
                    let w = size.height * imgAspect
                    rect = CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
                }
                ctx.draw(cg, in: rect)
                return true
            }), nil)
        } catch {
            handler(nil, error)
        }
    }
}
```

### `src/Preview.swift`

```swift
import QuickLookUI
import Cocoa

class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(
        for request: QLFilePreviewRequest,
        completionHandler handler: @escaping (QLPreviewReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let ext = url.pathExtension.lowercased()

        let contentType: UTType =
            ext == "insp" ? .jpeg :
            (ext == "insv" || ext == "lrv") ? .mpeg4Movie :
            .data

        // Hand the URL straight back — the system's preview UI (AVKit for
        // movies, image viewer for JPEG) will render it. AVKit playback
        // doesn't have the same HEVC-pix_fmt restriction as the
        // thumbnail-generation pipeline, so HEVC plays fine here.
        let reply = QLPreviewReply(fileURL: url, contentType: contentType)
        handler(reply, nil)
    }
}
```

## Build

No Xcode project — direct `swiftc` from CLI. SDK from Xcode CLT (`xcrun --sdk macosx --show-sdk-path`).

### `build.sh`

```bash
#!/bin/bash
set -euo pipefail

APP=Insta360QuickLook.app
SDK=$(xcrun --sdk macosx --show-sdk-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"

# Host stub (just exits — never actually launches because LSUIElement+no UI)
cat > /tmp/stub.swift << 'EOF'
import Foundation
exit(0)
EOF
xcrun -sdk macosx swiftc /tmp/stub.swift -o "$APP/Contents/MacOS/Insta360QuickLook"

cp src/HostInfo.plist "$APP/Contents/Info.plist"

# Thumbnail.appex
APPEX="$APP/Contents/PlugIns/Thumbnail.appex"
mkdir -p "$APPEX/Contents/MacOS"
xcrun -sdk macosx swiftc \
    -framework QuickLookThumbnailing \
    -framework AVFoundation \
    -framework AppKit \
    -emit-executable \
    src/Thumbnail.swift \
    -o "$APPEX/Contents/MacOS/Thumbnail"
cp src/ThumbnailInfo.plist "$APPEX/Contents/Info.plist"

# Preview.appex
APPEX="$APP/Contents/PlugIns/Preview.appex"
mkdir -p "$APPEX/Contents/MacOS"
xcrun -sdk macosx swiftc \
    -framework QuickLookUI \
    -framework Cocoa \
    -emit-executable \
    src/Preview.swift \
    -o "$APPEX/Contents/MacOS/Preview"
cp src/PreviewInfo.plist "$APPEX/Contents/Info.plist"

# Ad-hoc sign — required for LaunchServices to trust UTI declarations
# and for the appex to load.
codesign --force --deep --sign - "$APP"

# Verify
codesign --verify --deep --strict "$APP"
echo "✓ built $APP"
ls -lh "$APP/Contents/MacOS/Insta360QuickLook" \
       "$APP/Contents/PlugIns"/*.appex/Contents/MacOS/*
```

## Install

### `install.sh`

```bash
#!/bin/bash
set -euo pipefail

APP=Insta360QuickLook.app
DEST="$HOME/Library/Application Support/Insta360QL"
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Remove old stub if present
if [[ -d "$DEST/Insta360UTI.app" ]]; then
    "$LSREG" -u "$DEST/Insta360UTI.app" 2>/dev/null || true
    rm -rf "$DEST/Insta360UTI.app"
fi

# Remove any previous version of this app
"$LSREG" -u "$DEST/$APP" 2>/dev/null || true
rm -rf "$DEST/$APP"

mkdir -p "$DEST"
cp -R "$APP" "$DEST/"

"$LSREG" -f "$DEST/$APP"

# Reset QL caches so it picks up the new extension
qlmanage -r
qlmanage -r cache

# Verify the extension is discoverable
echo
echo "Discovered extensions for our UTIs:"
pluginkit -mAvvv | grep -B2 -A1 'com\.faeton\.insta360quicklook' | head -20

echo
echo "Next: open System Settings → General → Login Items & Extensions →"
echo "      Quick Look, and toggle ON 'Insta360 QuickLook' (Preview + Thumbnail)."
```

## Test

### `test.sh`

```bash
#!/bin/bash
TRIPS=/Users/faeton/Media/Trips

declare -a CASES=(
    "$TRIPS/2025-11-pacific-tahiti/VID_20251027_141109_00_002.insv:HEVC small"
    "$TRIPS/2025-11-pacific-au/VID_20251206_114759_00_005.insv:HEVC large 2.5GB"
    "$TRIPS/2025-12-les-arcs/360/LRV_20251230_203924_01_015.lrv:H.264 lrv"
    "$TRIPS/2025-11-pacific-tonga/day1/LRV_20251003_213904_11_003.insv:H.264 insv"
    "$TRIPS/2024-09-anya-aquapark-paphos/IMG_20240929_060307_00_013.insp:JPEG insp"
)

mkdir -p /tmp/iql-test
rm -f /tmp/iql-test/*.png

for case in "${CASES[@]}"; do
    F="${case%%:*}"
    label="${case##*:}"
    out=$(qlmanage -t -s 256 -o /tmp/iql-test "$F" 2>&1 | tail -1)
    base=$(basename "$F")
    if [[ -f "/tmp/iql-test/$base.png" ]]; then
        size=$(/bin/ls -la "/tmp/iql-test/$base.png" | awk '{print $5}')
        echo "✓ $label  ($size bytes)"
    else
        echo "✗ $label  ($out)"
    fi
done
```

Plus a manual test: Finder Space-press on each example file. CLI `qlmanage -t` is necessary but not sufficient — only Finder confirms the user-visible bug is fixed.

## Validation criteria

- [ ] CLI thumbnail (`qlmanage -t`) succeeds for `.insv` (H.264), `.insv` (HEVC), `.lrv`, `.insp`.
- [ ] Finder Space-press shows preview window for all 4 cases.
- [ ] Finder icon view shows thumbnails for all 4 cases.
- [ ] HEVC `.insv` files > 2 GB preview correctly (the original failing case).
- [ ] No regression on existing working files (H.264, JPEG).
- [ ] Insta360 Studio still opens `.insv` on double-click (we don't claim to be the default app — `LSHandlerRank = None`).
- [ ] Spotlight `mdls` reports `kMDItemContentType = com.insta360.{insv|insp}` after our extension installs.

## Roadmap (post-v1)

| Feature | Effort | Value |
|---|---|---|
| Custom info overlay (filename, duration, codec, GPS) on thumbnail | small | medium — distinguishes from generic AVKit thumb |
| Apply equirectangular projection from dual-fisheye source for proper 360 preview | large — needs ffmpeg `v360` filter or custom Metal shader; offline render takes seconds | high for end users; expensive in QL budget |
| Sparkle autoupdate framework | small (drop in `Sparkle.framework`, add appcast feed) | medium — for distribution |
| Homebrew cask | small (cask formula referencing GitHub release) | high — discoverability |
| Notarization (Apple Developer ID) | $99/year + notarytool wiring | high for trust; not strictly needed for ad-hoc personal use |
| Settings UI in host app (toggle stitching, fisheye view, info overlay) | medium | medium — only after we have multiple modes |
| Support for `.insproj` / `.insprj` (Insta360 Studio project files) | small | low — these are project bundles, less commonly previewed |

## File layout in this repo

```
insta360-quicklook/
├── PLAN.md              # this file
├── README.md            # user-facing install/build docs (TBD)
├── LICENSE              # MIT
├── build.sh
├── install.sh
├── test.sh
├── src/
│   ├── HostInfo.plist
│   ├── Thumbnail.swift
│   ├── ThumbnailInfo.plist
│   ├── Preview.swift
│   └── PreviewInfo.plist
└── .gitignore           # /Insta360QuickLook.app, /build/, .DS_Store
```

## Risks & open questions

- **Sequoia/Tahoe enable-extension UX**: third-party QL extensions need explicit user toggle in System Settings the first time. Document clearly in README. There's no programmatic way to enable from install script.
- **Ad-hoc codesign trust**: confirmed earlier that LaunchServices marks ad-hoc-signed UTI declarations as `untrusted` in `lsregister -dump`, but they still resolve correctly in practice (Spotlight + QL both honored them in the stub-app testing). If Apple tightens this in a future update, we'd need Developer ID. Watch for it.
- **AVAssetImageGenerator in extension sandbox**: the extension process *is* sandboxed (lighter than quicklookd's, but still). Need to verify HEVC decode actually succeeds at runtime, not just compile. If it doesn't, fall back to ffmpeg via XPC service or shipping a static `ffmpeg` binary in `Resources/`.
- **Insta360 file format edge cases**: `.insv` from older firmware (X1, ONE) may use different brands/codecs than X2/X3/X4. Test on a wider sample if possible.
- **`.insp` JPEG variants**: a few `.insp` from newer firmware may be HEIC instead of JPEG. Detect via magic bytes, not extension. Trivial to handle.
- **Stitching**: explicitly out of scope for v1. Dual-fisheye thumbnail is fine — that's also what Insta360 Studio's own QL provider would have shown.

## Ownership

- Repo: `~/Sites/insta360-quicklook` (local for now; push to `github.com/faeton/insta360-quicklook` when ready).
- License: MIT.
- Maintenance: low — Apple QL APIs are stable, file formats don't change. Expect to touch only when macOS major version breaks something.
