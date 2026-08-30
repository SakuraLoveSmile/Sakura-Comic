import Foundation
import ImageIO

// MARK: - Image integrity (mirror of `reader/integrity.rs`)
//
// The page cache is the one place where a bad byte stops being a transient
// failure and becomes permanent: a truncated download or an HTML error page
// renamed to `.jpg` would be cached, hit forever, and render as a broken image
// on every page turn. Every cache write and every cache read therefore passes a
// verdict from here.
//
// The core never decodes a picture, so "valid" here means *structurally*
// complete, which is decidable from the container alone:
//
// * the format is recognised from its magic bytes (not from a content type — the
//   header is the only witness that cannot lie about what was written),
// * the declared payload is actually present,
// * the format's terminator is at the end of the buffer.
//
// Two entry points because they have different costs:
//
// * [`ImageIntegrity.inspect`] runs on bytes already in memory, at store time, and
//   walks the whole container including per-chunk CRCs;
// * [`ImageIntegrity.quickCheckFile`] runs on every cache hit and reads only the
//   head and tail of the file, so a 24 MB page costs two small reads instead of a
//   copy.
//
// Why ImageIO is a *second* witness and never the only one. Measured on this
// toolchain (Xcode 27, macOS SDK 27): `CGImageSourceGetStatus` answers
// `kCGImageStatusComplete` for a PNG with its last 6 bytes cut off and for one
// whose IDAT has a flipped byte, because ImageIO parses headers lazily and never
// verifies the chunk stream it is not decoding. So completeness stays structural
// (the same walk the Rust core runs, which is what makes the two platforms agree
// byte for byte), and ImageIO contributes the two things the byte walk cannot
// decide on its own: whether a container this module does not walk is decodable
// *at all* on this device, and the dimensions for the formats whose header does
// not disclose them where the walker looks (WebP lossless).
//
// The asymmetry that matters most survives from Rust: a container that is
// recognised but not walkable — AVIF, HEIC, BMP, TIFF, JPEG XL — answers
// `indeterminate`, which is *kept*. Only an explicit `corrupt` verdict deletes a
// cache entry, because deleting a page the device happens not to have a codec for
// would turn a missing decoder into a permanent re-download.

/// Sizes and windows shared with the Rust module, so both platforms judge the
/// same bytes the same way.
public enum ImageIntegrityConstants {
    /// Smallest buffer that can hold a PNG head plus an IHDR, or a JPEG APPn
    /// segment. Anything smaller cannot be a well-formed image of any kind.
    public static let minImageBytes = 24
    /// How many bytes the quick check reads at each end of a file. PNG's `IEND`
    /// and JPEG's `FFD9` need 12 and 2 bytes; WebP's `RIFF` size needs 12; the
    /// extra room is for formats whose trailer is a little further in.
    public static let headWindow = 64
    public static let tailWindow = 64
}

public enum ImageFormat: String, Sendable, Equatable, CaseIterable {
    case png
    case jpeg
    case gif
    case webp
    /// Bytes whose container this module cannot judge.
    case unknown

    public var asStr: String { rawValue }

    /// The extension this module writes a container under, when it names a file
    /// after what the bytes are rather than what the header claimed.
    public var fileExtension: String? {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .gif: return "gif"
        case .webp: return "webp"
        case .unknown: return nil
        }
    }

    /// The format a response's `Content-Type` claims.
    public static func from(contentType: String) -> ImageFormat {
        let head = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? contentType
        switch head {
        case "image/png": return .png
        case "image/jpeg", "image/jpg", "image/pjpeg": return .jpeg
        case "image/gif": return .gif
        case "image/webp": return .webp
        default: return .unknown
        }
    }

    /// The format the bytes themselves say they are.
    public static func from(magic bytes: [UInt8]) -> ImageFormat {
        if bytes.starts(with: ImageIntegrity.pngSignature) { return .png }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) {
            return .gif
        }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return .webp
        }
        return .unknown
    }
}

public struct ImageInfo: Sendable, Equatable {
    public var format: ImageFormat
    /// Zero when the container did not disclose dimensions where this module
    /// looks for them. Never a guess.
    public var width: UInt32
    public var height: UInt32

    public init(format: ImageFormat, width: UInt32, height: UInt32) {
        self.format = format
        self.width = width
        self.height = height
    }
}

