// Tests for TrailerReader. Run with tests/run.sh.
//
// Fixtures are generated here, so no camera footage lives in the repo. Any paths
// passed as arguments are real clips: each must yield a panorama, and it's written
// next to the tests' temp files for inspection.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let magic = Array("8db42d694ccc418790edff439fe026bf".utf8)
let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("trailer-tests-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
func header(_ id: Int, _ n: Int) -> [UInt8] { [UInt8(id & 0xFF), UInt8(id >> 8)] + le32(n) }

/// `records` are ordered as on disk, so the last one sits next to the tail block.
func trailer(_ records: [(id: Int, payload: [UInt8])], lengthOverride: Int? = nil) -> [UInt8] {
    var body: [UInt8] = []
    for (i, r) in records.enumerated() where i < records.count - 1 {
        body += r.payload + header(r.id, r.payload.count)
    }
    let last = records.last!
    body += last.payload
    let tailLen = 78
    let total = body.count + tailLen
    var tail = header(last.id, last.payload.count)
    tail += [UInt8](repeating: 0, count: 38 - tail.count)
    tail += le32(lengthOverride ?? total) + le32(3) + magic
    return body + tail
}

/// NV12 panorama record: solid colour, so conversion can be checked exactly.
func nv12(width: Int, height: Int, y: UInt8 = 235, cb: UInt8 = 128, cr: UInt8 = 128) -> [UInt8] {
    let n = 40 + width * height * 3 / 2
    var head = le32(1) + le32(n) + le32(1) + le32(0) + le32(width) + le32(height)
    head += [UInt8](repeating: 0, count: 40 - head.count)
    var chroma: [UInt8] = []
    for _ in 0..<(width * height / 4) { chroma += [cb, cr] }
    return head + [UInt8](repeating: y, count: width * height) + chroma
}

func file(_ name: String, _ bytes: [UInt8]) -> URL {
    let u = dir.appendingPathComponent(name)
    try! Data(bytes).write(to: u)
    return u
}

func jpeg() -> [UInt8] {
    let ctx = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let out = NSMutableData()
    let d = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(d)
    return [UInt8](out as Data)
}

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "ok  " : "FAIL") \(name)")
    if !ok { failures += 1 }
}

func pixel(_ img: CGImage) -> (UInt8, UInt8, UInt8) {
    var p = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (p[0], p[1], p[2])
}

let video = [UInt8](repeating: 0xAB, count: 4096)
let pano = nv12(width: 16, height: 8)
let info = [UInt8](repeating: 0x11, count: 64)

// Valid layouts
do {
    let img = TrailerReader.panorama(at: file("a.insv", video + trailer([(0x200, pano), (0x101, info), (0, info)])))
    check("finds a panorama behind other records", img?.width == 16 && img?.height == 8)
    if let img {
        let (r, g, b) = pixel(img)
        check("Y=235 neutral decodes to white", r > 250 && g > 250 && b > 250)
    }
    let last = TrailerReader.panorama(at: file("b.insv", video + trailer([(0x101, info), (0x200, pano)])))
    check("finds a panorama in the last record", last?.width == 16)
    let red = TrailerReader.panorama(at: file("c.insv", video + trailer([(0x200, nv12(width: 16, height: 8, y: 81, cb: 90, cr: 240))])))
    if let red {
        let (r, g, b) = pixel(red)
        check("BT.601 red decodes to red", r > 240 && g < 15 && b < 15)
    } else { check("BT.601 red decodes", false) }
    let j = TrailerReader.panorama(at: file("d.insp", video + trailer([(0x200, jpeg()), (0x101, info)])))
    check("accepts the JPEG record form", j?.width == 8 && j?.height == 4)
}

// Files that must return nil, without crashing or hanging
let valid = video + trailer([(0x200, pano), (0x101, info)])
var badMagic = valid; badMagic[badMagic.count - 1] = 0
let cases: [(String, [UInt8])] = [
    ("empty file", []),
    ("shorter than the tail", [UInt8](repeating: 0, count: 77)),
    ("no trailer", video),
    ("wrong magic", badMagic),
    ("no panorama record", video + trailer([(0x101, info), (0, info)])),
    ("trailer longer than file", video + trailer([(0x200, pano)], lengthOverride: 1 << 30)),
    ("trailer shorter than tail", video + trailer([(0x200, pano)], lengthOverride: 10)),
    ("record longer than trailer", video + {
        var t = trailer([(0x200, pano)])
        let at = t.count - 78 + 2
        t.replaceSubrange(at..<(at + 4), with: le32(1 << 28))
        return t
    }()),
    ("zero-length record", video + trailer([(0x101, [])])),
    ("unknown panorama form", video + trailer([(0x200, [UInt8](repeating: 7, count: 100))])),
    ("panorama size disagrees with header", video + trailer([(0x200, Array(pano.dropLast(2)))])),
    ("zero dimensions", video + trailer([(0x200, nv12(width: 0, height: 0))])),
    ("odd dimensions", {
        var p = nv12(width: 16, height: 8)
        p.replaceSubrange(16..<20, with: le32(15))
        return video + trailer([(0x200, p)])
    }()),
    ("huge dimensions", {
        var p = nv12(width: 16, height: 8)
        p.replaceSubrange(16..<20, with: le32(1 << 30))
        p.replaceSubrange(20..<24, with: le32(1 << 30))
        return video + trailer([(0x200, p)])
    }()),
    ("corrupt JPEG", video + trailer([(0x200, [0xFF, 0xD8, 0xFF, 0xE1, 0, 0, 0])])),
]
for (i, c) in cases.enumerated() {
    check("nil: \(c.0)", TrailerReader.panorama(at: file("bad\(i).insv", c.1)) == nil)
}
check("nil: missing file", TrailerReader.panorama(at: dir.appendingPathComponent("nope.insv")) == nil)

// Records are walked backwards through untrusted lengths: must terminate.
do {
    let many = (0..<500).map { _ in (id: 0x900, payload: [UInt8](repeating: 1, count: 4)) }
    check("nil: stops walking after too many records",
          TrailerReader.panorama(at: file("many.insv", video + trailer([(0x200, pano)] + many))) == nil)
}

// Real clips, by path
for path in CommandLine.arguments.dropFirst() {
    let t0 = Date()
    let img = TrailerReader.panorama(at: URL(fileURLWithPath: path))
    let ms = Date().timeIntervalSince(t0) * 1000
    let name = (path as NSString).lastPathComponent
    check(String(format: "real: %@ %dx%d in %.1f ms", name, img?.width ?? 0, img?.height ?? 0, ms), img != nil)
    if let img, let out = ProcessInfo.processInfo.environment["PANO_OUT"] {
        let u = URL(fileURLWithPath: out).appendingPathComponent(name + ".png")
        let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
