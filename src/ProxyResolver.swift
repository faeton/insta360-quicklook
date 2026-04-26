// Insta360 cameras write a paired low-res proxy alongside each .insv:
//   VID_<ts>_<sensorA>_<idx>.insv  ↔  LRV_<ts>_<sensorB>_<idx>.lrv
// The proxy is pre-stitched dual-fisheye, H.264, 5–10× smaller. Always a
// better Quick Look source when it exists.
//
// Sandboxed app extensions can't enumerate the source directory; they can
// only stat individual paths. So we probe a small list of likely sensor
// indexes (01 first — it's the camera convention — then 02, then 00).
import Foundation

enum ProxyResolver {
    static func lrvProxy(for url: URL) -> URL? {
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
}
