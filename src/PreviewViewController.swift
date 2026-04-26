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
            attachPlayer(hardlink: h)
            handler(nil)
        } catch {
            log.error("hardlink failed: \(error.localizedDescription, privacy: .public)")
            handler(error)
        }
    }

    private func attachPlayer(hardlink: URL) {
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

        p.play()
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

    private static func makeHardlink(of url: URL) throws -> URL {
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
