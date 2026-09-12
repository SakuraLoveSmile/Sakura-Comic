import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import KomgaReader
@testable import KomgaDownloads

// MARK: - Mirror of `reader/integrity.rs`'s unit tests
//
// Same cases, same names (in Swift's camelCase spelling), same expectations, so a
// reviewer can diff the two platforms' behaviour line by line. The verdict
// vocabulary is shared: `valid` / `reclassified` / `complete` / `indeterminate` /
// `corrupt`, and the asymmetry that matters — *only* `corrupt` may delete a cached
// page — is pinned here rather than in a comment.

final class ImageIntegrityTests: XCTestCase {
    private func png() -> [UInt8] { DemoPNG.pageBytes(7) }

    func testAGeneratedPngIsValidAndReportsItsSize() throws {
        let bytes = png()
        let verdict = ImageIntegrity.inspect(bytes, declaredContentType: "image/png")
        guard case let .valid(info) = verdict else {
            return XCTFail("expected valid, got \(verdict)")
        }
        XCTAssertEqual(info.format, .png)
        // Swift tuples are not Equatable, so the pair is asserted component-wise.
        let (width, height) = DemoPNG.pageDimensions(7)
        XCTAssertEqual(info.width, width)
        XCTAssertEqual(info.height, height)
        XCTAssertTrue(verdict.isUsable)
    }

    /// The mutation check for the test above: the same bytes with one IDAT byte
    /// zeroed must NOT still be valid.
    func testOneFlippedByteInsideIdatBreaksTheChunkCrc() throws {
        var bytes = png()
        let at = bytes.count - 20
        bytes[at] ^= 0xFF
        switch ImageIntegrity.inspect(bytes, declaredContentType: "image/png") {
        case let .corrupt(corruption):
            XCTAssertTrue(
                corruption.kind == .checksumMismatch || corruption.kind == .structureInvalid,
                "expected a CRC or structure refusal, got \(corruption.reason)"
            )
        case let other:
            XCTFail("expected corrupt, got \(other)")
        }
    }

    func testATruncatedPngIsCaught() throws {
        let bytes = png()
        let cut = Array(bytes[..<(bytes.count - 6)])
        XCTAssertEqual(
            ImageIntegrity.inspect(cut, declaredContentType: "image/png"),
            .corrupt(.truncated(.png))
        )
    }

    func testTrailingBytesAfterIendAreInvalid() throws {
        var bytes = png()
        bytes.append(contentsOf: Array("garbage".utf8))
        let verdict = ImageIntegrity.inspect(bytes, declaredContentType: "image/png")
        guard case let .corrupt(corruption) = verdict, corruption.kind == .structureInvalid else {
            return XCTFail("expected a structure refusal, got \(verdict)")
        }
    }

    func testAnErrorPageCachedAsJpegIsNotAnImage() throws {
        let body = Array("<html><body>502 Bad Gateway</body></html>".utf8)
        let verdict = ImageIntegrity.inspect(body, declaredContentType: "image/jpeg")
        guard case .corrupt(let corruption) = verdict, corruption.kind == .notAnImage else {
            return XCTFail("expected not-an-image, got \(verdict)")
        }
        // And the reason is printable for the UI's error state.
        XCTAssertTrue(verdict.corruptionDescription.contains("not an image"))
    }

    func testEmptyAndUndersizedPayloadsAreRefused() throws {
        XCTAssertEqual(
            ImageIntegrity.inspect([UInt8](), declaredContentType: "image/png"),
            .corrupt(.empty)
        )
        let verdict = ImageIntegrity.inspect(Array("PNG".utf8), declaredContentType: "image/png")
        guard case let .corrupt(corruption) = verdict, corruption.kind == .tooSmall else {
            return XCTFail("expected too-small, got \(verdict)")
        }
    }

    func testAShortReadAgainstTheDeclaredSizeIsCorruption() throws {
        let bytes = png()
        let declared = Int64(bytes.count + 1)
        XCTAssertEqual(
            ImageIntegrity.inspect(bytes, declaredContentType: "image/png", declaredSize: declared),
            .corrupt(.shortRead(declared: declared, cached: Int64(bytes.count)))
        )
        // A larger-than-declared file stays fine: servers may pad.
        XCTAssertTrue(
            ImageIntegrity.inspect(bytes, declaredContentType: "image/png", declaredSize: 1)
                .isUsable
        )
    }

    func testAHeaderThatDisagreesWithTheContentTypeIsReclassifiedNotRejected() throws {
        let bytes = png()
        let verdict = ImageIntegrity.inspect(bytes, declaredContentType: "image/jpeg")
        guard case let .reclassified(info, declared) = verdict else {
            return XCTFail("expected reclassified, got \(verdict)")
        }
        XCTAssertEqual(info.format, .png)
        XCTAssertEqual(declared, "image/jpeg")
        XCTAssertEqual(info.format.fileExtension, "png")
    }

