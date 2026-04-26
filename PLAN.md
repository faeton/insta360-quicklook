# Insta360 Quick Look — Implementation Plan

> Native macOS Quick Look App Extension that adds **Space-bar preview** and **Finder thumbnails** for Insta360 files (`.insv`, `.insp`, `.lrv`) on macOS Sequoia (15) and Tahoe (26).

> **Status (2026-04-26):** Both Thumbnail and Preview extensions proven
> end-to-end on Tahoe (macOS 26.4.1). HEVC 2.5 GB `.insv` shows real
> frame in Finder; Space-press opens video player with timeline +
> controls; `.insv` automatically substituted with paired `.lrv` proxy
> (smaller, dual-fisheye). Ready to assemble production `Insta360QuickLook.app`.
> See `experiments/findings.md` for the full empirical story.

## Why this exists

### The user-visible bug
On macOS Sequoia/Tahoe, pressing Space on an Insta360 file in Finder either does nothing or shows a generic icon. The actual chain (verified empirically — see `experiments/findings.md`):

1. **Unknown extensions** — `.insv`, `.insp`, `.lrv` are not recognized by macOS out of the box, so files resolve to dynamic UTIs (`dyn.ah62d4rv4ge80w5xxs2` etc.). LaunchServices can't route them to any preview handler.
2. **AVFoundation is extension-gated, not UTI-gated** — even after declaring `.insv` as `public.mpeg-4`-conformant, `AVURLAsset(url:)` returns `-11828 "Cannot Open"` for any path ending in `.insv`/`.lrv`. AVFoundation's demuxer-routing reads the filename extension, ignoring our UTI declaration. `AVURLAssetOverrideMIMETypeKey` does not help.
3. **Finder's Space → ThumbnailsAgent fails silently** — `com.apple.quicklook.ThumbnailsAgent` tries the standard AVFoundation route, gets -11828, returns `null` in 0.249s without consulting any extension. CLI `qlmanage -t` follows a different code path that *does* succeed, which is why earlier diagnosis blamed HEVC pix_fmt — that hypothesis is **false**.
4. **Insta360 Studio's bundled QL extension is invisible to LaunchServices** — `/Applications/Insta360 Studio.app/Contents/PlugIns/QuickLookHost.app` is buried under `PlugIns/`, so LaunchServices never registers it. `pluginkit` confirms zero Insta360 QL providers ever load.
5. **What you actually see in Finder** is Studio's `DocumentIcon1.icns` from its document-type claim — not a Quick Look thumbnail at all.
6. **Legacy `.qlgenerator` plugin is dead** — Apple removed `.qlgenerator` loading in Sequoia.

### The fix that works (and why HEVC is a red herring)

Hardlink the source file to `<tmp>/<uuid>.mp4` and feed *that* path to AVAssetImageGenerator / AVPlayer. AVFoundation opens it instantly — HEVC, full-range YUV, 2.5 GB, all fine. Decode of the first I-frame takes ~0.1s regardless of file size. The whole "HEVC pix_fmt rejection" story dissolves: it never was the bug.

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

