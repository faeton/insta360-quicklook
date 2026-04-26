import QuickLookThumbnailing
import AVFoundation
import AppKit
import OSLog
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.faeton.insta360ql.exp03", category: "thumbnail")

@objc(ThumbnailProvider)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let url = request.fileURL
        let ext = url.pathExtension.lowercased()
        log.info("invoked \(url.lastPathComponent, privacy: .public) ext=\(ext, privacy: .public)")

        if ext == "insp" {
            handleImage(url: url, size: request.maximumSize, handler: handler)
            return
        }
        handleVideo(url: url, size: request.maximumSize, handler: handler)
    }

    private func handleImage(url: URL, size: CGSize, handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            handler(nil, NSError(domain: "Insta360QL", code: 1)); return
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height) * 2,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            handler(nil, NSError(domain: "Insta360QL", code: 2)); return
        }
        handler(makeReply(cg: cg, size: size), nil)
    }

    private func handleVideo(url: URL, size: CGSize, handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // Prefer the LRV proxy alongside .insv: smaller, H.264, faster decode.
        let source = Self.lrvProxy(for: url) ?? url
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
            handler(nil, NSError(domain: "Insta360QL", code: 3)); return
        }
        handler(makeReply(cg: cg, size: size), nil)
    }

    private static func lrvProxy(for url: URL) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("VID_") else { return nil }
        let rest = String(name.dropFirst(4))
        let parts = rest.split(separator: "_")
        guard parts.count >= 4 else { return nil }
        let stampPrefix = parts[0..<2].joined(separator: "_")
        let trailingIdx = parts.last!
        let dir = url.deletingLastPathComponent()
        for sensor in ["01", "02", "00"] {
            let candidate = dir.appendingPathComponent(
                "LRV_\(stampPrefix)_\(sensor)_\(trailingIdx).lrv")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
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
