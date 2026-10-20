# Insta360 QuickLook

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](https://swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tahoe verified](https://img.shields.io/badge/macOS%2026.6-verified-success)]()

Native macOS Quick Look extension that fixes broken Finder previews and
thumbnails for 360 camera files: Insta360 `.insv`, `.insp`, `.lrv` and
DJI Osmo 360 `.osv`, `.lrf`. Built for macOS Sequoia (15) and Tahoe (26).

Press **Space** on a 360 video in Finder. Get a real player with timeline,
play/pause, scrub — and dual-fisheye footage from both lenses, not a
generic blue icon. Works on HEVC clips of any size, including the 2 GB+
files that the underlying macOS bug breaks for everyone.

> **Why this exists:** out of the box, pressing Space on an `.insv` in
> Finder shows nothing — generic blue INSV icon, no playback. macOS
> doesn't recognize the extension; Insta360 Studio's bundled QuickLook
> handler is buried under `PlugIns/` where LaunchServices never finds
> it; AVFoundation refuses to open `.insv`/`.lrv` even after declaring
> them as `public.mpeg-4`. This extension fixes all of that with no
> reliance on Studio.

## What you get

- **Thumbnails** in Finder icon view for `.insv`, `.insp`, `.lrv`,
  `.osv` and `.lrf`, with a duration · codec pill and a "360°" badge in
  the corner so 360 footage stands out at a glance in mixed folders.
- **Space-press preview** in Finder — full AVPlayerView with timeline,
  play/pause, scrub. A HUD bar at the top of the panel shows capture
  date, time, **timezone**, resolution, codec, duration, and file
  size.
- **Capture-time timezone recovery.** Neither brand writes a TZ-aware
  ISO creation date, but the `mvhd` atom holds the absolute UTC moment
  while the filename holds the local wall clock. Their delta is the
  offset — a Tahiti shoot opened on a Berlin laptop still reads
  `08:45 GMT-10:00`, not the current TZ. Handles both
  `VID_YYYYMMDD_HHMMSS` (Insta360) and `CAM_YYYYMMDDHHMMSS` (DJI).
- **Proxy substitution** for the camera-written low-res file next to
  each clip (`LRV_*.lrv` for Insta360, same-basename `.LRF` for DJI):
  smaller, H.264 instead of HEVC, and pre-stitched dual-fisheye showing
  both lenses. On macOS 26.6 the sandbox no longer grants read access to
  sibling files, so this degrades to using the original — see
  [`experiments/findings.md`](experiments/findings.md) gotcha 11.
- Works for HEVC `.insv` files larger than 2 GB — the original failing
  case that the underlying macOS bug breaks for everyone.

## Install

Requirements: macOS 13+ (built and tested on Tahoe 26.4).

### Homebrew (recommended)

```bash
brew install --cask faeton/tap/insta360-quicklook
```

### From source

Needs Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/faeton/insta360-quicklook.git
cd insta360-quicklook
./build.sh && ./install.sh
```

Then enable the extension once:

> **System Settings → General → Login Items & Extensions → Quick Look**
> → toggle ON **Insta360 QuickLook**.

Or from the terminal, which also works and has to be repeated after each
reinstall (the appex gets a new UUID):

```bash
pluginkit -e use -i com.faeton.insta360quicklook.thumbnail
pluginkit -e use -i com.faeton.insta360quicklook.preview
pluginkit -m -A -v | grep insta360    # "+" in column 1 means enabled
```

## Verify

```bash
qlmanage -t -s 256 -o /tmp /path/to/some.insv      # CLI thumbnail check
mdls -name kMDItemContentType /path/to/some.insv   # should report com.insta360.insv

# .osv may report com.light.studio.thumbnail.osv instead — that's DJI
# Studio's exported UTI, which the extension also claims. Both work.
mdls -name kMDItemContentType /path/to/some.osv
```

In Finder: open the folder, wait for thumbnails to render, press Space
on an `.insv` — you should see the dual-fisheye player, not a blue
synthetic icon.

## Uninstall

```bash
APP="$HOME/Library/Application Support/Insta360QL/Insta360QuickLook.app"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -u "$APP"
rm -rf "$APP"
qlmanage -r && qlmanage -r cache
killall Finder
```

## How it works (short version)

The actual macOS bug: **AVFoundation routes by file extension**, not UTI.
`AVURLAsset(url:)` on any path ending in `.insv`/`.lrv`/`.osv`/`.lrf` returns
`-11828 "Cannot Open"` regardless of any UTI declaration. Finder's
`com.apple.quicklook.ThumbnailsAgent` hits this and silently returns
`null` in 0.249s, so no extension ever gets called.

This project's fix has two parts:

1. **Register UTIs and Quick Look extensions** (`UTImportedTypeDeclarations`,
   `Thumbnail.appex` + `Preview.appex` with `QLSupportedContentTypes` for
   `com.insta360.insv` / `com.insta360.insp` / `com.dji.osv`, plus DJI
   Studio's own `com.light.studio.thumbnail.osv`). LaunchServices then
   knows to ask *us* for previews/thumbnails, instead of falling through
   to the default AVFoundation path that rejects these extensions.

2. **Hardlink the file to `<tmp>/<uuid>.mp4`** before handing it to
   AVFoundation — that's how we sidestep the extension-routing bug
   entirely. AVAssetImageGenerator and AVPlayer happily decode the
   hardlink as a regular MP4. Decode time of the first I-frame is
   ~0.1s regardless of file size (works fine on a 2.5 GB HEVC `.insv`).

3. Where the sandbox allows it, prefer the camera's pre-stitched proxy
   over the raw clip — see `src/ProxyResolver.swift`. This is purely a
   UX optimization; we work without it, and on macOS 26.6 we have to.

The full empirical writeup — including 13 specific gotchas that bit
during development (NSExtensionMain recursion on Tahoe, sandbox
sibling-file invisibility, NSISEngine crashes on AVPlayerView resize,
audio teardown timing, etc.) — is in
[`experiments/findings.md`](experiments/findings.md).

## Repo layout

```
insta360-quicklook/
├── build.sh                       # swiftc + iconutil + codesign, ~5s
├── install.sh                     # lsregister + pluginkit + cache reset
├── src/
│   ├── HostInfo.plist             # UTIs, doc types, app metadata
│   ├── Thumbnail{Info,.entitlements,Provider.swift}
│   ├── Preview{Info,.entitlements,ViewController.swift}
│   └── ProxyResolver.swift        # proxy-pair lookup, shared by both
├── icon/
│   ├── make-icon.swift            # generates AppIcon.icns programmatically
│   └── AppIcon.icns               # built artifact (regenerated on demand)
├── experiments/                   # 4 stages of empirical proof
│   ├── README.md
│   ├── findings.md                # 13 gotchas, full empirical record
│   ├── 00-avfoundation-hevc.swift # disprove HEVC pix_fmt hypothesis
│   ├── 01-hardlink-trick.swift    # prove the workaround in plain Swift
│   ├── 02-min-appex/              # smallest possible Thumbnail extension
│   └── 03-preview-appex/          # add Preview, then LRV proxy logic
```

## License

MIT — see [LICENSE](LICENSE).

## Compatibility

| File type | Codec | Status |
|-----------|-------|--------|
| `.insv` (HEVC, ≤ 2 GB) | HEVC 4:2:0 | ✅ thumbnail + preview |
| `.insv` (HEVC, > 2 GB) | HEVC 4:2:0 | ✅ — the original failing case |
| `.insv` (H.264) | H.264 | ✅ |
| `.lrv` | H.264 (camera proxy) | ✅ |
| `.insp` | JPEG | ✅ |
| `.insp` | HEIC (newer firmware) | ✅ via `CGImageSource`, not separately verified |
| `.osv` (DJI Osmo 360) | HEVC, 2 × 3840×3840 | ✅ — shows one lens, see below |
| `.osv` (> 12 GB) | HEVC | ✅ thumbnail in 0.09 s |
| `.lrf` (DJI proxy) | H.264 2048×1024 | ✅ both lenses side-by-side |

Tested on Insta360 X3 / X4 and ONE R footage (10K and 8K HEVC `.insv`
plus the camera-written H.264 LRV proxies), and on DJI Osmo 360 `.osv` /
`.lrf` pairs.

A DJI `.osv` carries the two lenses as **two separate video tracks**
rather than one side-by-side frame, so the thumbnail and preview show
track 0 only. The paired `.lrf` has both lenses in a single track and is
displayed in full.

## Status

v0.1: works on macOS 26.4 and 26.6. Ad-hoc signed (no Developer ID
needed for personal use). Not yet on Homebrew or notarized.

Known limitations:

- Audio briefly continues (~200ms) after closing the QL panel — XPC
  tear-down latency we can't shorten without abandoning AVPlayerView.
- Proxy substitution is inert on macOS 26.6: the sandbox reports sibling
  files as existing but refuses to read them, so we fall back to the
  original clip. Practical effect is one lens instead of two.
- Cross-volume sources work. The hardlink always fails inside the
  extension sandbox (EPERM on its own tmp, not EXDEV) and the symlink
  fallback carries every request, including files on external drives.
- macOS Settings → Login Items & Extensions can show phantom entries
  for previous bundle IDs after multiple installs — they have no
  effect; safe to ignore. Will fade after a reboot.

## Contributing

This is a small personal tool, but issues and PRs are welcome —
particularly for footage from cameras the author doesn't own
(X1 / X2, professional Insta360 Pro / Titan formats, other DJI 360
models), where the file naming and codec brand may differ. See
[`experiments/findings.md`](experiments/findings.md) before debugging
anything Quick Look–related: most surprises are documented there.
