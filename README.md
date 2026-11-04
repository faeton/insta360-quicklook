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

> [!WARNING]
> **v0.1 conflicts with Insta360 Studio's own Quick Look plugin.** It
> declares its own file types for `.insv`, `.insp` and `.lrv`, and in
> testing with Studio 6.0.7 that stopped Studio's preview from launching.
> **If you have Studio 5.6.1 or later, use its plugin and don't install
> this.** The Homebrew cask is disabled for this reason. If v0.1 is already
> installed, see [Uninstall](#uninstall). A future release is planned to
> coexist with Studio and to serve Macs without it.

> **Why this exists:** without a Quick Look handler, pressing Space on an
> `.insv` in Finder shows nothing — generic blue INSV icon, no playback.
> macOS doesn't recognize the extension, and AVFoundation refuses to open
> `.insv`/`.lrv` even after declaring them as `public.mpeg-4`. This
> extension handles all of that with no reliance on Studio.

## What you get

- **Thumbnails** in Finder icon view for `.insv`, `.insp`, `.lrv`,
  with a duration · codec pill and a "360°" badge in the corner so
  Insta360 footage stands out at a glance in mixed folders.
- **Space-press preview** in Finder — full AVPlayerView with timeline,
  play/pause, scrub. A HUD bar at the top of the panel shows capture
  date, time, **timezone**, resolution, codec, duration, and file
  size.
- **Capture-time timezone recovery.** Insta360 doesn't write a
  TZ-aware ISO creation date, but the `mvhd` atom holds the absolute
  UTC moment while the filename holds the local wall clock. Their
  delta is the offset — a Tahiti shoot opened on a Berlin laptop
  still reads `08:45 GMT-10:00`, not the current TZ.
- **LRV proxy substitution.** When you Space an `.insv`, the extension
  finds the camera-written `LRV_*.lrv` proxy alongside it and uses
  *that* as the playback source: smaller (5–10×), H.264 instead of
  HEVC, and side-by-side fisheye showing both lenses simultaneously
  (not stitched). Falls back to the raw `.insv` if no LRV is present.
- Works for HEVC `.insv` files larger than 2 GB — the original failing
  case that the underlying macOS bug breaks for everyone.

## Install

Requirements: macOS 13+ (built and tested on Tahoe 26.4).

Read the [warning above](#insta360-quicklook) first: install v0.1 only on
a Mac without Insta360 Studio. The Homebrew cask is disabled and now refuses
to install.

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

## Verify

```bash
qlmanage -t -s 256 -o /tmp /path/to/some.insv      # CLI thumbnail check
mdls -name kMDItemContentType /path/to/some.insv   # should report com.insta360.insv
```

In Finder: open the folder, wait for thumbnails to render, press Space
on an `.insv` — you should see the dual-fisheye player, not a blue
synthetic icon.

## Uninstall

If you installed with Homebrew, try this first:

```bash
brew uninstall --cask insta360-quicklook
```

Then run this for any install, including one from source or the release
zip. It removes every standard install location and is safe to run if a
copy isn't there:

```bash
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
for APP in "/Applications/Insta360QuickLook.app" \
           "$HOME/Library/Application Support/Insta360QL/Insta360QuickLook.app"; do
  "$LSREG" -u "$APP" 2>/dev/null
  rm -rf "$APP"
done
qlmanage -r && qlmanage -r cache
killall Finder
```

A built copy left inside a source checkout (`./Insta360QuickLook.app`, or
under `experiments/`) also keeps its file types registered, so unregister and
delete it the same way, or delete the checkout. To check the result:

```bash
"$LSREG" -dump | grep -c 'com.insta360.insv'   # should print 0
```

If you use Studio's plugin and its preview still doesn't appear, check
**System Settings → General → Login Items & Extensions → QuickLookHost**.

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

3. For Space-press previews, prefer the camera's LRV proxy (side-by-side
   fisheye, not stitched) over the raw `.insv` — see `src/ProxyResolver.swift`. This is purely
   a UX optimization; we'd work without it.

The full empirical writeup — including 10 specific gotchas that bit
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

v0.1: works on macOS 26.4. Ad-hoc signed, not notarized, so Gatekeeper
rejects it. The Homebrew cask is disabled because v0.1 conflicts with Insta360
Studio's plugin.

Known limitations:

- Conflicts with Insta360 Studio's Quick Look plugin (see the warning at
  the top).
- LRV proxy substitution may not work on current macOS: a contributor
  reports the sandbox refusing to read sibling files on 26.6
  ([#1](https://github.com/faeton/insta360-quicklook/pull/1)). Not yet
  reproduced here.
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