    func testContentTypesAndMagicMapToTheSameFormats() throws {
        let cases: [(String, ImageFormat)] = [
            ("image/png", .png),
            ("image/jpeg", .jpeg),
            ("image/jpeg;charset=binary", .jpeg),
            ("image/webp", .webp),
            ("image/gif", .gif),
            ("application/octet-stream", .unknown),
        ]
        for (contentType, expected) in cases {
            XCTAssertEqual(
                ImageFormat.from(contentType: contentType), expected, contentType
            )
        }
        XCTAssertEqual(ImageFormat.from(magic: png()), .png)
        XCTAssertEqual(ImageFormat.from(magic: Array("GIF89a...........;".utf8)), .gif)
        XCTAssertEqual(
            ImageFormat.from(magic: Array("RIFF".utf8) + [0x10, 0, 0, 0] + Array("WEBPVP8 ".utf8)),
            .webp
        )
    }

    func testQuickCheckFileAgreesWithTheFullWalkForGoodAndCutFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = png()
        let whole = dir.appendingPathComponent("whole.png")
        let cut = dir.appendingPathComponent("cut.png")
        try Data(bytes).write(to: whole)
        try Data(bytes[..<(bytes.count - 6)]).write(to: cut)

        XCTAssertTrue(ImageIntegrity.quickCheckFile(at: whole).isUsable)
        XCTAssertEqual(
            ImageIntegrity.quickCheckFile(at: cut),
            .corrupt(.truncated(.png))
        )
        XCTAssertEqual(
            ImageIntegrity.quickCheckFile(at: dir.appendingPathComponent("missing.png")),
            .corrupt(.empty)
        )
        let empty = dir.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        guard case let .corrupt(corruption) = ImageIntegrity.quickCheckFile(at: empty) else {
            return XCTFail("an empty file is not a hit")
        }
        XCTAssertEqual(corruption.kind, .empty)
    }

    func testQuickCheckCatchesATruncatedJpegAndABogusFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrityTestsJpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Long enough to clear MIN_IMAGE_BYTES, and ending on the EOI marker.
        var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        jpeg.append(contentsOf: [0x00, 0x04, 0x00, 0x00])
        jpeg.append(contentsOf: [UInt8](repeating: 0x20, count: 20))
        jpeg.append(contentsOf: [0xFF, 0xD9])
        let good = dir.appendingPathComponent("good.jpg")
        let bad = dir.appendingPathComponent("bad.jpg")
        try Data(jpeg).write(to: good)
        try Data(jpeg[..<(jpeg.count - 2)]).write(to: bad)
        XCTAssertTrue(ImageIntegrity.quickCheckFile(at: good).isUsable)
        XCTAssertEqual(
            ImageIntegrity.quickCheckFile(at: bad),
            .corrupt(.truncated(.jpeg))
        )
        let html = dir.appendingPathComponent("html.jpg")
        try Data("<html><body>login required</body></html>".utf8).write(to: html)
        guard case let .corrupt(corruption) = ImageIntegrity.quickCheckFile(at: html) else {
            return XCTFail("an error page is not an image")
        }
        XCTAssertEqual(corruption.kind, .notAnImage)
    }

    func testJpegSegmentWalkReadsFrameDimensionsAndRejectsABrokenLength() throws {
        // SOF0 declaring 1200x1600, then SOS, then a proper trailer.
        var jpeg: [UInt8] = [0xFF, 0xD8]
        // Lf = 14 covers the two length bytes plus the 12 that follow.
        jpeg.append(contentsOf: [0xFF, 0xC0, 0x00, 0x0E, 0x08])
        jpeg.append(contentsOf: [0x06, 0x40]) // 1600
        jpeg.append(contentsOf: [0x04, 0xB0]) // 1200
        jpeg.append(contentsOf: [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        jpeg.append(contentsOf: [0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00])
        jpeg.append(contentsOf: [0x01, 0x02, 0x03, 0xFF, 0xD9])
        XCTAssertEqual(
            ImageIntegrity.inspect(jpeg, declaredContentType: "image/jpeg"),
            .valid(ImageInfo(format: .jpeg, width: 1200, height: 1600))
        )

        // Same frame, but the scan data never terminates.
        var cut = jpeg
        cut.removeSubrange((cut.count - 2)..<cut.count)
        XCTAssertEqual(
            ImageIntegrity.inspect(cut, declaredContentType: "image/jpeg"),
            .corrupt(.truncated(.jpeg))
        )

        // A segment header claiming more bytes than exist.
        var liar: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0]
        liar.append(contentsOf: [0x7F, 0xFF])
        liar.append(contentsOf: [UInt8](repeating: 0, count: 20))
        let verdict = ImageIntegrity.inspect(liar, declaredContentType: "image/jpeg")
        guard case let .corrupt(corruption) = verdict, corruption.kind == .truncated else {
            return XCTFail("expected a truncated refusal, got \(verdict)")
        }
    }

    func testCrc32MatchesTheKnownVector() throws {
        XCTAssertEqual(ImageIntegrity.crc32(DemoPNG.bytes("IEND")), 0xAE_42_60_82)
        XCTAssertEqual(ImageIntegrity.crc32(DemoPNG.bytes("123456789")), 0xCB_F4_39_26)
    }

    // MARK: - The Apple-side half of the asymmetry

    /// A container this module recognises but cannot walk must be KEPT. Deleting
    /// it would turn "this device has no codec" into a permanent re-download.
    func testARecognisedButUnwalkableContainerIsIndeterminateAndKept() throws {
        // A BMP: real magic, no trailer to walk.
        var bmp = Array("BM".utf8)
        bmp.append(contentsOf: [UInt8](repeating: 0, count: 40))
        bmp.append(contentsOf: [UInt8](repeating: 0x20, count: 40))
        XCTAssertEqual(
            ImageIntegrity.inspect(bmp, declaredContentType: "image/bmp"),
            .indeterminate(detail: "bmp")
        )
        XCTAssertTrue(ImageIntegrity.inspect(bmp, declaredContentType: "image/bmp").isUsable)
        // And on the cheap read path, where a wrong answer costs a page.
        XCTAssertEqual(
            ImageIntegrity.checkHeadTail(head: bmp, tail: bmp, length: UInt64(bmp.count)),
            .indeterminate(detail: "bmp")
        )

        // An ISO-BMFF still image: brand in bytes 8..12, not a byte-walkable stream.
        var avif: [UInt8] = [0x00, 0x00, 0x00, 0x1C]
        avif.append(contentsOf: Array("ftyp".utf8))
        avif.append(contentsOf: Array("avif".utf8))
        avif.append(contentsOf: [UInt8](repeating: 0, count: 40))
        XCTAssertEqual(
            ImageIntegrity.inspect(avif, declaredContentType: "image/avif"),
            .indeterminate(detail: "avif")
        )
        XCTAssertEqual(ImageIntegrity.opaqueImageBrand(avif), "avif")
        // A video brand is not an image brand, so it is judged by other witnesses.
        XCTAssertNil(ImageIntegrity.opaqueImageBrand({
            var mp4: [UInt8] = [0x00, 0x00, 0x00, 0x1C]
            mp4.append(contentsOf: Array("ftyp".utf8))
            mp4.append(contentsOf: Array("mp42".utf8))
            mp4.append(contentsOf: [UInt8](repeating: 0, count: 40))
            return mp4
        }()))
    }

    /// ImageIO is the second witness: a container it can open but this module
    /// cannot name is kept, and one it rejects outright is refused.
    func testImageioKeepsWhatItCanOpenAndRefusesWhatItCannot() throws {
        let heic = encode(UTType.heic.identifier, width: 64, height: 64)
        if heic.isEmpty {
            throw XCTSkip("this device has no HEIC encoder; the case is brand-driven anyway")
        }
        // HEIC is an ISO-BMFF brand, so it is kept before ImageIO is even asked —
        // and that is the whole point: the verdict may not depend on a codec.
        let verdict = ImageIntegrity.inspect(heic, declaredContentType: "image/heic")
        XCTAssertTrue(verdict.isUsable, "a HEIC page must never be swept: \(verdict)")

        // A payload that is neither a known container nor decodable is refused.
        let garbage = [UInt8](repeating: 0x01, count: 64)
        let refused = ImageIntegrity.inspect(garbage, declaredContentType: "image/png")
        guard case let .corrupt(corruption) = refused, corruption.kind == .notAnImage else {
            return XCTFail("expected not-an-image, got \(refused)")
        }
    }

    /// ImageIO reads headers lazily, so it is NOT a completeness oracle. Pinned
    /// here because the module's design depends on that measurement holding.
    func testImageioReportsACompleteSourceForATruncatedFileSoStructureMustDecide() throws {
        let bytes = png()
        let cut = Data(bytes[..<(bytes.count - 6)])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(cut as CFData, nil))
        XCTAssertEqual(
            CGImageSourceGetStatus(source).rawValue, 0,
            "if ImageIO ever starts proving completeness, the walk above it is redundant"
        )
        XCTAssertFalse(ImageIntegrity.quickCheckFile(
            at: writeTemp(cut, name: "cut-witness.png")
        ).isUsable)
    }

    private func writeTemp(_ data: Data, name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IntegrityTests-\(UUID().uuidString)").appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url)
        return url
    }

    private func encode(_ identifier: String, width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, identifier as CFString, 1, nil
        ) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return out as Data
    }
}
