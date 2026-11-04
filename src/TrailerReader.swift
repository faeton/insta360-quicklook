// Reads the stitched panorama that Insta360 cameras store in a file's trailer, so a
// thumbnail needs no video decode and no stitching. Reads only the end of the file.
//
// The format is undocumented and these bytes are untrusted, so anything unexpected
// returns nil and the caller falls back to decoding a frame. Layout learned from
// ExifTool's ProcessInsta360 and checked against Insta360 X5 files:
//
//   ...video... | payload | header | ... | payload | tail (78 bytes)
//
//   tail:   header(6) ... u32 trailer length at 38 ... magic in the last 32 bytes
//   header: u16 record id, u32 length of the payload just before the header
//
// Record 0x200 is the panorama, in one of two forms handled here:
//   - JPEG
//   - 40-byte header (u32 1, u32 record length, ..., u32 width at 16, u32 height
//     at 20) followed by NV12 pixels
// ExifTool also documents other forms of this record, which return nil here.
//
// Record 0x101 is a protobuf message. Field 7 holds the camera's local wall clock
// as an integer reading YYYYMMDDHHMMSS, which survives the file being renamed.
import Foundation
import CoreGraphics
import ImageIO

enum TrailerReader {
    private static let magic = Data("8db42d694ccc418790edff439fe026bf".utf8)
    private static let tailLength = 78
    private static let panoramaRecord = 0x200
    private static let infoRecord = 0x101
    private static let wallClockField = 7
    private static let maxInfoBytes = 1 << 20
    private static let maxRecords = 64
    private static let maxPanoramaBytes = 64 << 20
    private static let maxDimension = 8192

    static func panorama(at url: URL) -> CGImage? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let payload = record(panoramaRecord, maxBytes: maxPanoramaBytes, in: file) else { return nil }
        return decode(payload)
    }

    /// The camera's local capture time as YYYYMMDDHHMMSS, with no timezone.
    static func captureWallClock(at url: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let payload = record(infoRecord, maxBytes: maxInfoBytes, in: file) else { return nil }
        return wallClock(inMessage: [UInt8](payload))
    }

    private static func wallClock(inMessage bytes: [UInt8]) -> String? {
        var i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < bytes.count, shift < 63 {
                let b = bytes[i]
                i += 1
                value |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < bytes.count {
            guard let tag = varint() else { return nil }
            switch tag & 7 {
            case 0:
                guard let value = varint() else { return nil }
                if tag >> 3 == wallClockField {
                    return (10_000_000_000_000...99_999_999_999_999).contains(value) ? String(value) : nil
                }
            case 1: i += 8
            case 5: i += 4
            case 2:
                guard let n = varint(), n >= 0, n <= bytes.count - i else { return nil }
                i += n
            default: return nil
            }
        }
        return nil
    }

    /// How to fit a panorama into a thumbnail. Below `squareBelow` a 2:1 image is too
    /// short to read, so it takes the centre square. Above it, the full panorama keeps
    /// its own shape, so there are no bars around it.
    static func framing(imageWidth: Int, imageHeight: Int, maximum: CGSize,
                        squareBelow: CGFloat = 128) -> (crop: CGRect?, frame: CGSize) {
        guard imageWidth > imageHeight, imageHeight > 0 else { return (nil, maximum) }
        if min(maximum.width, maximum.height) < squareBelow {
            let side = min(maximum.width, maximum.height)
            let crop = CGRect(x: (imageWidth - imageHeight) / 2, y: 0,
                              width: imageHeight, height: imageHeight)
            return (crop, CGSize(width: side, height: side))
        }
        let aspect = CGFloat(imageWidth) / CGFloat(imageHeight)
        let width = min(maximum.width, maximum.height * aspect)
        return (nil, CGSize(width: width, height: width / aspect))
    }

    private static func record(_ wanted: Int, maxBytes: Int, in file: FileHandle) -> Data? {
        guard let size = (try? file.seekToEnd()).map(Int.init), size >= tailLength,
              let tail = read(file, at: size - tailLength, count: tailLength),
              tail.suffix(magic.count) == magic
        else { return nil }

        let trailerLength = u32(tail, 38)
        guard trailerLength >= tailLength, trailerLength <= size else { return nil }
        let trailerStart = size - trailerLength

        var headerAt = size - tailLength
        var header = tail.prefix(6)
        for _ in 0..<maxRecords {
            let id = Int(header[header.startIndex]) | Int(header[header.startIndex + 1]) << 8
            let length = u32(header, 2)
            let payloadAt = headerAt - length
            guard length > 0, payloadAt >= trailerStart else { return nil }

            if id == wanted {
                guard length <= maxBytes else { return nil }
                return read(file, at: payloadAt, count: length)
            }

            headerAt = payloadAt - 6
            guard headerAt >= trailerStart,
                  let next = read(file, at: headerAt, count: 6)
            else { return nil }
            header = next
        }
        return nil
    }

    private static func decode(_ payload: Data) -> CGImage? {
        if payload.starts(with: [0xFF, 0xD8, 0xFF]) {
            guard let source = CGImageSourceCreateWithData(payload as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard payload.count >= 40, u32(payload, 0) == 1, u32(payload, 4) == payload.count else {
            return nil
        }
        let width = u32(payload, 16), height = u32(payload, 20)
        guard width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              width % 2 == 0, height % 2 == 0,
              payload.count == 40 + width * height * 3 / 2
        else { return nil }
        return nv12Image(payload.dropFirst(40), width: width, height: height)
    }

    /// BT.601 video range, which matches how these panoramas decode with ffmpeg.
    private static func nv12Image(_ pixels: Data, width: Int, height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let luma = src.bindMemory(to: UInt8.self)
            rgba.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let chromaRow = width * height + (y / 2) * width
                    var o = y * width * 4
                    for x in 0..<width {
                        let c = 298 * (Int(luma[y * width + x]) - 16)
                        let u = Int(luma[chromaRow + (x & ~1)]) - 128
                        let v = Int(luma[chromaRow + (x & ~1) + 1]) - 128
                        dst[o] = clamp((c + 409 * v + 128) >> 8)
                        dst[o + 1] = clamp((c - 100 * u - 208 * v + 128) >> 8)
                        dst[o + 2] = clamp((c + 516 * u + 128) >> 8)
                        o += 4
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v))) }

    private static func read(_ file: FileHandle, at offset: Int, count: Int) -> Data? {
        guard offset >= 0, (try? file.seek(toOffset: UInt64(offset))) != nil,
              let data = try? file.read(upToCount: count), data.count == count
        else { return nil }
        return data
    }

    private static func u32(_ data: Data, _ at: Int) -> Int {
        let s = data.startIndex + at
        return Int(data[s]) | Int(data[s + 1]) << 8 | Int(data[s + 2]) << 16 | Int(data[s + 3]) << 24
    }
}
