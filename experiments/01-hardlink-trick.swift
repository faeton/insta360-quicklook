// Exp 01: hardlink/symlink trick — pretend .insv is .mp4 to AVFoundation
import AVFoundation
import AppKit

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("\(UUID().uuidString).mp4")

defer { try? FileManager.default.removeItem(at: tmp) }

// Try hardlink first (free, instant, same volume only)
do {
    try FileManager.default.linkItem(at: url, to: tmp)
    print("hardlink ok -> \(tmp.path)")
} catch {
    print("hardlink failed (\(error.localizedDescription)) — falling back to symlink")
    try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: url)
    print("symlink ok -> \(tmp.path)")
}

let asset = AVURLAsset(url: tmp)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
gen.maximumSize = CGSize(width: 1024, height: 1024)
let t0 = Date()
do {
    let cg = try gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
    let dt = Date().timeIntervalSince(t0)
    let bmp = NSBitmapImageRep(cgImage: cg)
    let png = bmp.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: "/tmp/exp01-frame.png"))
    print("OK  \(cg.width)x\(cg.height)  decode=\(String(format: "%.2f", dt))s  -> /tmp/exp01-frame.png")
} catch {
    print("FAIL  \(error)")
    exit(1)
}
