// Experiment 00: can AVAssetImageGenerator decode HEVC pix_fmt=yuvj420p
// outside any sandbox? If this fails, the whole project needs ffmpeg fallback.
//
// Run: swift experiments/00-avfoundation-hevc.swift <path-to-insv>
import AVFoundation
import AppKit

guard CommandLine.arguments.count == 2 else {
    print("usage: \(CommandLine.arguments[0]) <video-path>")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let asset = AVURLAsset(url: url)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
gen.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)
gen.maximumSize = CGSize(width: 1024, height: 1024)

let sem = DispatchSemaphore(value: 0)
var ok = false
var failure: String?

let t0 = Date()
do {
    let cg = try gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
    let dt = Date().timeIntervalSince(t0)
    let bmp = NSBitmapImageRep(cgImage: cg)
    let png = bmp.representation(using: .png, properties: [:])!
    let outURL = URL(fileURLWithPath: "/tmp/exp00-frame.png")
    try png.write(to: outURL)
    print("OK  \(cg.width)x\(cg.height)  \(String(format: "%.2f", dt))s  -> \(outURL.path)")
    ok = true
} catch {
    failure = String(describing: error)
}
sem.signal()
_ = sem.wait(timeout: .now() + .seconds(30))

if !ok {
    print("FAIL  \(failure ?? "unknown")")
    exit(1)
}
