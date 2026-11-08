# Findings — what experiments revealed about the real problem

## TL;DR (after exp 00 + exp 01 + exp 02)

PLAN.md's diagnosis was **wrong on the cause** but the architecture (own
QuickLook extension) is still right. Real cause + working solution:

### Why Finder fails on `.insv`

1. AVFoundation refuses to open files whose extension is `.insv` / `.lrv`
   regardless of UTI declaration — returns `AVFoundationErrorDomain -11828
   "Cannot Open"`. Routes by extension, not UTI. **Not** a HEVC-pix_fmt issue.
2. Finder's Space-press calls `com.apple.quicklook.ThumbnailsAgent`, which
   internally tries the standard AVFoundation path on the source URL, gets
   -11828, and returns `null` in 0.249s without invoking any extension.
3. CLI `qlmanage -t` follows a different code path that succeeds (which
   misled the original diagnosis into blaming HEVC).
4. Finder shows Insta360 Studio's `DocumentIcon1.icns` because the document
   type has an icon assigned by the LaunchServices claim from Studio, and
   that icon is what bleeds through when no thumbnail is produced.

### Working workaround (verified end-to-end)

Hardlink the source file to `<tmp>/<uuid>.mp4`, point AVAssetImageGenerator
at the hardlink. AVAsset opens it instantly, decodes the first I-frame in
~0.1s regardless of file size. Verified on:

- HEVC `.insv` 677 MB
- HEVC `.insv` 2.5 GB (was the primary failing case)
- H.264 `.insv`
- H.264 `.lrv`

Hardlink works because all test files live on the same volume as `/tmp`. For
cross-volume cases fall back to symlink.

**Update (macOS 26.6):** inside the extension sandbox the hardlink *always*
fails — `EPERM` on the extension's own `temporaryDirectory`, not `EXDEV`,
and on internal volumes too. The symlink fallback therefore carries every
request, and it works: the sandbox token issued for the file Quick Look
handed us covers the path the symlink resolves to. Verified on a 12 GB
`.osv` on an external volume (0.09 s). See gotcha 11 for the case this
does *not* cover.

## Build pitfalls discovered (Tahoe-specific)

These bit us hard — none documented, all required experiments to find:

### 1. Entry point recursion (CRITICAL)

`swiftc -emit-executable` of a Swift file with a top-level statement calling
`NSExtensionMain()` causes infinite recursion on Tahoe (macOS 26.4).
Stack trace: `main → NSExtensionMain → EXExtensionMain →
_EXRunningExtension._start → main → ...` until SIGSEGV at depth ~9000.

ExtensionFoundation framework now drives extension bootstrap, and the
`NSExtensionMain` shim ends up re-invoking the Mach-O entry point. The
entry must be `_NSExtensionMain` directly, not a Swift `main`.

Fix: pass `-Xlinker -e -Xlinker _NSExtensionMain` to swiftc and **do not
include any main.swift / top-level statements**. Add `-application-extension`
to suppress related warnings.

### 2. NSExtensionPrincipalClass needs module prefix

For Swift extensions: `Module.ClassName` (e.g. `Thumbnail.ThumbnailProvider`),
not just `ClassName`. Different from Apple's BooksThumbnail.appex which is
ObjC and uses just `ThumbnailProvider`. QLMarkdown reference confirms
`Markdown_QL_Extension.PreviewViewController` pattern.

### 3. UTImportedTypeDeclarations vs UTExportedTypeDeclarations

For UTIs we don't own (`com.insta360.insv` is Insta360's namespace), use
**Imported**. Verified: appears with `imported` flag in `lsregister -dump`,
mdls reports correct `kMDItemContentType`, and ThumbnailsAgent invokes
our extension correctly.

### 4. Ad-hoc signing works

Sandbox container is created (`~/Library/Containers/<bundle-id>/Data`),
sandbox extensions consumed (`quicklook-thumbnail` profile + entitlements).
`signer:none` warning in secinitd is non-fatal. Extension is invoked,
provided thumbnail rendered. No Developer ID needed for personal use.

### 5. pluginkit -p filter is broken

`pluginkit -mAvvv -p com.apple.quicklook.thumbnail` returns no matches
even though extensions for that point exist (Apple's BooksThumbnail,
ours). Always use `pluginkit -mAvvv | grep <bundle-id>` instead.

### 6. Caches need explicit nuking on extension change

After rebuild + reinstall, ThumbnailsAgent caches old extension state.
Sequence that worked:

```bash
qlmanage -r
qlmanage -r cache
killall -9 com.apple.quicklook.ThumbnailsAgent
killall Finder
pluginkit -a "$APPEX"
# user must toggle off+on the extension in Settings → Extensions → Quick Look
```

### 7. ExtensionsPoint discovery via `pluginkit -a`

