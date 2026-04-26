import QuickLookUI
import AVFoundation
import AVKit
import AppKit
import OSLog

private let log = Logger(subsystem: "com.faeton.insta360ql.exp03", category: "preview")

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var hardlinkURL: URL?
    private var player: AVPlayer?
    private var playerView: AVPlayerView?

    override func loadView() {
        // Bare layer-backed container; QL panel sizes us via constraints.
        let v = NSView()
        v.wantsLayer = true
        v.layer = CALayer()
        v.layer?.backgroundColor = NSColor.black.cgColor
        self.view = v
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let ext = url.pathExtension.lowercased()
        NSLog("[Insta360QL preview] preparePreview %@ ext=%@", url.lastPathComponent, ext)

        if ext == "insp" {
            attachImage(url: url)
            handler(nil)
            return
        }

        // Insta360 cameras write a paired LRV proxy alongside each .insv:
        // VID_<stamp>.insv  ↔  LRV_<stamp>.lrv. The proxy is pre-stitched
        // dual-fisheye, H.264, much smaller — far better source for preview.
        let source = Self.lrvProxy(for: url) ?? url
        if source != url {
            NSLog("[Insta360QL preview] using LRV proxy %@", source.lastPathComponent)
        }

        do {
            let h = try Self.makeHardlink(of: source)
            self.hardlinkURL = h
            NSLog("[Insta360QL preview] hardlinked %@", h.lastPathComponent)
            attachPlayer(hardlink: h)
            handler(nil)
        } catch {
            NSLog("[Insta360QL preview] hardlink failed: %@", error.localizedDescription)
            handler(error)
        }
    }

    /// For VID_<ts>_NN_<idx>.insv look for sibling LRV_<ts>_<NN+1>_<idx>.lrv
    /// (Insta360 pairs: VID_*_00_* ↔ LRV_*_01_*, occasionally _02_).
    /// Uses fileExists rather than listing — sandboxed extension can read
    /// the source file but not enumerate its directory.
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

    private func attachPlayer(hardlink: URL) {
        let asset = AVURLAsset(url: hardlink)
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        self.player = p

        let pv = AVPlayerView()
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
            NSLog("[Insta360QL preview] CGImageSource nil for %@", url.lastPathComponent)
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

    override func viewWillAppear() {
        super.viewWillAppear()
        NSLog("[Insta360QL preview] viewWillAppear")
        if let win = view.window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                                  name: NSWindow.willCloseNotification, object: win)
        }
    }
    override func viewDidAppear() { super.viewDidAppear(); NSLog("[Insta360QL preview] viewDidAppear window=%@", "\(view.window != nil)") }
    override func viewWillDisappear() { super.viewWillDisappear(); NSLog("[Insta360QL preview] viewWillDisappear"); teardown() }
    override func viewDidDisappear() { super.viewDidDisappear(); NSLog("[Insta360QL preview] viewDidDisappear"); teardown() }

    @objc private func windowWillClose(_ note: Notification) {
        NSLog("[Insta360QL preview] windowWillClose")
        teardown()
    }

    private func teardown() {
        // pause() alone leaves the audio buffer playing through CoreAudio.
        // Mute + replaceCurrentItem(nil) flushes the audio output immediately.
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