/// Why a payload may not be trusted. Mirrors the Rust `Corruption` variants, and
/// `reason` reproduces their `describe()` text so a log line means the same thing
/// on either platform.
public struct Corruption: Error, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case empty
        case tooSmall
        case notAnImage
        case truncated
        case structureInvalid
        case checksumMismatch
        case shortRead
    }

    public var kind: Kind
    public var format: ImageFormat
    /// Byte count (`tooSmall`), chunk name (`checksumMismatch`) or the hex
    /// preview of the head (`notAnImage`).
    public var detail: String
    public var declared: Int64
    public var cached: Int64

    public init(
        kind: Kind,
        format: ImageFormat = .unknown,
        detail: String = "",
        declared: Int64 = 0,
        cached: Int64 = 0
    ) {
        self.kind = kind
        self.format = format
        self.detail = detail
        self.declared = declared
        self.cached = cached
    }

    /// The walk returns `Result<ImageInfo, Corruption>`, exactly as Rust returns
    /// `Result<ImageInfo, Corruption>`; the Error conformance is what lets Swift
    /// spell it that way.
    ///
    /// Human-readable reason, for the reader's error state.
    public var reason: String {
        switch kind {
        case .empty: return "empty response"
        case .tooSmall: return "only \(detail) bytes"
        case .notAnImage: return "not an image (starts with \(detail))"
        case .truncated: return "\(format.asStr) is truncated"
        case .structureInvalid: return "\(format.asStr) structure invalid: \(detail)"
        case .checksumMismatch: return "\(format.asStr) checksum wrong in \(detail)"
        case .shortRead: return "cached \(cached) bytes of a declared \(declared)"
        }
    }
}

public enum Verdict: Sendable, Equatable {
    /// Complete image, and the header agrees with the declared content type.
    case valid(ImageInfo)
    /// Complete image whose header names a different format than declared.
    /// Usable — the bytes win, because the decoder sniffs bytes too — but the
    /// caller should name the file after `info.format`, not after the header.
    case reclassified(info: ImageInfo, declared: String)
    /// Head and trailer confirm the file is whole, without a full walk. This is
    /// what a cache hit answers with: the deep checks already ran at store time.
    case complete(ImageFormat)
    /// An image container this module recognises but cannot walk (AVIF, HEIC,
    /// BMP, JPEG XL), or one only ImageIO can open. Not proof of damage: the
    /// caller keeps it and simply cannot claim the bytes are complete.
    case indeterminate(detail: String)
    /// Unusable. The entry must be dropped, never served again.
    case corrupt(Corruption)

    /// Only an explicit corruption verdict is a reason to drop a cache entry.
    public var isUsable: Bool {
        if case .corrupt = self { return false }
        return true
    }

    public var info: ImageInfo? {
        switch self {
        case let .valid(info): return info
        case let .reclassified(info, _): return info
        default: return nil
        }
    }

    /// Human-readable reason, for the reader's error state. Empty when usable.
    public var corruptionDescription: String {
        if case let .corrupt(corruption) = self { return corruption.reason }
        return ""
    }
}

public enum ImageIntegrity {
    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// Judge in-memory bytes, optionally against the size the manifest declared
    /// for this page (`declaredSize` is nil when the server did not report one).
    public static func inspect(
        _ bytes: [UInt8],
        declaredContentType: String,
        declaredSize: Int64? = nil
    ) -> Verdict {
        if bytes.isEmpty { return .corrupt(.empty) }
        if bytes.count < ImageIntegrityConstants.minImageBytes {
            return .corrupt(.tooSmall(bytes.count))
        }
        if let declared = declaredSize, declared > 0, Int64(bytes.count) < declared {
            return .corrupt(.shortRead(declared: declared, cached: Int64(bytes.count)))
        }

        let found = ImageFormat.from(magic: bytes)
        var info: ImageInfo
        switch found {
        case .png, .jpeg, .gif, .webp:
            switch walk(bytes, found) {
            case let .success(verified): info = verified
            case let .failure(corruption): return .corrupt(corruption)
            }
        case .unknown:
            // The Rust order matters here: an unwalkable-but-named container is
            // judged before the "this is not an image at all" verdict, so a page
            // the device cannot decode is never mistaken for a page that was
            // never an image.
            if let brand = opaqueImageBrand(bytes) {
                return .indeterminate(detail: brand)
            }
            // Apple's extra witness: a container with no magic this module walks,
            // but which ImageIO opens completely, is decodable on this device.
            // Keep it — and keep it under `indeterminate` when nothing can name
            // it, since neither a byte walk nor a header read proved its trailer.
            guard let sniff = imageIOSniff(bytes) else {
                return .corrupt(.notAnImage(hexPreview(bytes, 12)))
            }
            if sniff.decodable {
                return classifyFormatFound(
                    found: sniff.format,
                    info: ImageInfo(format: sniff.format, width: sniff.width, height: sniff.height),
                    declaredContentType: declaredContentType,
                    fallbackDetail: sniff.typeName
                )
            }
            if !sniff.rejectedAsDamaged {
                // `kCGImageStatusUnknownType`: no codec on this device, which is a
                // reason to keep the bytes and say nothing about them.
                return .indeterminate(detail: sniff.typeName.isEmpty ? "unknown" : sniff.typeName)
            }
            return .corrupt(.notAnImage(hexPreview(bytes, 12)))
        }

        // A container that walks clean but that ImageIO refuses outright is not
        // something the reader can paint either, and the walk is the more lenient
        // of the two for an exotic variant.
        let sniff = imageIOSniff(bytes)
        if let sniff, sniff.rejectedAsDamaged {
            return .corrupt(.invalid(found, "ImageIO status \(sniff.status)"))
        }
        if info.width == 0 || info.height == 0, let sniff, sniff.decodable {
            info = ImageInfo(format: info.format, width: sniff.width, height: sniff.height)
        }
        return classifyFormatFound(
            found: found, info: info, declaredContentType: declaredContentType,
            fallbackDetail: ""
        )
    }