1. Declares Insta360 UTIs via `UTImportedTypeDeclarations` (we don't own the `com.insta360.*` namespace) and replaces our existing stub entirely.
2. Provides a `Thumbnail.appex` that hardlinks the file to `<tmp>/<uuid>.mp4` and runs `AVAssetImageGenerator` on the hardlink. For `.insp`, uses `CGImageSourceCreateThumbnailAtIndex` directly. **Proven working** in exp 02.
3. Provides a `Preview.appex` as an `NSViewController` conforming to `QLPreviewingController`, with an `AVPlayerView` (or `AVPlayerLayer` fallback) playing from the same hardlink. The `QLPreviewReply(fileURL:contentType:)` API in PLAN v0 does **not exist** in macOS 26.4 SDK — view-based is the only option for video.
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

### `src/PreviewViewController.swift`

> Original PLAN had a `QLPreviewProvider` returning `QLPreviewReply(fileURL:contentType:)`. That initializer **does not exist** in macOS 26.4 SDK, and even if we used `QLPreviewReply(fileURL:)` it would route the original `.insv` path back into AVFoundation and hit the same -11828 wall. View-based is the right path.

See `experiments/03-preview-appex/src/PreviewViewController.swift` for the
verified-working implementation. Key points:

- Bare `NSView` in `loadView()` — no fixed frame, no autoresizing mask, no
  intrinsic constraints. QL panel sizes us via its own constraints.
- Sub `AVPlayerView` added with `translatesAutoresizingMaskIntoConstraints
  = false` and explicit anchor constraints to the parent. (Mixing the
  player view's intrinsic constraints with autoresizingMask crashes
  NSISEngine on resize — see findings gotcha 9.)
- Substitute `LRV_*.lrv` proxy if present (see "LRV proxy substitution").
- Hardlink the resolved source to `<tmp>/<uuid>.mp4`, store the path as
  a property, delete in `viewWillDisappear` *and* `deinit`.
- `viewWillDisappear` mutes audio aggressively:
  ```swift
  player?.volume = 0
  player?.pause()
  player?.replaceCurrentItem(with: nil)
  playerView?.player = nil
  ```
  Without this the audio buffer plays for ~500ms past panel close. Even
  with it, ~200ms tail leaks through XPC tear-down — acceptable for v1.

### Preview.appex Info.plist (NSExtension keys)

```xml
NSExtension = {
    NSExtensionPointIdentifier = com.apple.quicklook.preview
    NSExtensionPrincipalClass  = $(PRODUCT_MODULE_NAME).PreviewViewController
    NSExtensionAttributes = {
        QLSupportedContentTypes = [com.insta360.insv, com.insta360.insp]
        # Do NOT set QLIsDataBasedPreview — view-based is implied by
        # principal class being NSViewController + QLPreviewingController.
    }
}
```

## Build

No Xcode project — direct `swiftc` from CLI. SDK from Xcode CLT (`xcrun --sdk macosx --show-sdk-path`).

### LRV proxy substitution (key UX win)

Insta360 cameras write a paired low-res proxy alongside each `.insv`:
`VID_<ts>_<sensorA>_<idx>.insv` ↔ `LRV_<ts>_<sensorB>_<idx>.lrv`. The proxy
is **already stitched dual-fisheye**, **H.264** instead of HEVC, and 5–10×
smaller. For Quick Look it's the better source on every axis:

- AVPlayer cold-start in milliseconds vs seconds for raw HEVC.
- Both fisheye lenses visible simultaneously instead of just one.
- No HEVC decode pressure on integrated GPU.
- Tiny memory footprint inside the extension's strict sandbox limit (~1.3 GB).

Substitution is one `fileExists` probe on the predicted sibling name (try
sensor index `01` first, fall back to `02`, then `00`). Apply this in both
Thumbnail and Preview extensions. Fall through to the `.insv` itself if no
LRV is present (e.g. user copied one file without its proxy).

### Required entitlements

Both extensions need:

```xml
<key>com.apple.security.app-sandbox</key>                                   <true/>
<key>com.apple.security.files.user-selected.read-only</key>                 <true/>
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array>
    <string>/</string>
</array>
```

The temporary-exception is what unlocks LRV-proxy lookup (sandbox extension
can only see the file QuickLook handed it; siblings are invisible without
this). QLMarkdown uses the same entitlement. For ad-hoc personal builds it's
fine; for App Store distribution it would need App Review justification.

### Tahoe (26) gotchas — required for the appex to even start

These were discovered the hard way (see `experiments/findings.md` for the
full story including stack traces):

1. **No `main.swift`, no top-level statements.** swiftc with any top-level
   code produces a Swift `main` symbol; ExtensionFoundation's bootstrap on
   Tahoe ends up calling that `main` recursively until SIGSEGV at depth ~9000.
2. **Force linker entry to `_NSExtensionMain`** via
   `-Xlinker -e -Xlinker _NSExtensionMain`. This bypasses Swift's main and
   hands control directly to the system extension bootstrap.
3. **`NSExtensionPrincipalClass` needs the module prefix** for Swift:
   `Module.ClassName`, e.g. `Thumbnail.ThumbnailProvider`. Mirror QLMarkdown.
4. **Add `-application-extension`** to swiftc to silence warnings about
   unavailable APIs in extension contexts.
5. **`pluginkit -a <appex>`** is required after install to register the
   extension under its NSExtensionPointIdentifier. `lsregister -f` alone
   leaves the extension invisible to ThumbnailsAgent / quicklookd.

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

# Preview.appex
APPEX="$APP/Contents/PlugIns/Preview.appex"
mkdir -p "$APPEX/Contents/MacOS"
xcrun -sdk macosx swiftc \
    -module-name Preview \
    -application-extension \
    -framework QuickLookUI \
    -framework AVKit \
    -framework AppKit \
    -framework Foundation \
    -emit-executable \
    -Xlinker -e -Xlinker _NSExtensionMain \
    src/PreviewViewController.swift \
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

# Critical on Tahoe: register each appex against its extension point.
# Without this, lsregister sees the host but ThumbnailsAgent / quicklookd
# never discover the appex.
for ext in "$DEST/$APP/Contents/PlugIns/"*.appex; do
    pluginkit -a "$ext"
done

# Reset QL caches so it picks up the new extension
qlmanage -r
qlmanage -r cache
killall -9 com.apple.quicklook.ThumbnailsAgent 2>/dev/null || true
killall Finder 2>/dev/null || true

# Verify the extension is discoverable
echo
echo "Discovered extensions for our UTIs:"
pluginkit -mAvvv | grep -B2 -A4 'com\.faeton\.insta360quicklook' | head -30

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

Thumbnail (proven in exp 02):
- [x] CLI thumbnail (`qlmanage -t`) succeeds for HEVC `.insv` and copies. Already worked even before this project.
- [x] Finder Space-press shows real-frame thumbnail for HEVC `.insv` 2.5 GB (the original failing case).
- [x] Spotlight `mdls` reports `kMDItemContentType = com.insta360.insv`.
- [ ] Finder icon view (not just Space) shows thumbnails for all 4 cases — to verify after caches warm up.
- [ ] H.264 `.insv` and `.lrv` thumbnails (regression check vs old stub).
- [ ] `.insp` (JPEG and HEIC variants) thumbnail.

Preview (proven in exp 03):
- [x] Space-press on `.insv` opens AVPlayerView with playback controls (timeline, play, scrub).
- [x] LRV-proxy substitution active when sibling `.lrv` exists — plays dual-fisheye, both lenses.
- [x] No crash on QL panel resize.
- [x] Audio mostly stops on panel close (small ~200ms tail remaining).
- [ ] Verify no leak of hardlinked tmp files after many open/close cycles.
- [ ] Verify cross-volume case (source on external drive, /tmp on internal).

Cross-cutting:
- [ ] Insta360 Studio still opens `.insv` on double-click (we use `LSHandlerRank = None`).
- [ ] Studio's `DocumentIcon1.icns` does not bleed through and override our thumbnail in any Finder view.

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

Resolved (confirmed with experiments):
- ~~AVAssetImageGenerator in extension sandbox~~ — works, see exp 02. Hardlink trick required because AVFoundation routes by extension.
- ~~HEVC pix_fmt rejection~~ — not actually a bug; plain AVFoundation decodes all our HEVC samples once given a `.mp4` path.
- ~~Ad-hoc codesign trust~~ — works for both UTI claim and appex registration. Sandbox container created normally. `signer:none` warning from secinitd is non-fatal.
- ~~`UTImportedTypeDeclarations` correctness~~ — confirmed via lsregister and mdls.

Open:
- **AVPlayerView vs custom AVPlayerLayer view** in QL chrome — empirical. AVPlayerView may conflict with QL's toolbar. If so, fall back to AVPlayer + AVPlayerLayer attached to a plain NSView.
- **Hardlink lifetime in Preview** — must outlive AVPlayer. Store as property, delete in `deinit`. Verify no tmp leak after dismissing QL.
- **Cross-volume case** — if `/tmp` and source on different volumes, hardlink fails. Symlink works in plain Swift; not yet tested in sandbox. AppSandbox may block following symlinks to user-selected paths.
- **Insta360 file format edge cases** — `.insv` from older firmware (X1, ONE) may use different brands/codecs. Test on wider sample.
- **`.insp` HEIC variants** — `CGImageSource` handles JPEG and HEIC transparently, no detection logic needed.
- **Sequoia/Tahoe enable-extension UX** — third-party QL extensions need explicit user toggle in System Settings → Extensions → Quick Look. Also need toggle off+on after rebuild for ThumbnailsAgent to pick up changes. Document in README.
- **Insta360 Studio's `DocumentIcon1.icns` claim** — competes with our thumbnail in some Finder views. Empirically our extension wins now; track this.
- **Stitching** — explicitly out of scope for v1. Dual-fisheye thumbnail is fine.

## Ownership

- Repo: `~/Sites/insta360-quicklook` (local for now; push to `github.com/faeton/insta360-quicklook` when ready).
- License: MIT.
- Maintenance: low — Apple QL APIs are stable, file formats don't change. Expect to touch only when macOS major version breaks something.