Just `lsregister -f` is not enough — must run `pluginkit -a <appex-path>`
to register the extension under its NSExtensionPointIdentifier. Otherwise
the extension is in lsregister but ThumbnailsAgent doesn't know about it.

## Killed gospel (from PLAN.md)

- "HEVC pix_fmt=yuvj420p banned by quicklookd" — false. CLI thumbnailer
  decodes HEVC `.insv` of any size fine. Same with our extension.
- "Insta360 Studio's bundled QuickLookHost.appex was hijacking previews" —
  pluginkit confirms it's never registered. Studio is innocent.
- "Need ffmpeg fallback because of HEVC quirk" — not needed at all.
  Native AVFoundation works once we feed it a `.mp4`-named path.
- "QLPreviewReply(fileURL:contentType:)" — does not exist in macOS 26.4 SDK.
  Available: initWithFileURL:, initWithContextSize:isBitmap:drawingBlock:,
  initWithDataOfContentType:..., initForPDFWithPageSize:. View-based preview
  via NSViewController + QLPreviewingController is the right path for video.

## What works now (exp 02)

A QL Thumbnail extension that:

1. Receives the file URL from QuickLookThumbnailing.
2. Creates a hardlink at `<tmp>/<uuid>.mp4` (falls back to symlink).
3. Calls `AVAssetImageGenerator` on the hardlink (~0.1s).
4. Returns the rendered frame via `QLThumbnailReply`.
5. Cleans up the hardlink in `defer`.

