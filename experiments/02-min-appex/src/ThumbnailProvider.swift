// Minimal Thumbnail.appex provider — proves three things at once:
//   1. ad-hoc-signed appex registers via lsregister and is discovered by Finder
//   2. sandbox lets us hardlink the source file into our temp dir
//   3. AVAssetImageGenerator on the hardlink works inside the extension sandbox
//
// All decisions logged to os_log subsystem com.faeton.insta360ql.exp02 so we can
// see in `log stream` whether Finder ever calls us.

import QuickLookThumbnailing
import AVFoundation
import AppKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.faeton.insta360ql.exp02", category: "thumbnail")

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let ext = url.pathExtension.lowercased()
        log.info("invoked for \(url.lastPathComponent, privacy: .public) ext=\(ext, privacy: .public) size=\(request.maximumSize.width)x\(request.maximumSize.height)")

        if ext == "insp" {
            handleImage(url: url, size: request.maximumSize, handler: handler)
            return
        }
        handleVideo(url: url, size: request.maximumSize, handler: handler)
    }

    private func handleImage(url: URL, size: CGSize, handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            log.error("CGImageSourceCreateWithURL nil for \(url.path, privacy: .public)")
            handler(nil, NSError(domain: "Insta360QL", code: 1))
            return
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * 2,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            log.error("CGImageSourceCreateThumbnail nil")
            handler(nil, NSError(domain: "Insta360QL", code: 2))
            return
        }
        log.info("insp thumbnail \(cg.width)x\(cg.height)")
        handler(makeReply(cg: cg, size: size), nil)
    }

    private func handleVideo(url: URL, size: CGSize, handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // Try direct first — if some future macOS routes by UTI it'll work
        if let cg = tryDecode(url: url) {
            log.info("direct decode worked")
            handler(makeReply(cg: cg, size: size), nil)
            return
        }
        // Hardlink trick
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.linkItem(at: url, to: tmp)
            log.info("hardlinked to \(tmp.lastPathComponent, privacy: .public)")
        } catch {
            log.warning("hardlink failed (\(error.localizedDescription, privacy: .public)) — trying symlink")
            do {
                try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: url)
            } catch {
                log.error("symlink also failed: \(error.localizedDescription, privacy: .public)")
                handler(nil, error)
                return
            }
        }
        guard let cg = tryDecode(url: tmp) else {
            log.error("AVAsset failed even on hardlinked .mp4")
            handler(nil, NSError(domain: "Insta360QL", code: 3))
            return
        }
        log.info("hardlinked decode \(cg.width)x\(cg.height)")
        handler(makeReply(cg: cg, size: size), nil)
    }

    private func tryDecode(url: URL) -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: 1024, height: 1024)
        do {
            return try gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
        } catch {
            log.warning("decode failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func makeReply(cg: CGImage, size: CGSize) -> QLThumbnailReply {
        return QLThumbnailReply(contextSize: size, currentContextDrawing: {
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
