// 360 cameras write a paired low-res proxy alongside each full-res clip:
//   Insta360  VID_<ts>_<sensorA>_<idx>.insv ↔ LRV_<ts>_<sensorB>_<idx>.lrv
//   DJI       CAM_<ts>_<idx>_D.OSV          ↔ CAM_<ts>_<idx>_D.LRF
// The proxy is pre-stitched dual-fisheye, H.264, 5–10× smaller. Always a
// better Quick Look source when it exists — and for DJI it's the only way
// to show both lenses at once, since an .OSV carries one lens per track.
//
// Sandboxed app extensions can't enumerate the source directory; they can
// only stat individual paths. Insta360 therefore needs a small probe over
// likely sensor indexes; DJI pairs by identical basename, so one stat does.
//
// Probing uses isReadableFile, not fileExists. On macOS 26.6 the sandbox
// reports siblings as existing but denies reading them — the
// temporary-exception.files.absolute-path.read-only entitlement no longer
// covers files Quick Look didn't hand us. Returning an unreadable proxy
// would substitute a source that cannot be decoded and kill the thumbnail
// outright, so treat "not readable" as "no proxy" and let the caller fall
// back to the original file.
import Foundation

enum ProxyResolver {
    static func proxy(for url: URL) -> URL? {
        switch url.pathExtension.lowercased() {
        case "insv": return insta360LRV(for: url)
        case "osv":  return djiLRF(for: url)
        default:     return nil
        }
    }

    private static func usable(_ url: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: url.path)
    }

    // Probe 01 first — it's the camera convention — then 02, then 00.
    private static func insta360LRV(for url: URL) -> URL? {
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
            if usable(candidate) { return candidate }
        }
        return nil
    }

    // The camera writes .LRF uppercase; probe lowercase too, since copied
    // or renamed media often arrives lowercased.
    private static func djiLRF(for url: URL) -> URL? {
        let base = url.deletingPathExtension()
        for ext in ["LRF", "lrf"] {
            let candidate = base.appendingPathExtension(ext)
            if usable(candidate) { return candidate }
        }
        return nil
    }
}
