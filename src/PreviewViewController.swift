// Preview.appex principal class — view-based QuickLook previewer.
//
//   - .insp  → CGImageSource → CALayer with the bitmap.
//   - .insv  → if paired LRV proxy exists, use it (smaller, dual-fisheye,
//              both lenses). Otherwise the .insv itself.
//              Hardlink to <tmp>/<uuid>.mp4 (AVFoundation routes by file
//              extension; .insv triggers -11828 "Cannot Open"). AVPlayer
//              against the hardlink, mounted in an AVPlayerView.
//
// Lifetime: the hardlink must outlive the AVPlayer. Stored as a property
// and torn down in viewWillDisappear (deinit fires too late for audio).
import QuickLookUI
import AVFoundation
import AVKit
import AppKit
import OSLog

private let log = Logger(subsystem: "com.faeton.insta360quicklook", category: "preview")

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var hardlinkURL: URL?
    private var player: AVPlayer?
    private var playerView: AVPlayerView?
    private var infoBar: NSView?
    private var infoLabel: NSTextField?

    override func loadView() {
        // Bare layer-backed container; QL panel sizes us via constraints.
        // Don't set an intrinsic size — it conflicts with QL chrome.
        let v = NSView()
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.backgroundColor = NSColor.black.cgColor
        self.view = v
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let ext = url.pathExtension.lowercased()
        log.info("preparePreview \(url.lastPathComponent, privacy: .public)")

        if ext == "insp" {
            attachImage(url: url)
            handler(nil)
            return
        }

        let source = ProxyResolver.lrvProxy(for: url) ?? url
        if source != url {
            log.info("using LRV proxy \(source.lastPathComponent, privacy: .public)")
        }

        do {
            let h = try Self.makeHardlink(of: source)
            self.hardlinkURL = h
            attachPlayer(hardlink: h, originalURL: url)
            handler(nil)
        } catch {
            log.error("hardlink failed: \(error.localizedDescription, privacy: .public)")
            handler(error)
        }
    }

    private func attachPlayer(hardlink: URL, originalURL: URL) {
        let asset = AVURLAsset(url: hardlink)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        self.player = p

        let pv = AVPlayerView()
        // Auto Layout — NOT autoresizingMask. AVPlayerView's intrinsic
        // constraints crash NSISEngine on resize when mixed with springs.
        pv.translatesAutoresizingMaskIntoConstraints = false
        pv.controlsStyle = .inline
        pv.showsFullScreenToggleButton = false
        pv.player = p
        view.addSubview(pv)
        NSLayoutConstraint.activate([
            pv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pv.topAnchor.constraint(equalTo: view.topAnchor),
            pv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.playerView = pv

        // Show empty info bar synchronously, fill text asynchronously so
        // metadata reads never delay the QL panel from appearing.
        installInfoBar(text: " ")
        let label = self.infoLabel
        Task.detached {
            let text = Self.videoInfoString(originalURL: originalURL, playbackAsset: asset)
            await MainActor.run { label?.stringValue = text }
        }

        p.play()
    }

    nonisolated private static func videoInfoString(originalURL: URL, playbackAsset: AVURLAsset) -> String {
        var parts: [String] = []

        // Codec + resolution should reflect the ORIGINAL .insv, not the LRV
        // proxy. AVFoundation refuses to open .insv by extension, so we
        // hardlink it to a throwaway .mp4 just to read tracks/formatDescriptions.
        let metaAsset: AVURLAsset
        var metaTmp: URL?
        if originalURL.path == playbackAsset.url.path {
            metaAsset = playbackAsset
        } else if let tmp = try? Self.makeHardlink(of: originalURL) {
            metaTmp = tmp
            metaAsset = AVURLAsset(url: tmp)
        } else {
            metaAsset = playbackAsset
        }
        defer { if let t = metaTmp { try? FileManager.default.removeItem(at: t) } }

        if let stamp = Self.captureStamp(originalURL: originalURL, asset: metaAsset) {
            parts.append(stamp)
        }

        let track = Self.syncLoadVideoTrack(asset: metaAsset)
        if let (w, h) = track?.size, w > 0 && h > 0 {
            parts.append("\(w)×\(h)")
        }
        if let codec = track?.codec { parts.append(codec) }

        if let dur = Self.syncLoadDuration(asset: playbackAsset), dur > 0 {
            let total = Int(dur.rounded())
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            parts.append(h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                               : String(format: "%d:%02d", m, s))
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: originalURL.path),
           let bytes = attrs[.size] as? NSNumber {
            let f = ByteCountFormatter()
            f.countStyle = .file
            parts.append(f.string(fromByteCount: bytes.int64Value))
        }

        return parts.joined(separator: "  ·  ")
    }

    private func installInfoBar(text: String) {
        let bar = NSVisualEffectView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 6
        bar.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1

        bar.addSubview(label)
        view.addSubview(bar)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            bar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
        ])
        self.infoBar = bar
        self.infoLabel = label
    }

    private func attachImage(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            log.error("CGImageSource nil")
            return
        }
        let imageLayer = CALayer()
        imageLayer.contents = cg
        imageLayer.frame = view.bounds
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(imageLayer)
    }

    // Insta360 writes the capture time twice:
    //   - QuickTime mvhd creation_time (UTC, per ISO 14496-12 spec)
    //   - Filename VID_YYYYMMDD_HHMMSS_* (local wall clock, no TZ)
    // Their difference IS the capture-time TZ offset. Recover it.
    nonisolated private static func captureStamp(originalURL: URL, asset: AVURLAsset) -> String? {
        let mvhd = mvhdUTCDate(asset: asset)
        let filename = filenameNaiveDate(originalURL: originalURL)

        if let mvhd, let fnUTC = filename {
            // mvhd is the absolute UTC moment; filename is naive local wall
            // clock parsed as if UTC. Their delta is the capture-time offset.
            let step: TimeInterval = 900   // round to 15-min slots
            let raw = fnUTC.timeIntervalSince(mvhd)
            let offset = Int((raw / step).rounded() * step)
            if abs(offset) <= 14 * 3600, let tz = TimeZone(secondsFromGMT: offset) {
                return formatStamp(mvhd, tz: tz, showTZ: true)
            }
        }
        if let fnUTC = filename {
            // Display the wall-clock as-is. Reinterpret in current TZ purely
            // so DateFormatter prints the same hh:mm we read from the name.
            return formatStamp(reinterpretInCurrentTZ(fnUTC), tz: .current, showTZ: false)
        }
        if let mvhd { return formatStamp(mvhd, tz: .current, showTZ: true) }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: originalURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            return formatStamp(mtime, tz: .current, showTZ: true)
        }
        return nil
    }

    // Sync bridges to async AVAsync APIs. Tahoe deprecated all sync getters;
    // we're called from a QL background queue, so blocking via semaphore is
    // safe. 2-second timeout matches what hardlinked local files need.
    nonisolated private static func syncAwait<T>(_ work: @escaping () async throws -> T) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var out: T?
        Task.detached {
            defer { sem.signal() }
            out = try? await work()
        }
        _ = sem.wait(timeout: .now() + 2.0)
        return out
    }

    nonisolated private static func syncLoadVideoTrack(asset: AVURLAsset)
        -> (size: (Int, Int), codec: String?)?
    {
        return syncAwait {
            guard let track = try await asset.loadTracks(withMediaType: .video).first
            else { return nil }
            let (rawSize, transform, fmts) = try await track.load(
                .naturalSize, .preferredTransform, .formatDescriptions)
            let r = rawSize.applying(transform)
            let size = (Int(abs(r.width)), Int(abs(r.height)))
            var codec: String?
            if let fmt = fmts.first {
                let code = CMFormatDescriptionGetMediaSubType(fmt)
                let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                             UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
                let raw = String(bytes: bytes, encoding: .ascii) ?? ""
                switch raw {
                case "hvc1", "hev1": codec = "HEVC"
                case "avc1":         codec = "H.264"
                default:             codec = raw.isEmpty ? nil : raw.uppercased()
                }
            }
            return (size, codec)
        } ?? nil
    }

    nonisolated private static func syncLoadDuration(asset: AVURLAsset) -> TimeInterval? {
        return syncAwait {
            CMTimeGetSeconds(try await asset.load(.duration))
        }
    }

    // AVFoundation doesn't expose mvhd creation_time via commonMetadata for
    // these files. Parse it directly: walk top-level atoms, descend into
    // 'moov', find 'mvhd', read creation_time (seconds since 1904-01-01 UTC).
    nonisolated private static func mvhdUTCDate(asset: AVURLAsset) -> Date? {
        guard let fh = try? FileHandle(forReadingFrom: asset.url) else { return nil }
        defer { try? fh.close() }

        // Insta360 writes moov at the END of the file, after a multi-GB mdat.
        // Walk top-level atoms (only 8-byte reads each) until we find moov.
        let scanLimit: UInt64 = (try? fh.seekToEnd()) ?? 0
        var pos: UInt64 = 0
        while pos < scanLimit {
            try? fh.seek(toOffset: pos)
            guard let header = try? fh.read(upToCount: 8), header.count == 8 else { return nil }
            let size32 = header.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            var bodyStart = pos + 8
            var atomEnd: UInt64
            if size32 == 1 {
                guard let ext = try? fh.read(upToCount: 8), ext.count == 8 else { return nil }
                let size64 = ext.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                bodyStart = pos + 16
                atomEnd = pos + size64
            } else if size32 == 0 {
                atomEnd = scanLimit
            } else {
                atomEnd = pos + UInt64(size32)
            }

            if type == "moov" {
                return scanForMVHD(fh: fh, start: bodyStart, end: atomEnd)
            }
            if atomEnd <= pos { return nil }
            pos = atomEnd
        }
        return nil
    }

    nonisolated private static func scanForMVHD(fh: FileHandle, start: UInt64, end: UInt64) -> Date? {
        var pos = start
        while pos < end {
            try? fh.seek(toOffset: pos)
            guard let header = try? fh.read(upToCount: 8), header.count == 8 else { return nil }
            let size32 = header.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? ""
            var bodyStart = pos + 8
            var atomEnd: UInt64
            if size32 == 1 {
                guard let ext = try? fh.read(upToCount: 8), ext.count == 8 else { return nil }
                let size64 = ext.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                bodyStart = pos + 16
                atomEnd = pos + size64
            } else if size32 == 0 {
                atomEnd = end
            } else {
                atomEnd = pos + UInt64(size32)
            }

            if type == "mvhd" {
                try? fh.seek(toOffset: bodyStart)
                guard let payload = try? fh.read(upToCount: 16), payload.count >= 16 else {
                    return nil
                }
                let version = payload[0]
                let creation: UInt64
                if version == 1 {
                    guard let p2 = try? fh.read(upToCount: 8), p2.count == 8 else { return nil }
                    // payload had only 16 bytes; rewind+reread for v1 layout
                    try? fh.seek(toOffset: bodyStart + 4)
                    guard let cdata = try? fh.read(upToCount: 8), cdata.count == 8 else { return nil }
                    creation = cdata.withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
                    _ = p2
                } else {
                    let c32 = payload[4..<8].withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                    creation = UInt64(c32)
                }
                if creation == 0 { return nil }
                // mp4 epoch: 1904-01-01 UTC. Unix epoch: 1970-01-01 UTC.
                // Seconds between them: 2082844800.
                let unix = Int64(creation) - 2082844800
                return Date(timeIntervalSince1970: TimeInterval(unix))
            }
            if atomEnd <= pos { return nil }
            pos = atomEnd
        }
        return nil
    }

    // Parses VID_YYYYMMDD_HHMMSS_* digits as if they were UTC. Used as one
    // half of the offset calculation; absolute moment is meaningless until
    // combined with mvhd UTC.
    nonisolated private static func filenameNaiveDate(originalURL: URL) -> Date? {
        let parts = originalURL.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard parts.count >= 3, parts[1].count == 8, parts[2].count == 6,
              Int(parts[1]) != nil, Int(parts[2]) != nil else { return nil }
        let p = DateFormatter()
        p.dateFormat = "yyyyMMdd_HHmmss"
        p.timeZone = TimeZone(identifier: "UTC")
        return p.date(from: "\(parts[1])_\(parts[2])")
    }

    // Take a Date whose hh:mm:ss components in UTC are X, and produce a Date
    // whose hh:mm:ss components in the user's current TZ are also X. Lets us
    // print the filename's wall clock unchanged when we have no real TZ.
    nonisolated private static func reinterpretInCurrentTZ(_ d: Date) -> Date {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let comps = utcCal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: d)
        var localCal = Calendar(identifier: .gregorian)
        localCal.timeZone = .current
        return localCal.date(from: comps) ?? d
    }

    nonisolated private static func formatStamp(_ d: Date, tz: TimeZone, showTZ: Bool) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.timeZone = tz
        f.setLocalizedDateFormatFromTemplate(showTZ ? "yMMMd HH:mm OOOO" : "yMMMd HH:mm")
        return f.string(from: d)
    }

    nonisolated private static func makeHardlink(of url: URL) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        do {
            try FileManager.default.linkItem(at: url, to: tmp)
        } catch {
            try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: url)
        }
        return tmp
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        teardown()
    }

    private func teardown() {
        // pause() alone leaves the audio buffer playing through CoreAudio.
        // Mute + replaceCurrentItem(nil) flushes the audio output immediately
        // (residual ~200ms is XPC tear-down latency, beyond our control).
        player?.volume = 0
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView?.player = nil
        player = nil
        if let h = hardlinkURL {
            try? FileManager.default.removeItem(at: h)
            hardlinkURL = nil
        }
    }

    deinit {
        if let h = hardlinkURL {
            try? FileManager.default.removeItem(at: h)
        }
    }
}
