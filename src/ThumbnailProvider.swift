// Thumbnail.appex principal class — generates Finder/QL thumbnails for
// .insv / .lrv / .osv / .lrf (video) and .insp (image) by:
//
//   - .insp  → CGImageSourceCreateThumbnailAtIndex (handles JPEG and HEIC)
//   - .insv  → if a paired LRV proxy exists nearby, prefer it (smaller,
//              H.264, dual-fisheye); otherwise use the .insv itself.
//              Hardlink the chosen source to <tmp>/<uuid>.mp4 so AVFoundation
//              opens it (it routes by extension, not UTI).
//   - .lrv   → same hardlink trick.
//   - .osv   → DJI Osmo 360. Same AVFoundation extension-routing bug, same
//              hardlink trick. Carries two 3840×3840 HEVC tracks, one per
//              lens, so the generator yields a single lens. The paired
//              .lrf would show both, but the sandbox won't let us read it
//              — see ProxyResolver.
//   - .lrf   → DJI's proxy: one 2048×1024 H.264 track, both lenses
//              side-by-side. Same hardlink trick.
//
// See PLAN.md and experiments/findings.md for why each detail is needed.
import QuickLookThumbnailing
import AVFoundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.faeton.insta360quicklook", category: "thumbnail")

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let ext = url.pathExtension.lowercased()
        log.info("invoked \(url.lastPathComponent, privacy: .public)")

        if ext == "insp" {
            handleImage(url: url, size: request.maximumSize, handler: handler)
            return
        }
        handleVideo(url: url, size: request.maximumSize, handler: handler)
    }

    private func handleImage(url: URL, size: CGSize, handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            handler(nil, NSError(domain: "Insta360QuickLook", code: 1)); return
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * 2,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            handler(nil, NSError(domain: "Insta360QuickLook", code: 2)); return
        }
        handler(makeReply(cg: cg, size: size), nil)
    }

    private func handleVideo(url: URL, size: CGSize, handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let source = ProxyResolver.proxy(for: url) ?? url
        if source != url {
            log.info("using proxy \(source.lastPathComponent, privacy: .public)")
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.linkItem(at: source, to: tmp)
        } catch {
            do {
                try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: source)
            } catch {
                log.error("link failed: \(error.localizedDescription, privacy: .public)")
                handler(nil, error); return
            }
        }
        guard let decoded = decode(url: tmp) else {
            log.error("decode failed for \(source.lastPathComponent, privacy: .public)")
            handler(nil, NSError(domain: "Insta360QuickLook", code: 3)); return
        }
        let ext = url.pathExtension.lowercased()
        let badge = ["insv", "lrv", "osv", "lrf"].contains(ext)
        handler(makeReply(cg: decoded.image, size: size, overlay: decoded.info, badge: badge), nil)
    }

    private func decode(url: URL) -> (image: CGImage, info: String?)? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 1024, height: 1024)
        // Sync decode — we're called from Finder for every visible icon.
        // The async replacement gen.image(at:) is markedly slower at scale.
        // Tolerate the macOS 15 deprecation here for the throughput it buys.
        guard let cg = try? gen.copyCGImage(
            at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        else { return nil }
        return (cg, videoInfo(asset: asset))
    }

    private func videoInfo(asset: AVURLAsset) -> String? {
        var parts: [String] = []
        if let dur = Self.syncAwait({ CMTimeGetSeconds(try await asset.load(.duration)) }),
           dur.isFinite, dur > 0
        {
            let total = Int(dur.rounded())
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            parts.append(h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                               : String(format: "%d:%02d", m, s))
        }
        if let label = Self.syncAwait({ () -> String? in
            guard let track = try await asset.loadTracks(withMediaType: .video).first
            else { return nil }
            let fmts = try await track.load(.formatDescriptions)
            guard let fmt = fmts.first else { return nil }
            let code = CMFormatDescriptionGetMediaSubType(fmt)
            let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                         UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
            let raw = String(bytes: bytes, encoding: .ascii) ?? ""
            switch raw {
            case "hvc1", "hev1": return "HEVC"
            case "avc1":         return "H.264"
            default:             return raw.isEmpty ? nil : raw.uppercased()
            }
        }) ?? nil {
            parts.append(label)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    // Sync bridge to async AV APIs. Tight timeout — info overlay is a
    // nicety, not worth stalling Finder if AVFoundation is slow on a file.
    private static func syncAwait<T>(_ work: @escaping () async throws -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var out: T?
        Task.detached {
            defer { sem.signal() }
            out = try? await work()
        }
        _ = sem.wait(timeout: .now() + 0.5)
        return out
    }

    private func makeReply(cg: CGImage, size: CGSize, overlay: String? = nil, badge: Bool = false) -> QLThumbnailReply {
        QLThumbnailReply(contextSize: size, currentContextDrawing: {
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
            if size.height >= 96 {
                if let text = overlay { drawOverlay(text: text, frameSize: size) }
                if badge { drawBadge(frameSize: size) }
            }
            return true
        })
    }
}

// File-scope helpers — kept out of the class so the QLThumbnailReply drawing
// closure doesn't have to capture self.

private func drawOverlay(text: String, frameSize: CGSize) {
    let fontSize = max(11, min(22, frameSize.height * 0.07))
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 2
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: NSColor.white,
        .shadow: shadow,
    ]
    let astr = NSAttributedString(string: text, attributes: attrs)
    let tsize = astr.size()
    let padX: CGFloat = max(8, fontSize * 0.6)
    let padY: CGFloat = max(4, fontSize * 0.3)
    let barH = ceil(tsize.height) + padY * 2
    let barW = min(frameSize.width - 12, ceil(tsize.width) + padX * 2)
    let bar = CGRect(x: (frameSize.width - barW) / 2,
                     y: max(6, frameSize.height * 0.025),
                     width: barW, height: barH)
    NSColor.black.withAlphaComponent(0.78).setFill()
    NSBezierPath(roundedRect: bar, xRadius: barH / 2, yRadius: barH / 2).fill()
    astr.draw(at: CGPoint(x: bar.minX + (bar.width - tsize.width) / 2,
                          y: bar.minY + padY))
}

private func drawBadge(frameSize: CGSize) {
    let diameter = max(28, min(64, frameSize.height * 0.18))
    let margin = max(6, frameSize.height * 0.03)
    let rect = CGRect(x: frameSize.width - diameter - margin,
                      y: frameSize.height - diameter - margin,
                      width: diameter, height: diameter)
    let path = NSBezierPath(ovalIn: rect)
    NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.95, alpha: 0.92).setFill()
    path.fill()
    NSColor.white.withAlphaComponent(0.85).setStroke()
    path.lineWidth = max(1, diameter * 0.04)
    path.stroke()

    let fontSize = diameter * 0.42
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
        .foregroundColor: NSColor.white,
    ]
    let astr = NSAttributedString(string: "360°", attributes: attrs)
    let tsize = astr.size()
    astr.draw(at: CGPoint(x: rect.midX - tsize.width / 2,
                          y: rect.midY - tsize.height / 2))
}
