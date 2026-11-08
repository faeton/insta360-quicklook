// Tests for TrailerReader. Run with tests/run.sh.
//
// Fixtures are generated here, so no camera footage lives in the repo. Any paths
// passed as arguments are real clips: each must yield a panorama, and it's written
// next to the tests' temp files for inspection.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Metal

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

// Thumbnail framing
do {
    let small = TrailerReader.framing(imageWidth: 1280, imageHeight: 640, maximum: CGSize(width: 64, height: 64))
    check("64 px takes the centre square",
          small.crop == CGRect(x: 320, y: 0, width: 640, height: 640) && small.frame == CGSize(width: 64, height: 64))
    let large = TrailerReader.framing(imageWidth: 1280, imageHeight: 640, maximum: CGSize(width: 256, height: 256))
    check("256 px keeps the full 2:1 panorama", large.crop == nil && large.frame == CGSize(width: 256, height: 128))
    let edge = TrailerReader.framing(imageWidth: 1280, imageHeight: 640, maximum: CGSize(width: 128, height: 128))
    check("128 px is the first full-panorama size", edge.crop == nil && edge.frame == CGSize(width: 128, height: 64))
    let tall = TrailerReader.framing(imageWidth: 640, imageHeight: 640, maximum: CGSize(width: 64, height: 64))
    check("a square image is left alone", tall.crop == nil && tall.frame == CGSize(width: 64, height: 64))
}

// Capture wall clock
do {
    func field(_ number: Int, _ text: String) -> [UInt8] { [UInt8(number << 3 | 2), UInt8(text.utf8.count)] + Array(text.utf8) }
    func number(_ number: Int, _ value: Int) -> [UInt8] {
        var out = [UInt8(number << 3)], v = value
        while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        return out + [UInt8(v)]
    }
    let good = field(1, "SERIAL") + number(10, 253) + number(7, 20260625182503) + field(9, "x")
    check("reads the wall clock from the info record",
          TrailerReader.captureWallClock(at: file("w1.insv", video + trailer([(0x200, pano), (0x101, good)]))) == "20260625182503")
    let cases: [(String, [UInt8])] = [
        ("no such field", field(1, "SERIAL")),
        ("too few digits", number(7, 2026)),
        ("too many digits", number(7, 202606251825030)),
        ("field overruns the message", [UInt8(1 << 3 | 2), 200, 0x31]),
        ("unknown wire type", [0x0F, 1, 2, 3]),
        ("truncated varint", [0x08, 0x80]),
    ]
    for (i, c) in cases.enumerated() {
        check("no wall clock: \(c.0)", TrailerReader.captureWallClock(at: file("w\(i + 2).insv", video + trailer([(0x101, c.1)]))) == nil)
    }
    check("no wall clock: no trailer", TrailerReader.captureWallClock(at: file("w9.insv", video)) == nil)
}

// Proxy pairing
do {
    let p = dir.appendingPathComponent("proxies")
    try! FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
    func touch(_ n: String) -> URL { let u = p.appendingPathComponent(n); try! Data().write(to: u); return u }
    let insv = touch("VID_20260625_182503_00_054.insv")
    check("insv without a proxy", ProxyResolver.proxy(for: insv) == nil)
    let lrv = touch("LRV_20260625_182503_01_054.lrv")
    check("insv pairs with its lrv", ProxyResolver.proxy(for: insv)?.lastPathComponent == lrv.lastPathComponent)
    try! FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lrv.path)
    check("an unreadable lrv counts as no proxy", ProxyResolver.proxy(for: insv) == nil)
    let osv = touch("CAM_20260625182503_0054_D.OSV")
    check("osv without a proxy", ProxyResolver.proxy(for: osv) == nil)
    let lrf = touch("CAM_20260625182503_0054_D.LRF")
    check("osv pairs with its LRF", ProxyResolver.proxy(for: osv)?.lastPathComponent.lowercased() == lrf.lastPathComponent.lowercased())
    let lower = touch("CAM_20260625182504_0055_D.osv")
    let lowerProxy = touch("CAM_20260625182504_0055_D.lrf")
    check("a lowercased osv pairs with its lrf", ProxyResolver.proxy(for: lower)?.lastPathComponent.lowercased() == lowerProxy.lastPathComponent.lowercased())
    check("an lrf has no proxy of its own", ProxyResolver.proxy(for: lrf) == nil)
}

