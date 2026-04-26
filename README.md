# Insta360 QuickLook

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)](https://swift.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Tahoe verified](https://img.shields.io/badge/macOS%2026.4-verified-success)]()

Native macOS Quick Look extension that fixes broken Finder previews and
thumbnails for Insta360 files: `.insv`, `.insp`, `.lrv`. Built for
macOS Sequoia (15) and Tahoe (26).

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

- **Thumbnails** in Finder icon view for `.insv`, `.insp`, `.lrv`.
- **Space-press preview** in Finder — full AVPlayerView with timeline,
  play/pause, scrub.
- **LRV proxy substitution.** When you Space an `.insv`, the extension
  finds the camera-written `LRV_*.lrv` proxy alongside it and uses
  *that* as the playback source: smaller (5–10×), H.264 instead of
  HEVC, and pre-stitched dual-fisheye showing both lenses
  simultaneously. Falls back to the raw `.insv` if no LRV is present.
- Works for HEVC `.insv` files larger than 2 GB — the original failing
  case that the underlying macOS bug breaks for everyone.

## Install

Requirements: macOS 13+ (built and tested on Tahoe 26.4), Xcode command
line tools (`xcode-select --install`).

```bash
git clone https://github.com/faeton/insta360-quicklook.git
cd insta360-quicklook
./build.sh && ./install.sh
```

Then enable the extension once:

> **System Settings → General → Login Items & Extensions → Quick Look**
> → toggle ON **Insta360 QuickLook**.

## Verify

```bash
qlmanage -t -s 256 -o /tmp /path/to/some.insv      # CLI thumbnail check
mdls -name kMDItemContentType /path/to/some.insv   # should report com.insta360.insv
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
`AVURLAsset(url:)` on any path ending in `.insv`/`.lrv` returns
`-11828 "Cannot Open"` regardless of any UTI declaration. Finder's
`com.apple.quicklook.ThumbnailsAgent` hits this and silently returns
`null` in 0.249s, so no extension ever gets called.

This project's fix has two parts:

1. **Register UTIs and Quick Look extensions** (`UTImportedTypeDeclarations`,
   `Thumbnail.appex` + `Preview.appex` with `QLSupportedContentTypes` for
   `com.insta360.insv` / `com.insta360.insp`). LaunchServices then knows
   to ask *us* for previews/thumbnails, instead of falling through to
   the default AVFoundation path that rejects `.insv`.

2. **Hardlink the file to `<tmp>/<uuid>.mp4`** before handing it to
   AVFoundation — that's how we sidestep the extension-routing bug
   entirely. AVAssetImageGenerator and AVPlayer happily decode the
   hardlink as a regular MP4. Decode time of the first I-frame is
   ~0.1s regardless of file size (works fine on a 2.5 GB HEVC `.insv`).

3. For Space-press previews, prefer the camera's pre-stitched LRV proxy
   over the raw `.insv` — see `src/ProxyResolver.swift`. This is purely
   a UX optimization; we'd work without it.

The full empirical writeup — including 10 specific gotchas that bit
during development (NSExtensionMain recursion on Tahoe, sandbox
sibling-file invisibility, NSISEngine crashes on AVPlayerView resize,
audio teardown timing, etc.) — is in
[`experiments/findings.md`](experiments/findings.md). The original
plan with the wrong diagnosis is in [`PLAN.md`](PLAN.md), revised
inline with the truth as experiments revealed it.

## Repo layout

```
insta360-quicklook/
├── build.sh                       # swiftc + iconutil + codesign, ~5s
├── install.sh                     # lsregister + pluginkit + cache reset
├── src/
│   ├── HostInfo.plist             # UTIs, doc types, app metadata
│   ├── Thumbnail{Info,.entitlements,Provider.swift}
│   ├── Preview{Info,.entitlements,ViewController.swift}
│   └── ProxyResolver.swift        # LRV-pair lookup, shared by both
├── icon/
│   ├── make-icon.swift            # generates AppIcon.icns programmatically
│   └── AppIcon.icns               # built artifact (regenerated on demand)
├── experiments/                   # 4 stages of empirical proof
│   ├── README.md
│   ├── findings.md                # 10 gotchas, full empirical record
│   ├── 00-avfoundation-hevc.swift # disprove HEVC pix_fmt hypothesis
│   ├── 01-hardlink-trick.swift    # prove the workaround in plain Swift
│   ├── 02-min-appex/              # smallest possible Thumbnail extension
│   └── 03-preview-appex/          # add Preview, then LRV proxy logic
└── PLAN.md                        # original plan, revised with findings
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

Tested on Insta360 X3 / X4 footage (10K and 8K HEVC `.insv` plus the
camera-written H.264 LRV proxies).

## Status

v0.1: works on macOS 26.4. Ad-hoc signed (no Developer ID needed for
personal use). Not yet on Homebrew or notarized.

Known limitations:

- Audio briefly continues (~200ms) after closing the QL panel — XPC
  tear-down latency we can't shorten without abandoning AVPlayerView.
- Cross-volume hardlink fallback (symlink) is exercised in plain Swift
  but not yet through the sandboxed extension code path.
- macOS Settings → Login Items & Extensions can show phantom entries
  for previous bundle IDs after multiple installs — they have no
  effect; safe to ignore. Will fade after a reboot.

## Contributing

This is a small personal tool, but issues and PRs are welcome —
particularly for footage from cameras the author doesn't own
(ONE / X1 / X2, professional Insta360 Pro / Titan formats), where the
file naming and codec brand may differ. See
[`experiments/findings.md`](experiments/findings.md) before debugging
anything Quick Look–related: most surprises are documented there.