    /// The structural walk for the four containers this module can read to the
    /// end, which is where completeness is actually decidable.
    static func walk(
        _ bytes: [UInt8], _ format: ImageFormat
    ) -> Result<ImageInfo, Corruption> {
        switch format {
        case .png: return inspectPNG(bytes)
        case .jpeg: return inspectJPEG(bytes)
        case .gif: return inspectGIF(bytes)
        case .webp: return inspectWebP(bytes)
        case .unknown: return .failure(.invalid(.unknown, "no walker"))
        }
    }

    public static func inspect(
        _ data: Data,
        declaredContentType: String,
        declaredSize: Int64? = nil
    ) -> Verdict {
        inspect([UInt8](data), declaredContentType: declaredContentType, declaredSize: declaredSize)
    }

    /// The declared-format rule, shared by the magic path and the ImageIO path:
    /// a container that names itself differently from the response header is
    /// reclassified, not rejected, unless nothing can name it — which is a kept,
    /// undecidable container rather than a verdict of damage.
    private static func classifyFormatFound(
        found: ImageFormat,
        info: ImageInfo,
        declaredContentType: String,
        fallbackDetail: String
    ) -> Verdict {
        guard found != .unknown else {
            return .indeterminate(detail: fallbackDetail.isEmpty ? "unknown" : fallbackDetail)
        }
        let declared = ImageFormat.from(contentType: declaredContentType)
        if declared != .unknown && declared != found {
            return .reclassified(info: info, declared: declaredContentType)
        }
        return .valid(info)
    }

