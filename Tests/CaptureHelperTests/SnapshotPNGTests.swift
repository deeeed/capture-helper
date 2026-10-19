import CoreVideo
import Foundation
import ImageIO
import XCTest
import zlib
@testable import capture_helper

final class SnapshotPNGTests: XCTestCase {
    func testSnapshotPngIsDeflatedAndDecodesToTheCapturedPixels() throws {
        // A UI-like frame: a flat header, text-like strokes, a gradient and translucent edge pixels.
        let width = 320
        let height = 200
        var created: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created),
            kCVReturnSuccess
        )
        let pixelBuffer = try XCTUnwrap(created)
        // The scanlines the previous stored encoder wrote: filter byte 0, then RGBA per pixel.
        var scanlines = Data()
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)).assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var seed: UInt32 = 1
        for y in 0..<height {
            scanlines.append(0)
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let stroke = y >= 40 && y % 20 < 8 && x % 7 < 3 && seed >> 28 > 7
                let r = UInt8(x * 255 / width)
                let g: UInt8 = y < 40 ? 30 : stroke ? 240 : 22
                let b: UInt8 = y < 40 ? 30 : stroke ? 236 : 18
                let a: UInt8 = x < 4 ? 128 : 255
                let pixel = base.advanced(by: y * bytesPerRow + x * 4)
                pixel[0] = b
                pixel[1] = g
                pixel[2] = r
                pixel[3] = a
                scanlines.append(contentsOf: [r, g, b, a])
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let png = try pngDataFromBgraPixelBuffer(pixelBuffer)

        let idat = try XCTUnwrap(pngChunk("IDAT", in: png))
        XCTAssertEqual(Array(idat.prefix(2)), [0x78, 0x5e])
        // System zlib checks the header and the Adler-32 trailer while it inflates.
        var inflated = Data(count: scanlines.count)
        var inflatedCount = uLongf(scanlines.count)
        let status = inflated.withUnsafeMutableBytes { output in
            idat.withUnsafeBytes { input in
                uncompress(
                    output.bindMemory(to: Bytef.self).baseAddress!, &inflatedCount,
                    input.bindMemory(to: Bytef.self).baseAddress!, uLong(idat.count)
                )
            }
        }
        XCTAssertEqual(status, Z_OK)
        XCTAssertEqual(inflated.prefix(Int(inflatedCount)), scanlines, "same scanlines, so the same pixels as the stored stream")
        XCTAssertLessThan(png.count, scanlines.count / 4, "\(png.count) bytes for \(scanlines.count) raw")

        // ImageIO reads it as the same 8-bit RGBA image.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        XCTAssertEqual(image.bitsPerPixel, 32)
        XCTAssertEqual(image.alphaInfo, .last)
        let decoded = try XCTUnwrap(image.dataProvider?.data) as Data
        for y in 0..<height {
            let row = decoded.subdata(in: (y * image.bytesPerRow)..<(y * image.bytesPerRow + width * 4))
            let start = y * (width * 4 + 1) + 1
            XCTAssertEqual(row, scanlines.subdata(in: start..<(start + width * 4)), "row \(y)")
        }
    }

    private func pngChunk(_ type: String, in png: Data) -> Data? {
        var offset = 8
        while offset + 8 <= png.count {
            let length = png[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            let name = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if name == type { return png.subdata(in: (offset + 8)..<(offset + 8 + length)) }
            offset += 12 + length
        }
        return nil
    }
}
