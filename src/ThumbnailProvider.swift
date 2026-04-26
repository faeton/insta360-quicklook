// Thumbnail.appex principal class — generates Finder/QL thumbnails for
// .insv / .lrv (video) and .insp (image) by:
//
//   - .insp  → CGImageSourceCreateThumbnailAtIndex (handles JPEG and HEIC)
//   - .insv  → if a paired LRV proxy exists nearby, prefer it (smaller,
//              H.264, dual-fisheye); otherwise use the .insv itself.
//              Hardlink the chosen source to <tmp>/<uuid>.mp4 so AVFoundation
//              opens it (it routes by extension, not UTI).
//   - .lrv   → same hardlink trick.
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
        let source = ProxyResolver.lrvProxy(for: url) ?? url
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.linkItem(at: source, to: tmp)
        } catch {
            do {
                try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: source)
            } catch {
                handler(nil, error); return
            }
        }
        guard let cg = decode(url: tmp) else {
            handler(nil, NSError(domain: "Insta360QuickLook", code: 3)); return
        }
        handler(makeReply(cg: cg, size: size), nil)
    }

    private func decode(url: URL) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 1024, height: 1024)
        return try? gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
    }

    private func makeReply(cg: CGImage, size: CGSize) -> QLThumbnailReply {
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
            return true
        })
    }
}
