// Exp 00b: can we make AVURLAsset open .insv by forcing MIME type?
import AVFoundation
import AppKit

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let opts: [String: Any] = [
    "AVURLAssetOverrideMIMETypeKey": "video/mp4",  // private key but documented to work
]
let asset = AVURLAsset(url: url, options: opts)
let gen = AVAssetImageGenerator(asset: asset)
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
gen.requestedTimeToleranceAfter  = CMTime(seconds: 1, preferredTimescale: 600)
gen.maximumSize = CGSize(width: 1024, height: 1024)
do {
    let cg = try gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil)
    let bmp = NSBitmapImageRep(cgImage: cg)
    let png = bmp.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: "/tmp/exp00b-frame.png"))
    print("OK  \(cg.width)x\(cg.height)  via MIME override")
} catch {
    print("FAIL  \(error)")
    exit(1)
}