For `.insp` images, uses `CGImageSourceCreateThumbnailAtIndex` directly
on the original URL (extension-route doesn't matter for ImageIO).

When user presses Space in Finder, ThumbnailsAgent invokes our thumbnail
provider and shows a static frame in the QL window. **This is not a real
video preview** — there's no playback, no timeline, no scrubbing. For that
we need the Preview extension.

## What works now (after exp 03)

End-to-end Quick Look stack proven on Tahoe (macOS 26.4.1):

- Thumbnail extension generates real frames in Finder for all `.insv`/`.lrv`/`.insp`.
- Preview extension plays video on Space-press with full AVPlayerView controls
  (timeline, play/pause, scrub).
- LRV proxy substitution: when user opens `VID_<ts>_NN_<idx>.insv`, the
  extension probes for the paired `LRV_<ts>_<NN+1>_<idx>.lrv` (Insta360
  conventionally writes proxy as sensor `01` against video sensor `00`).
  If found, it's used as the AVPlayer source — much smaller (5–10×), H.264
  instead of HEVC, and pre-stitched dual-fisheye showing both cameras.
  Falls back to the .insv itself if no LRV is present.
  **On macOS 26.6 this only works on the boot volume — see gotcha 11.**

## More gotchas discovered in exp 03

### 8. Sandbox app extension cannot see sibling files

`com.apple.security.files.user-selected.read-only` only grants access to
the file QuickLook hands the extension — `fileExists(atPath:)` on a
sibling path returns false even when the file is right there. Result:
LRV-proxy lookup silently failed, fell through to `.insv` which AVPlayer
can't open, plug-in showed empty player with `--:--`.

Fix: add the same temporary-exception entitlement QLMarkdown uses —
`com.apple.security.temporary-exception.files.absolute-path.read-only`
with value `["/"]`. This grants read-only access to the whole filesystem
without needing a Developer ID / TCC prompt. With this entitlement the
hardlink trick also works on sibling files (LRV) which were never
user-selected.

This is a temporary-exception entitlement, but ad-hoc-signed extensions
*can* use it (verified). It would normally need App Review for App Store
distribution.

**Superseded on macOS 26.6 — see gotcha 11.**

### 9. AVPlayerView + autoresizingMask = NSISEngine crash

`AVPlayerView` with `autoresizingMask = [.width, .height]` on a layer-backed
view inside QL panel triggers `NSISEngine handleUnsatisfiableRow` exception
on resize, killing the extension intermittently. Use Auto Layout
constraints (`translatesAutoresizingMaskIntoConstraints = false` +
explicit anchors against the parent view) instead.

### 10. Audio teardown on QL close

`viewWillDisappear` on the `QLPreviewingController` does fire when QL
panel closes, but `player.pause()` alone leaves the audio buffer playing
through CoreAudio for ~500–1000ms. Solution that actually mutes immediately:

```swift
player?.volume = 0
player?.pause()
player?.replaceCurrentItem(with: nil)
playerView?.player = nil
```

Even with all this, on Tahoe a brief audio tail (~200ms) still leaks past
the panel close. Likely because XPC tear-down of the extension process
flushes whatever audio frames CoreAudio has already pulled. Acceptable
for v1; if more aggressive teardown is needed, would have to abandon
AVPlayerView for a fully custom player+layer where we control the
AVAudioOutput stack directly.

## Gotchas discovered adding DJI Osmo 360 (macOS 26.6.2)

### 11. The sibling-file entitlement no longer works

Gotcha 8's fix has stopped working. With
`com.apple.security.temporary-exception.files.absolute-path.read-only`
set to `["/"]`, a sibling proxy now reports `fileExists == true` but
`isReadableFile == false`. Adding `/Volumes/` to the array changes
nothing, and the behaviour is identical on internal and external volumes,
so it is not a removable-media TCC issue — the entitlement simply no
longer covers files Quick Look didn't hand us.

**Correction (v0.2.0-beta.1, macOS 26.6.2, tested by @muuksi in #1):** with
the shipping v0.2 entitlements the result depends on the volume. Same `.OSV`,
`.LRF` next to it both times:

| location | result |
|---|---|
| external SSD | HEVC, one lens — proxy rejected |
| boot volume | H.264, both lenses — proxy read |
| boot volume, no `.LRF` | HEVC, one lens — clean fallback |

The external run is byte-identical to the run with no `.LRF`, so the proxy
is discarded there, not misread. The likeliest cause is that the `["/"]`
read exception doesn't extend across mount points, and the security scope
Quick Look grants covers only the file it handed us. The paragraphs below
describe the original 26.6 measurement, which found it dead on both volume
types; treat "dead" as "dead off the boot volume".

Consequence: proxy substitution is unreliable on this OS for both brands.
Worse, it is dead in a way that *breaks* working thumbnails — swapping a
decodable source (the file we were given) for an undecodable one (a
sibling we cannot read) makes the extension return nothing at all, where
doing nothing would have worked.

`ProxyResolver` therefore probes with `isReadableFile`, not `fileExists`,
and treats "not readable" as "no proxy" so callers fall back to the
original file.

### 12. DJI Studio already claims `.osv` / `.lrf`

`.osv` and `.lrf` do not resolve to a newly imported UTI. They resolve to
`com.light.studio.thumbnail.osv`, exported by
`DJI Studio.app/Contents/PlugIns/DJIStudioQuickLookHost.app`. Exported
beats imported, so our declaration loses.

The claim also survives as a stale LaunchServices record after DJI Studio
is uninstalled — verified on a machine where the app no longer exists but
the binding does. Listing both UTIs in `QLSupportedContentTypes` covers
machines with and without Studio.

Symptom: `QLThumbnailGenerator` returns `.icon` instead of `.thumbnail`
in ~0.01 s and the extension log stays empty — it is never invoked.

### 13. `pluginkit -e use` enables extensions without System Settings

The install instructions say the Quick Look toggle must be flipped by
hand. It doesn't:

```bash
pluginkit -e use -i com.faeton.insta360quicklook.thumbnail
pluginkit -e use -i com.faeton.insta360quicklook.preview
pluginkit -m -A -v | grep insta360    # "+" in column 1 means enabled
```

Needed again after every reinstall, since the appex gets a new UUID.

### 14. Without a type declaration, `.insv` is `public.data` on 26.6 (#4)

v0.2 declares no types and claims the `dyn.*` IDs instead (73de735). On
macOS 27.2 that works: `UTType(filenameExtension: "insv")` is
`dyn.ah62d4rv4ge80w5xxs2`. On 26.6.2 ThumbnailsAgent types the same file as
`public.data` ("Did not find any extension matching content type:
public.data"), so neither our extension nor anything else is invoked.
`mdls` disagrees with ThumbnailsAgent here; trust the ThumbnailsAgent log.

Insta360 Studio 6.0.7 has the same shape: its extensions claim the same
`dyn.*` IDs, and it lists `insv`/`insp` only under `CFBundleDocumentTypes`.
A baseline on 26.6.2 with no build of ours ever installed confirmed it gives
**no** thumbnails there: `.insv` and `.insp` both come back as `icon`. DJI
Studio exports `com.light.studio.thumbnail.osv`, so `.osv`/`.lrf` are fine.

So on 26.6 importing the types costs Studio nothing. Studio's thumbnails and
preview only depend on the file staying `dyn.*` where `dyn.*` is what the OS
resolves to.

## Open risks for v2 / production

- **Proxy substitution only works on the boot volume on macOS 26.6** — see
  gotcha 11. Off it, the feature degrades silently: `.insv` shows one lens
  and `.osv` shows one of its two tracks.
- **HEIC `.insp`** — `CGImageSource` handles JPEG and HEIC transparently,
  no extra logic needed.
- **Insta360 Studio's `DocumentIcon1.icns` claim** — may compete with
  our thumbnail in some Finder views. Empirically our extension wins
  now; track over time.
- **Audio tail on close (~200ms)** — see gotcha 10.
- **Settings shows phantom old extensions** after rebuilds with new bundle
  IDs (e.g. exp02 zombie). `lsregister -kill -seed` was removed in macOS
  Sonoma; phantom records persist until natural LS rebuild. Production
  bundle should keep a stable bundle ID forever to avoid this.