// Panorama view: renders offscreen so the projection can be checked exactly
func render(_ image: CGImage, camera: PanoramaCamera, width: Int = 16, height: Int = 16) -> [UInt8]? {
    guard let renderer = PanoramaRenderer(image: image) else { return nil }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    let target = renderer.device.makeTexture(descriptor: d)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    guard let buffer = renderer.commandBuffer(camera: camera, pass: pass, aspect: Float(width) / Float(height)) else { return nil }
    buffer.commit()
    buffer.waitUntilCompleted()
    var out = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(&out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return out
}
do {
    // Four 90° columns: front is red, right green, back blue, left yellow. Top half is lit.
    let w = 64, h = 32
    var px = [UInt8](repeating: 255, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let lon = (Double(x) + 0.5) / Double(w) * 360 - 180
        let c: (UInt8, UInt8, UInt8)
        switch lon {
        case -45..<45: c = (255, 0, 0)
        case 45..<135: c = (0, 255, 0)
        case -135 ..< -45: c = (255, 255, 0)
        default: c = (0, 0, 255)
        }
        let dim: UInt8 = y < h / 2 ? 1 : 2
        let i = (y * w + x) * 4
        px[i] = c.0 / dim; px[i + 1] = c.1 / dim; px[i + 2] = c.2 / dim
    } }
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let image = ctx.makeImage()!
    func centre(_ yaw: Float, _ pitch: Float = 0.5) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let o = render(image, camera: PanoramaCamera(yaw: yaw, pitch: pitch, fov: 30)) else { return nil }
        let i = (8 * 16 + 8) * 4   // BGRA
        return (o[i + 2], o[i + 1], o[i])
    }
    let front = centre(0), right = centre(.pi / 2), back = centre(.pi), left = centre(-.pi / 2)
    check("panorama: yaw 0 looks at the front", front.map { $0.r > 200 && $0.g < 60 && $0.b < 60 } ?? false)
    check("panorama: turning right finds the right side", right.map { $0.g > 200 && $0.r < 60 } ?? false)
    check("panorama: turning around finds the back", back.map { $0.b > 200 && $0.r < 60 } ?? false)
    check("panorama: turning left finds the left side", left.map { $0.r > 200 && $0.g > 200 } ?? false)
    let up = centre(0, 0.5), down = centre(0, -0.5)
    check("panorama: looking up sees the top half", up.map { $0.r > 200 } ?? false)
    check("panorama: looking down sees the bottom half", down.map { $0.r < 160 && $0.r > 90 } ?? false)
}
do {
    var c = PanoramaCamera()
    c.drag(dx: 0, dy: -100000, viewHeight: 100)
    check("camera: pitch stops at the pole", abs(c.pitch) <= .pi / 2 + 0.001)
    c = PanoramaCamera(); c.zoom(by: 1000)
    check("camera: zoom stops at its limit", c.fov == 30)
}

// Real clips, by path
for path in CommandLine.arguments.dropFirst() {
    let t0 = Date()
    let img = TrailerReader.panorama(at: URL(fileURLWithPath: path))
    let ms = Date().timeIntervalSince(t0) * 1000
    let name = (path as NSString).lastPathComponent
    check(String(format: "real: %@ %dx%d in %.1f ms", name, img?.width ?? 0, img?.height ?? 0, ms), img != nil)
    let clock = TrailerReader.captureWallClock(at: URL(fileURLWithPath: path))
    check("real: \(name) wall clock \(clock ?? "none")", clock != nil)
    if let img, let out = ProcessInfo.processInfo.environment["PANO_OUT"] {
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(name + ".png")
        var saved = false
        if let d = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(d, img, nil)
            saved = CGImageDestinationFinalize(d)
        }
        check("real: \(name) saved to \(u.path)", saved)
    }
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
