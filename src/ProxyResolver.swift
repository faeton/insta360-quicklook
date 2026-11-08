// 360 cameras write a paired low-res proxy alongside each full-res clip:
//   Insta360  VID_<ts>_<sensorA>_<idx>.insv ↔ LRV_<ts>_<sensorB>_<idx>.lrv
//             ONE R uses .insv for the proxy too, with sensor index 11
//   DJI       CAM_<ts>_<idx>_D.OSV          ↔ CAM_<ts>_<idx>_D.LRF
// The proxy is side-by-side fisheye (not stitched), H.264, 5–10× smaller. A
// better Quick Look source when it can be read, and for DJI the only way to show
// both lenses at once, since an .OSV carries one lens per track.
//
// Sandboxed app extensions can't enumerate the source directory; they can
// only stat individual paths. Insta360 therefore needs a small probe over likely
// sensor indexes; DJI pairs by identical basename, so one stat does.
//
// Probing uses isReadableFile, not fileExists. A contributor measured the
// sandbox on macOS 26.6 reporting siblings as existing while denying reads.
// Returning an unreadable proxy would replace a working source with one that
// can't be decoded, so "not readable" means "no proxy" and the caller falls
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

    // Probe 01 first — it's the camera convention — then 02, then 00, then 11.
    // A ONE R writes one 2880x2880 fisheye per .insv, two files per clip, and
    // names its proxy LRV_<ts>_11_<idx>.insv — sensor 11, and .insv rather than
    // .lrv. That proxy is 736x368, side by side, so it is the only single file
    // of the set showing both lenses. Probe both extensions for every index,
    // since the index and the extension vary independently across models.
    private static let insta360Sensors = ["01", "02", "00", "11"]
    private static let insta360ProxyExtensions = ["lrv", "insv"]

    private static func insta360LRV(for url: URL) -> URL? {
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("VID_") else { return nil }
        let rest = String(name.dropFirst(4))
        let parts = rest.split(separator: "_")
        guard parts.count >= 4 else { return nil }
        let stampPrefix = parts[0..<2].joined(separator: "_")
        let trailingIdx = parts.last!
        let dir = url.deletingLastPathComponent()
        for sensor in insta360Sensors {
            for ext in insta360ProxyExtensions {
                let candidate = dir.appendingPathComponent(
                    "LRV_\(stampPrefix)_\(sensor)_\(trailingIdx).\(ext)")
                if usable(candidate) { return candidate }
            }
        }
        return nil
    }

    // The camera writes .LRF uppercase; probe lowercase too, since copied or
    // renamed media often arrives lowercased.
    private static func djiLRF(for url: URL) -> URL? {
        let base = url.deletingPathExtension()
        for ext in ["LRF", "lrf"] {
            let candidate = base.appendingPathExtension(ext)
            if usable(candidate) { return candidate }
        }
        return nil
    }
}