    /// Cheap completeness check of a file already on disk: head and tail only.
    ///
    /// This is what runs on the hot path (every cache hit), so it must not copy a
    /// 24 MB page. It answers exactly one question — is this file plausibly still
    /// the complete image the ledger says it is — and leaves the deep walk to
    /// `inspect` at store time.
    public static func quickCheckFile(at url: URL, declaredSize: Int64? = nil) -> Verdict {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .corrupt(.empty)
        }
        defer { try? handle.close() }
        let length: UInt64
        do {
            length = try handle.seekToEnd()
        } catch {
            return .corrupt(.empty)
        }
        if length == 0 { return .corrupt(.empty) }
        if let declared = declaredSize, declared > 0, Int64(length) < declared {
            return .corrupt(.shortRead(declared: declared, cached: Int64(length)))
        }
        if length < UInt64(ImageIntegrityConstants.minImageBytes) {
            return .corrupt(.tooSmall(length))
        }
        guard
            let head = readWindow(handle, offset: 0, want: ImageIntegrityConstants.headWindow, length: length),
            let tail = readWindow(
                handle,
                offset: length > UInt64(ImageIntegrityConstants.tailWindow)
                    ? length - UInt64(ImageIntegrityConstants.tailWindow) : 0,
                want: ImageIntegrityConstants.tailWindow,
                length: length
            )
        else {
            return .corrupt(.empty)
        }
        return checkHeadTail(head: head, tail: tail, length: length)
    }

    static func checkHeadTail(head: [UInt8], tail: [UInt8], length: UInt64) -> Verdict {
        let found = ImageFormat.from(magic: head)
        switch found {
        case .png:
            // IEND is 12 bytes: length(4) + 'IEND'(4) + CRC(4), and must be last.
            let at = tail.count - 12
            if tail.count < 12 || Array(tail[(at + 4)..<(at + 8)]) != Array("IEND".utf8) {
                return .corrupt(.truncated(.png))
            }
            return .complete(found)
        case .jpeg:
            if !(tail.count >= 2 && tail[tail.count - 2] == 0xFF && tail[tail.count - 1] == 0xD9) {
                return .corrupt(.truncated(.jpeg))
            }
            return .complete(found)
        case .gif:
            if tail.last != 0x3B {
                return .corrupt(.truncated(.gif))
            }
            return .complete(found)
        case .webp:
            if head.count < 12 {
                return .corrupt(.tooSmall(head.count))
            }
            let declared = UInt64(le32(head, 4))
            // RIFF size counts everything after the first 8 bytes; a one-byte
            // pad for odd lengths is legal.
            if declared + 8 < length && declared + 9 != length {
                return .corrupt(.truncated(.webp))
            }
            return .complete(found)
        case .unknown:
            if let brand = opaqueImageBrand(head) {
                return .indeterminate(detail: brand)
            }
            return .corrupt(.notAnImage(hexPreview(head, 8)))
        }
    }

    /// Image containers that are recognisable but not walkable here, so a page in
    /// one of them must be kept rather than deleted as corrupt. Returns the brand.
    public static func opaqueImageBrand(_ bytes: [UInt8]) -> String? {
        if bytes.starts(with: Array("BM".utf8)) { return "bmp" }
        // JPEG XL raw codestream.
        if bytes.starts(with: [0xFF, 0x0A]) { return "jxl" }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            let imageBrands: [String] = [
                "avif", "avis", "heic", "heix", "heim", "heis", "mif1", "msf1", "jxl ", "crx ",
            ]
            if imageBrands.contains(brand) { return brand }
        }
        return nil
    }

    // MARK: - PNG

    /// PNG: signature, IHDR first, every chunk CRC, and IEND exactly last.
    static func inspectPNG(_ bytes: [UInt8]) -> Result<ImageInfo, Corruption> {
        let format = ImageFormat.png
        var pos = pngSignature.count
        var info = ImageInfo(format: format, width: 0, height: 0)
        var sawIHDR = false
        var sawIDAT = false
        while true {
            guard pos + 8 <= bytes.count else { return .failure(.truncated(format)) }
            let chunkLen = Int(be32(bytes, pos))
            let kind = Array(bytes[(pos + 4)..<(pos + 8)])
            let dataStart = pos + 8
            guard chunkLen <= bytes.count - dataStart else { return .failure(.truncated(format)) }
            let dataEnd = dataStart + chunkLen
            let crcEnd = dataEnd + 4
            if crcEnd > bytes.count { return .failure(.truncated(format)) }
            let data = Array(bytes[dataStart..<dataEnd])
            let storedCRC = be32(bytes, dataEnd)
            if crc32(kind + data) != storedCRC {
                return .failure(.checksum(format, name(kind)))
            }

            switch kind {
            case Array("IHDR".utf8):
                if sawIHDR {
                    return .failure(.invalid(format, "second IHDR"))
                }
                if data.count != 13 {
                    return .failure(.invalid(
                        format, "IHDR is \(data.count) bytes, not 13"
                    ))
                }
                info.width = be32(data, 0)
                info.height = be32(data, 4)
                if info.width == 0 || info.height == 0 {
                    return .failure(.invalid(format, "IHDR declares an empty image"))
                }
                sawIHDR = true
            case Array("IDAT".utf8):
                sawIDAT = true
            case Array("IEND".utf8):
                if !sawIHDR || !sawIDAT {
                    return .failure(.invalid(format, "IEND without IDAT"))
                }
                if crcEnd != bytes.count {
                    return .failure(.invalid(format, "bytes follow IEND"))
                }
                return .success(info)
            default:
                break
            }
            if !sawIHDR {
                return .failure(.invalid(format, "\(name(kind)) precedes IHDR"))
            }
            pos = crcEnd
        }
    }

    // MARK: - JPEG

    /// JPEG: marker segments up to the start of scan, then the end-of-image marker.
    static func inspectJPEG(_ bytes: [UInt8]) -> Result<ImageInfo, Corruption> {
        let format = ImageFormat.jpeg
        var info = ImageInfo(format: format, width: 0, height: 0)
        var pos = 2 // past FFD8
        while pos < bytes.count {
            guard bytes[pos] == 0xFF else {
                return .failure(.invalid(format, "marker expected at \(pos)"))
            }
            // 0xFF fill bytes may precede a marker.
            while pos < bytes.count, bytes[pos] == 0xFF { pos += 1 }
            if pos >= bytes.count { return .failure(.truncated(format)) }
            let marker = bytes[pos]
            pos += 1
            switch marker {
            case 0x01, 0xD8, 0xD9, 0x00:
                // Standalone markers carry no length.
                if marker == 0xD9 { return .success(info) }
                continue
            case 0xD0...0xD7:
                continue
            case 0xDA:
                // Start of scan: entropy-coded data follows, which is not
                // segment-walkable. Completeness then rests on the trailer.
                if bytes.count >= 2, bytes[bytes.count - 2] == 0xFF, bytes[bytes.count - 1] == 0xD9 {
                    return .success(info)
                }
                return .failure(.truncated(format))
            default:
                break
            }
            if pos + 2 > bytes.count { return .failure(.truncated(format)) }
            let segmentLen = Int(be16(bytes, pos))
            if segmentLen < 2 {
                return .failure(.invalid(
                    format, "segment length \(segmentLen) shorter than its own header"
                ))
            }
            let end = pos + segmentLen
            if end > bytes.count { return .failure(.truncated(format)) }
            // SOF0..SOF3 carry the frame dimensions; SOF1 is the progressive case.
            if (0xC0...0xC3).contains(marker), segmentLen >= 7 {
                info.height = UInt32(be16(bytes, pos + 3))
                info.width = UInt32(be16(bytes, pos + 5))
            }
            pos = end
        }
        return .failure(.truncated(format))
    }

    // MARK: - GIF / WebP

    static func inspectGIF(_ bytes: [UInt8]) -> Result<ImageInfo, Corruption> {
        let format = ImageFormat.gif
        if bytes.count < 13 { return .failure(.truncated(format)) }
        let width = UInt32(le16(bytes, 6))
        let height = UInt32(le16(bytes, 8))
        if width == 0 || height == 0 {
            return .failure(.invalid(format, "logical screen descriptor is empty"))
        }
        if bytes.last != 0x3B { return .failure(.truncated(format)) }
        return .success(ImageInfo(format: format, width: width, height: height))
    }

    static func inspectWebP(_ bytes: [UInt8]) -> Result<ImageInfo, Corruption> {
        let format = ImageFormat.webp
        if bytes.count < 20 { return .failure(.truncated(format)) }
        let riffSize = UInt64(le32(bytes, 4))
        if riffSize + 8 < UInt64(bytes.count) && riffSize + 9 != UInt64(bytes.count) {
            return .failure(.truncated(format))
        }
        let fourCC = Array(bytes[12..<16])
        var width: UInt32 = 0
        var height: UInt32 = 0
        switch fourCC {
        case Array("VP8X".utf8):
            if bytes.count >= 30 {
                // Canvas size is 24-bit little-endian minus one, at offsets 24 and 27.
                width = 1 + le24(bytes, 24)
                height = 1 + le24(bytes, 27)
            }
        case Array("VP8 ".utf8):
            if bytes.count >= 30 {
                width = UInt32(le16(bytes, 26)) & 0x3FFF
                height = UInt32(le16(bytes, 28)) & 0x3FFF
            }
        case Array("VP8L".utf8):
            // VP8L (lossless) packs 14-bit dimensions into the bit stream; the
            // container is still checked, the size is simply not claimed here.
            width = 0
            height = 0
        default:
            return .failure(.invalid(format, "unknown WebP chunk \(name(fourCC))"))
        }
        return .success(ImageInfo(format: format, width: width, height: height))
    }

    // MARK: - ImageIO

    /// What ImageIO says about a buffer. `decodable` is the keep signal for a
    /// container this module cannot walk; `rejectedAsDamaged` is the one that may
    /// turn a would-be hit into a miss.
    struct ImageIOSniff: Sendable {
        var format: ImageFormat
        var typeName: String
        var width: UInt32
        var height: UInt32
        /// `CGImageSourceStatus.rawValue`: 0 is `kCGImageStatusComplete`,
        /// -1 `kCGImageStatusIncomplete`, -3 `kCGImageStatusUnknownType`,
        /// -4 `kCGImageStatusInvalidData`, -5 `kCGImageStatusUnexpectedEOF`.
        var status: Int32
        var imageCount: Int

        var decodable: Bool {
            status == 0 && imageCount > 0 && !typeName.isEmpty
        }

        var rejectedAsDamaged: Bool {
            // -3 is `kCGImageStatusUnknownType`: no codec here, which is a reason
            // to keep the bytes and say nothing about them.
            status < 0 && status != -3
        }
    }

    static func imageIOSniff(_ bytes: [UInt8]) -> ImageIOSniff? {
        guard !bytes.isEmpty else { return nil }
        let data = Data(bytes)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let status = CGImageSourceGetStatus(source).rawValue
        let count = CGImageSourceGetCount(source)
        let typeName = (CGImageSourceGetType(source) as String?) ?? ""
        var width: UInt32 = 0
        var height: UInt32 = 0
        if count > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let value = properties[kCGImagePropertyPixelWidth] as? NSNumber {
                width = UInt32(max(value.int64Value, 0))
            }
            if let value = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                height = UInt32(max(value.int64Value, 0))
            }
        }
        return ImageIOSniff(
            format: format(forUTType: typeName),
            typeName: typeName,
            width: width,
            height: height,
            status: status,
            imageCount: count
        )
    }

    /// Map an ImageIO type identifier into this module's five-case vocabulary.
    /// Anything outside it stays `.unknown`, which the verdict layer reads as
    /// "recognised, not judgeable" rather than "not an image".
    public static func format(forUTType type: String) -> ImageFormat {
        switch type {
        case "public.png": return .png
        case "public.jpeg", "public.jpg", "public.exif": return .jpeg
        case "com.compuserve.gif": return .gif
        case "org.webmproject.webp", "public.webp": return .webp
        default: return .unknown
        }
    }

    // MARK: - Byte helpers

    /// PNG's CRC-32 (IEEE, reflected) over chunk type + data.
    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static let crc32Table: [UInt32] = {
        (0..<256).map { index in
            var c = UInt32(index)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : (c >> 1)
            }
            return c
        }
    }()

    static func readWindow(_ handle: FileHandle, offset: UInt64, want: Int, length: UInt64) -> [UInt8]? {
        do {
            try handle.seek(toOffset: offset)
            let take = min(UInt64(want), length > offset ? length - offset : 0)
            guard take > 0, let read = try handle.read(upToCount: Int(take)), !read.isEmpty else {
                return nil
            }
            return [UInt8](read)
        } catch {
            return nil
        }
    }

    static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16)
            | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
    }

    static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
            | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }

    static func be16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= bytes.count else { return 0 }
        return (UInt16(bytes[at]) << 8) | UInt16(bytes[at + 1])
    }

    static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        guard at + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    /// 24-bit little-endian unsigned, as WebP stores canvas dimensions.
    static func le24(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 3 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8) | (UInt32(bytes[at + 2]) << 16)
    }

    static func hexPreview(_ bytes: [UInt8], _ count: Int) -> String {
        bytes.prefix(count).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func name(_ fourCC: [UInt8]) -> String {
        String(decoding: fourCC, as: UTF8.self)
    }
}

public extension Corruption {
    static var empty: Corruption { Corruption(kind: .empty) }
    static func tooSmall(_ bytes: Int) -> Corruption {
        Corruption(kind: .tooSmall, detail: String(bytes))
    }
    static func tooSmall(_ bytes: UInt64) -> Corruption {
        Corruption(kind: .tooSmall, detail: String(bytes))
    }
    static func notAnImage(_ preview: String) -> Corruption {
        Corruption(kind: .notAnImage, detail: preview)
    }
    static func truncated(_ format: ImageFormat) -> Corruption {
        Corruption(kind: .truncated, format: format)
    }
    static func invalid(_ format: ImageFormat, _ detail: String) -> Corruption {
        Corruption(kind: .structureInvalid, format: format, detail: detail)
    }
    static func checksum(_ format: ImageFormat, _ chunk: String) -> Corruption {
        Corruption(kind: .checksumMismatch, format: format, detail: chunk)
    }
    static func shortRead(declared: Int64, cached: Int64) -> Corruption {
        Corruption(kind: .shortRead, declared: declared, cached: cached)
    }
}
