//! Image integrity: can these bytes be trusted as a complete picture?
//!
//! Stage 8 needs this because the page cache is the one place where a bad byte
//! stops being a transient failure and becomes permanent: a truncated download
//! or an HTML error page renamed to `.jpg` would be cached, hit forever, and
//! render as a broken image on every page turn. Every cache write and every
//! cache read therefore passes a verdict from here.
//!
//! The core never decodes a picture, so "valid" here means *structurally*
//! complete, which is decidable from the container alone:
//!
//! * the format is recognised from its magic bytes (not from a content type —
//!   the header is the only witness that cannot lie about what was written),
//! * the declared payload is actually present,
//! * the format's terminator is at the end of the buffer.
//!
//! Two entry points because they have different costs:
//!
//! * [`inspect`] runs on bytes already in memory, at store time, and walks the
//!   whole container including per-chunk CRCs;
//! * [`quick_check_file`] runs on every cache hit and reads only the head and
//!   tail of the file, so a 24 MB page costs two small reads instead of a copy.

use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Smallest buffer that can hold a PNG head plus an IHDR, or a JPEG APPn
/// segment. Anything smaller cannot be a well-formed image of any kind.
const MIN_IMAGE_BYTES: usize = 24;

/// How many bytes [`quick_check_file`] reads at each end of a file. PNG's `IEND`
/// and JPEG's `FFD9` need 12 and 2 bytes; WebP's `RIFF` size needs 12; the extra
/// room is for formats whose trailer is a little further in.
const TAIL_WINDOW: u64 = 64;
const HEAD_WINDOW: u64 = 64;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Png,
    Jpeg,
    Gif,
    WebP,
    /// Bytes whose container this module cannot judge.
    Unknown,
}

impl Format {
    pub fn as_str(&self) -> &'static str {
        match self {
            Format::Png => "png",
            Format::Jpeg => "jpeg",
            Format::Gif => "gif",
            Format::WebP => "webp",
            Format::Unknown => "unknown",
        }
    }

    /// The media type this container actually is. The download tree stores it with
    /// the page, and a manifest that said `png` would not match the `image/png` the
    /// server itself reported.
    pub fn content_type(&self) -> &'static str {
        match self {
            Format::Png => "image/png",
            Format::Jpeg => "image/jpeg",
            Format::Gif => "image/gif",
            Format::WebP => "image/webp",
            Format::Unknown => "application/octet-stream",
        }
    }

    pub fn extension(&self) -> Option<&'static str> {
        match self {
            Format::Png => Some("png"),
            Format::Jpeg => Some("jpg"),
            Format::Gif => Some("gif"),
            Format::WebP => Some("webp"),
            Format::Unknown => None,
        }
    }

    /// The format a response's `Content-Type` claims.
    pub fn from_content_type(content_type: &str) -> Self {
        let head = content_type
            .split(';')
            .next()
            .unwrap_or(content_type)
            .trim();
        match head {
            "image/png" => Format::Png,
            "image/jpeg" | "image/jpg" | "image/pjpeg" => Format::Jpeg,
            "image/gif" => Format::Gif,
            "image/webp" => Format::WebP,
            _ => Format::Unknown,
        }
    }

    /// The format the bytes themselves say they are.
    pub fn from_magic(bytes: &[u8]) -> Self {
        if bytes.starts_with(&PNG_SIGNATURE) {
            Format::Png
        } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
            Format::Jpeg
        } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
            Format::Gif
        } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            Format::WebP
        } else {
            Format::Unknown
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ImageInfo {
    pub format: Format,
    /// Zero when the container did not disclose dimensions where this module
    /// looks for them. Never a guess.
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Corruption {
    /// Nothing to work with — would look like a permanent cache hit.
    Empty,
    /// Smaller than any well-formed image of the declared format.
    TooSmall { bytes: usize },
    /// No recognised image container at the front. The classic cause is an
    /// error page or a login redirect body cached under a `.jpg` name.
    NotAnImage { first_bytes: String },
    /// The payload stops before the container's terminator.
    Truncated { format: Format },
    /// A chunk/segment header promises more bytes than the buffer holds.
    StructureInvalid { format: Format, detail: String },
    /// A checksum inside the container does not match its payload.
    ChecksumMismatch { format: Format, chunk: String },
    /// Shorter than the size the page manifest reported for this page.
    ShortRead { declared: i64, cached: i64 },
}

impl Corruption {
    pub fn describe(&self) -> String {
        match self {
            Corruption::Empty => "empty response".to_string(),
            Corruption::TooSmall { bytes } => format!("only {bytes} bytes"),
            Corruption::NotAnImage { first_bytes } => {
                format!("not an image (starts with {first_bytes})")
            }
            Corruption::Truncated { format } => format!("{} is truncated", format.as_str()),
            Corruption::StructureInvalid { format, detail } => {
                format!("{} structure invalid: {detail}", format.as_str())
            }
            Corruption::ChecksumMismatch { format, chunk } => {
                format!("{} checksum wrong in {chunk}", format.as_str())
            }
            Corruption::ShortRead { declared, cached } => {
                format!("cached {cached} bytes of a declared {declared}")
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Complete image, and the header agrees with the declared content type.
    Valid(ImageInfo),
    /// Complete image whose header names a different format than declared.
    /// Usable — the bytes win, because the decoder sniffs bytes too — but the
    /// caller should name the file after `info.format`, not after the header.
    Reclassified { info: ImageInfo, declared: String },
    /// Head and trailer confirm the file is whole, without a full walk. This is
    /// what a cache hit answers with: the deep checks already ran at store time.
    Complete(Format),
    /// An image container this module recognises but cannot walk (AVIF, HEIC,
    /// BMP, JPEG XL). Not proof of damage: the caller keeps it and simply cannot
    /// claim the bytes are complete.
    Indeterminate { detail: String },
    /// Unusable. The entry must be dropped, never served again.
    Corrupt(Corruption),
}

impl Verdict {
    /// Only an explicit corruption verdict is a reason to drop a cache entry.
    pub fn is_usable(&self) -> bool {
        !matches!(self, Verdict::Corrupt(_))
    }

    pub fn info(&self) -> Option<ImageInfo> {
        match self {
            Verdict::Valid(info) | Verdict::Reclassified { info, .. } => Some(*info),
            _ => None,
        }
    }

    /// Human-readable reason, for the reader's error state. Empty when usable.
    pub fn corruption_description(&self) -> String {
        match self {
            Verdict::Corrupt(corruption) => corruption.describe(),
            _ => String::new(),
        }
    }
}

const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

/// Judge in-memory bytes, optionally against the size the manifest declared for
/// this page (`declared_size` is `None` when the server did not report one).
pub fn inspect(bytes: &[u8], declared_content_type: &str, declared_size: Option<i64>) -> Verdict {
    if bytes.is_empty() {
        return Verdict::Corrupt(Corruption::Empty);
    }
    if bytes.len() < MIN_IMAGE_BYTES {
        return Verdict::Corrupt(Corruption::TooSmall { bytes: bytes.len() });
    }
    if let Some(declared) = declared_size.filter(|size| *size > 0) {
        if (bytes.len() as i64) < declared {
            return Verdict::Corrupt(Corruption::ShortRead {
                declared,
                cached: bytes.len() as i64,
            });
        }
    }

    let found = Format::from_magic(bytes);
    let info = match found {
        Format::Png => inspect_png(bytes),
        Format::Jpeg => inspect_jpeg(bytes),
        Format::Gif => inspect_gif(bytes),
        Format::WebP => inspect_webp(bytes),
        Format::Unknown => {
            if let Some(brand) = opaque_image_brand(bytes) {
                return Verdict::Indeterminate { detail: brand };
            }
            let preview: String = bytes
                .iter()
                .take(12)
                .map(|byte| format!("{byte:02X}"))
                .collect::<Vec<_>>()
                .join(" ");
            return Verdict::Corrupt(Corruption::NotAnImage {
                first_bytes: preview,
            });
        }
    };
    let info = match info {
        Ok(info) => info,
        Err(corruption) => return Verdict::Corrupt(corruption),
    };

    let declared_format = Format::from_content_type(declared_content_type);
    if declared_format != Format::Unknown && declared_format != found {
        return Verdict::Reclassified {
            info,
            declared: declared_content_type.to_string(),
        };
    }
    Verdict::Valid(info)
}

/// Cheap completeness check of a file already on disk: head and tail only.
///
/// This is what runs on the hot path (every cache hit), so it must not copy a
/// 24 MB page. It answers exactly one question — is this file plausibly still
/// the complete image the ledger says it is — and leaves the deep walk to
/// [`inspect`] at store time.
pub fn quick_check_file(path: &Path, declared_size: Option<i64>) -> Verdict {
    let Ok(meta) = std::fs::metadata(path) else {
        return Verdict::Corrupt(Corruption::Empty);
    };
    let len = meta.len();
    if len == 0 {
        return Verdict::Corrupt(Corruption::Empty);
    }
    if let Some(declared) = declared_size.filter(|size| *size > 0) {
        if (len as i64) < declared {
            return Verdict::Corrupt(Corruption::ShortRead {
                declared,
                cached: len as i64,
            });
        }
    }
    if len < MIN_IMAGE_BYTES as u64 {
        return Verdict::Corrupt(Corruption::TooSmall {
            bytes: len as usize,
        });
    }

    let head = match read_window(path, 0, HEAD_WINDOW, len) {
        Ok(bytes) => bytes,
        Err(_) => return Verdict::Corrupt(Corruption::Empty),
    };
    let tail = match read_window(path, len.saturating_sub(TAIL_WINDOW), TAIL_WINDOW, len) {
        Ok(bytes) => bytes,
        Err(_) => return Verdict::Corrupt(Corruption::Empty),
    };
    check_head_tail(&head, &tail, len)
}

fn check_head_tail(head: &[u8], tail: &[u8], len: u64) -> Verdict {
    let found = Format::from_magic(head);
    match found {
        Format::Png => {
            // IEND is 12 bytes: length(4) + 'IEND'(4) + CRC(4), and must be last.
            let iend_crc_position = tail.len().saturating_sub(12);
            if tail.len() < 12 || &tail[iend_crc_position + 4..iend_crc_position + 8] != b"IEND" {
                return Verdict::Corrupt(Corruption::Truncated {
                    format: Format::Png,
                });
            }
            Verdict::Complete(found)
        }
        Format::Jpeg => {
            if !tail.ends_with(&[0xFF, 0xD9]) {
                return Verdict::Corrupt(Corruption::Truncated {
                    format: Format::Jpeg,
                });
            }
            Verdict::Complete(found)
        }
        Format::Gif => {
            if !tail.last().is_some_and(|byte| *byte == 0x3B) {
                return Verdict::Corrupt(Corruption::Truncated {
                    format: Format::Gif,
                });
            }
            Verdict::Complete(found)
        }
        Format::WebP => {
            if head.len() < 12 {
                return Verdict::Corrupt(Corruption::TooSmall { bytes: head.len() });
            }
            let declared = u32::from_le_bytes(head[4..8].try_into().unwrap()) as u64;
            // RIFF size counts everything after the first 8 bytes; a one-byte
            // pad for odd lengths is legal.
            if declared + 8 < len && declared + 9 != len {
                return Verdict::Corrupt(Corruption::Truncated {
                    format: Format::WebP,
                });
            }
            Verdict::Complete(found)
        }
        Format::Unknown => {
            if let Some(brand) = opaque_image_brand(head) {
                return Verdict::Indeterminate { detail: brand };
            }
            let preview: String = head
                .iter()
                .take(8)
                .map(|byte| format!("{byte:02X}"))
                .collect::<Vec<_>>()
                .join(" ");
            Verdict::Corrupt(Corruption::NotAnImage {
                first_bytes: preview,
            })
        }
    }
}

/// Image containers that are recognisable but not walkable here, so a page in
/// one of them must be kept rather than deleted as corrupt. Returns the brand.
pub fn opaque_image_brand(bytes: &[u8]) -> Option<String> {
    if bytes.starts_with(b"BM") {
        return Some("bmp".to_string());
    }
    // JPEG XL raw codestream.
    if bytes.starts_with(&[0xFF, 0x0A]) {
        return Some("jxl".to_string());
    }
    if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        let brand = String::from_utf8_lossy(&bytes[8..12]).into_owned();
        const IMAGE_BRANDS: [&str; 10] = [
            "avif", "avis", "heic", "heix", "heim", "heis", "mif1", "msf1", "jxl ", "crx ",
        ];
        if IMAGE_BRANDS.contains(&brand.as_str()) {
            return Some(brand);
        }
    }
    None
}

fn read_window(path: &Path, start: u64, want: u64, len: u64) -> std::io::Result<Vec<u8>> {
    let mut file = std::fs::File::open(path)?;
    file.seek(SeekFrom::Start(start))?;
    let take = want.min(len.saturating_sub(start)) as usize;
    let mut buf = Vec::with_capacity(take);
    file.take(want).read_to_end(&mut buf)?;
    Ok(buf)
}

/// PNG: signature, IHDR first, every chunk CRC, and IEND exactly last.
fn inspect_png(bytes: &[u8]) -> Result<ImageInfo, Corruption> {
    let format = Format::Png;
    let mut pos = PNG_SIGNATURE.len();
    let mut info = ImageInfo {
        format,
        width: 0,
        height: 0,
    };
    let mut saw_ihdr = false;
    let mut saw_idat = false;
    loop {
        if pos + 8 > bytes.len() {
            return Err(Corruption::Truncated { format });
        }
        let chunk_len = u32::from_be_bytes(bytes[pos..pos + 4].try_into().unwrap()) as usize;
        let kind = &bytes[pos + 4..pos + 8];
        let data_end = match pos.checked_add(8).and_then(|v| v.checked_add(chunk_len)) {
            Some(end) if end <= bytes.len() => end,
            _ => return Err(Corruption::Truncated { format }),
        };
        let crc_end = data_end + 4;
        if crc_end > bytes.len() {
            return Err(Corruption::Truncated { format });
        }
        let data = &bytes[pos + 8..data_end];
        let stored_crc = u32::from_be_bytes(bytes[data_end..crc_end].try_into().unwrap());
        let mut crc_input = Vec::with_capacity(4 + data.len());
        crc_input.extend_from_slice(kind);
        crc_input.extend_from_slice(data);
        if crc32(&crc_input) != stored_crc {
            return Err(Corruption::ChecksumMismatch {
                format,
                chunk: String::from_utf8_lossy(kind).into_owned(),
            });
        }

        match kind {
            b"IHDR" => {
                if saw_ihdr {
                    return Err(Corruption::StructureInvalid {
                        format,
                        detail: "second IHDR".to_string(),
                    });
                }
                if data.len() != 13 {
                    return Err(Corruption::StructureInvalid {
                        format,
                        detail: format!("IHDR is {} bytes, not 13", data.len()),
                    });
                }
                info.width = u32::from_be_bytes(data[0..4].try_into().unwrap());
                info.height = u32::from_be_bytes(data[4..8].try_into().unwrap());
                if info.width == 0 || info.height == 0 {
                    return Err(Corruption::StructureInvalid {
                        format,
                        detail: "IHDR declares an empty image".to_string(),
                    });
                }
                saw_ihdr = true;
            }
            b"IDAT" => saw_idat = true,
            b"IEND" => {
                if !saw_ihdr || !saw_idat {
                    return Err(Corruption::StructureInvalid {
                        format,
                        detail: "IEND without IDAT".to_string(),
                    });
                }
                if crc_end != bytes.len() {
                    return Err(Corruption::StructureInvalid {
                        format,
                        detail: "bytes follow IEND".to_string(),
                    });
                }
                return Ok(info);
            }
            _ => {}
        }
        if !saw_ihdr && kind != b"IHDR" {
            return Err(Corruption::StructureInvalid {
                format,
                detail: format!("{} precedes IHDR", String::from_utf8_lossy(kind)),
            });
        }
        pos = crc_end;
    }
}

/// JPEG: marker segments up to the start of scan, then the end-of-image marker.
fn inspect_jpeg(bytes: &[u8]) -> Result<ImageInfo, Corruption> {
    let format = Format::Jpeg;
    let mut info = ImageInfo {
        format,
        width: 0,
        height: 0,
    };
    let mut pos = 2usize; // past FFD8
    while pos < bytes.len() {
        if bytes[pos] != 0xFF {
            return Err(Corruption::StructureInvalid {
                format,
                detail: format!("marker expected at {pos}"),
            });
        }
        // 0xFF fill bytes may precede a marker.
        while pos < bytes.len() && bytes[pos] == 0xFF {
            pos += 1;
        }
        if pos >= bytes.len() {
            return Err(Corruption::Truncated { format });
        }
        let marker = bytes[pos];
        pos += 1;
        match marker {
            0x01 | 0xD8 | 0xD9 | 0x00 => {
                // Standalone markers carry no length.
                if marker == 0xD9 {
                    return Ok(info);
                }
                continue;
            }
            0xD0..=0xD7 => continue,
            0xDA => {
                // Start of scan: entropy-coded data follows, which is not
                // segment-walkable. Completeness then rests on the trailer.
                return match bytes.len() >= 2
                    && bytes[bytes.len() - 2] == 0xFF
                    && bytes[bytes.len() - 1] == 0xD9
                {
                    true => Ok(info),
                    false => Err(Corruption::Truncated { format }),
                };
            }
            _ => {}
        }
        if pos + 2 > bytes.len() {
            return Err(Corruption::Truncated { format });
        }
        let segment_len = u16::from_be_bytes(bytes[pos..pos + 2].try_into().unwrap()) as usize;
        if segment_len < 2 {
            return Err(Corruption::StructureInvalid {
                format,
                detail: format!("segment length {segment_len} shorter than its own header"),
            });
        }
        let end = pos + segment_len;
        if end > bytes.len() {
            return Err(Corruption::Truncated { format });
        }
        // SOF0..SOF3 carry the frame dimensions; SOF1 is the progressive case.
        if matches!(marker, 0xC0..=0xC3) && segment_len >= 7 {
            info.height = u16::from_be_bytes(bytes[pos + 3..pos + 5].try_into().unwrap()) as u32;
            info.width = u16::from_be_bytes(bytes[pos + 5..pos + 7].try_into().unwrap()) as u32;
        }
        pos = end;
    }
    Err(Corruption::Truncated { format })
}

fn inspect_gif(bytes: &[u8]) -> Result<ImageInfo, Corruption> {
    let format = Format::Gif;
    if bytes.len() < 13 {
        return Err(Corruption::Truncated { format });
    }
    let width = u16::from_le_bytes(bytes[6..8].try_into().unwrap()) as u32;
    let height = u16::from_le_bytes(bytes[8..10].try_into().unwrap()) as u32;
    if width == 0 || height == 0 {
        return Err(Corruption::StructureInvalid {
            format,
            detail: "logical screen descriptor is empty".to_string(),
        });
    }
    if !bytes.last().is_some_and(|byte| *byte == 0x3B) {
        return Err(Corruption::Truncated { format });
    }
    Ok(ImageInfo {
        format,
        width,
        height,
    })
}

/// 24-bit little-endian unsigned, as WebP stores canvas dimensions.
fn le24(bytes: &[u8]) -> u32 {
    u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16)
}

fn inspect_webp(bytes: &[u8]) -> Result<ImageInfo, Corruption> {
    let format = Format::WebP;
    if bytes.len() < 20 {
        return Err(Corruption::Truncated { format });
    }
    let riff_size = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as u64;
    if riff_size + 8 < bytes.len() as u64 && riff_size + 9 != bytes.len() as u64 {
        return Err(Corruption::Truncated { format });
    }
    let fourcc = &bytes[12..16];
    let (width, height) = match fourcc {
        b"VP8X" if bytes.len() >= 30 => {
            // Canvas size is 24-bit little-endian minus one, at offsets 24 and 27.
            (1 + le24(&bytes[24..27]), 1 + le24(&bytes[27..30]))
        }
        b"VP8 " if bytes.len() >= 30 => (
            u16::from_le_bytes(bytes[26..28].try_into().unwrap()) as u32 & 0x3FFF,
            u16::from_le_bytes(bytes[28..30].try_into().unwrap()) as u32 & 0x3FFF,
        ),
        // VP8L (lossless) packs 14-bit dimensions into the bit stream; the
        // container is still checked, the size is simply not claimed here.
        b"VP8L" => (0, 0),
        other => {
            return Err(Corruption::StructureInvalid {
                format,
                detail: format!("unknown WebP chunk {}", String::from_utf8_lossy(other)),
            })
        }
    };
    if width == 0 || height == 0 {
        return Ok(ImageInfo {
            format,
            width: 0,
            height: 0,
        });
    }
    Ok(ImageInfo {
        format,
        width,
        height,
    })
}

const fn crc32_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0usize;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 != 0 {
                0xEDB8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
            k += 1;
        }
        table[i] = c;
        i += 1;
    }
    table
}

static CRC32_TABLE: [u32; 256] = crc32_table();

/// PNG's CRC-32 (IEEE, reflected) over chunk type + data.
pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        crc = CRC32_TABLE[((crc ^ byte as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    crc ^ 0xFFFF_FFFF
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::demo_png;

    fn png() -> Vec<u8> {
        demo_png::demo_page_bytes(7)
    }

    #[test]
    fn a_generated_png_is_valid_and_reports_its_size() {
        let bytes = png();
        let verdict = inspect(&bytes, "image/png", None);
        let info = match &verdict {
            Verdict::Valid(info) => *info,
            other => panic!("expected Valid, got {other:?}"),
        };
        assert_eq!(info.format, Format::Png);
        assert_eq!((info.width, info.height), demo_png::page_dimensions(7));
        assert!(verdict.is_usable());
    }

    /// The mutation check for the test above: the same bytes with one IDAT byte
    /// zeroed must NOT still be valid.
    #[test]
    fn one_flipped_byte_inside_idat_breaks_the_chunk_crc() {
        let mut bytes = png();
        let at = bytes.len() - 20;
        bytes[at] ^= 0xFF;
        assert!(matches!(
            inspect(&bytes, "image/png", None),
            Verdict::Corrupt(Corruption::ChecksumMismatch { .. })
                | Verdict::Corrupt(Corruption::StructureInvalid { .. })
        ));
    }

    #[test]
    fn a_truncated_png_is_caught() {
        let bytes = png();
        let cut = &bytes[..bytes.len() - 6];
        assert_eq!(
            inspect(cut, "image/png", None),
            Verdict::Corrupt(Corruption::Truncated {
                format: Format::Png
            })
        );
    }

    #[test]
    fn trailing_bytes_after_iend_are_invalid() {
        let mut bytes = png();
        bytes.extend_from_slice(b"garbage");
        assert!(matches!(
            inspect(&bytes, "image/png", None),
            Verdict::Corrupt(Corruption::StructureInvalid { .. })
        ));
    }

    #[test]
    fn an_error_page_cached_as_jpeg_is_not_an_image() {
        let body = b"<html><body>502 Bad Gateway</body></html>".to_vec();
        let verdict = inspect(&body, "image/jpeg", None);
        assert!(
            matches!(verdict, Verdict::Corrupt(Corruption::NotAnImage { .. })),
            "{verdict:?}"
        );
        // And the reason is printable for the UI's error state.
        assert!(verdict.corruption_description().contains("not an image"));
    }

    #[test]
    fn empty_and_undersized_payloads_are_refused() {
        assert_eq!(
            inspect(b"", "image/png", None),
            Verdict::Corrupt(Corruption::Empty)
        );
        assert!(matches!(
            inspect(b"PNG", "image/png", None),
            Verdict::Corrupt(Corruption::TooSmall { .. })
        ));
    }

    #[test]
    fn a_short_read_against_the_declared_size_is_corruption() {
        let bytes = png();
        let declared = (bytes.len() + 1) as i64;
        assert_eq!(
            inspect(&bytes, "image/png", Some(declared)),
            Verdict::Corrupt(Corruption::ShortRead {
                declared,
                cached: bytes.len() as i64
            })
        );
        // A larger-than-declared file stays fine: servers may pad.
        assert!(inspect(&bytes, "image/png", Some(1)).is_usable());
    }

    #[test]
    fn a_header_that_disagrees_with_the_content_type_is_reclassified_not_rejected() {
        let bytes = png();
        let verdict = inspect(&bytes, "image/jpeg", None);
        match verdict {
            Verdict::Reclassified { info, declared } => {
                assert_eq!(info.format, Format::Png);
                assert_eq!(declared, "image/jpeg");
                assert_eq!(info.format.extension().unwrap(), "png");
            }
            other => panic!("expected Reclassified, got {other:?}"),
        }
    }

    #[test]
    fn content_types_and_magic_map_to_the_same_formats() {
        for (content_type, expected) in [
            ("image/png", Format::Png),
            ("image/jpeg", Format::Jpeg),
            ("image/jpeg;charset=binary", Format::Jpeg),
            ("image/webp", Format::WebP),
            ("image/gif", Format::Gif),
            ("application/octet-stream", Format::Unknown),
        ] {
            assert_eq!(
                Format::from_content_type(content_type),
                expected,
                "{content_type}"
            );
        }
        assert_eq!(Format::from_magic(&png()), Format::Png);
        assert_eq!(
            Format::from_magic(b"GIF89a...........;"),
            Format::Gif,
            "gif magic"
        );
        assert_eq!(
            Format::from_magic(b"RIFF\x10\x00\x00\x00WEBPVP8 "),
            Format::WebP
        );
    }

    #[test]
    fn quick_check_file_agrees_with_the_full_walk_for_good_and_cut_files() {
        let dir = std::env::temp_dir().join(format!("komga_integrity_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let whole = dir.join("whole.png");
        let cut = dir.join("cut.png");
        let bytes = png();
        std::fs::write(&whole, &bytes).unwrap();
        std::fs::write(&cut, &bytes[..bytes.len() - 6]).unwrap();

        assert!(quick_check_file(&whole, None).is_usable());
        assert_eq!(
            quick_check_file(&cut, None),
            Verdict::Corrupt(Corruption::Truncated {
                format: Format::Png
            })
        );
        assert_eq!(
            quick_check_file(&dir.join("missing.png"), None),
            Verdict::Corrupt(Corruption::Empty)
        );
        let empty = dir.join("empty.png");
        std::fs::write(&empty, b"").unwrap();
        assert!(matches!(
            quick_check_file(&empty, None),
            Verdict::Corrupt(Corruption::Empty)
        ));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn quick_check_catches_a_truncated_jpeg_and_a_bogus_file() {
        let dir =
            std::env::temp_dir().join(format!("komga_integrity_jpeg_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        // Long enough to clear MIN_IMAGE_BYTES, and ending on the EOI marker.
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0];
        jpeg.extend_from_slice(&[0x00, 0x04, 0x00, 0x00]);
        jpeg.extend_from_slice(&[0x20; 20]);
        jpeg.extend_from_slice(&[0xFF, 0xD9]);
        let good = dir.join("good.jpg");
        let bad = dir.join("bad.jpg");
        std::fs::write(&good, &jpeg).unwrap();
        std::fs::write(&bad, &jpeg[..jpeg.len() - 2]).unwrap();
        assert!(quick_check_file(&good, None).is_usable());
        assert_eq!(
            quick_check_file(&bad, None),
            Verdict::Corrupt(Corruption::Truncated {
                format: Format::Jpeg
            })
        );
        let html = dir.join("html.jpg");
        std::fs::write(&html, b"<html><body>login required</body></html>").unwrap();
        assert!(matches!(
            quick_check_file(&html, None),
            Verdict::Corrupt(Corruption::NotAnImage { .. })
        ));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn jpeg_segment_walk_reads_frame_dimensions_and_rejects_a_broken_length() {
        // SOF0 declaring 1200x1600, then SOS, then a proper trailer.
        let mut jpeg = vec![0xFF, 0xD8];
        // Lf = 14 covers the two length bytes plus the 12 that follow.
        jpeg.extend_from_slice(&[0xFF, 0xC0, 0x00, 0x0E, 0x08]);
        jpeg.extend_from_slice(&1600u16.to_be_bytes());
        jpeg.extend_from_slice(&1200u16.to_be_bytes());
        jpeg.extend_from_slice(&[0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
        jpeg.extend_from_slice(&[0xFF, 0xDA, 0x00, 0x04, 0x00, 0x00]);
        jpeg.extend_from_slice(&[0x01, 0x02, 0x03, 0xFF, 0xD9]);
        assert_eq!(
            inspect(&jpeg, "image/jpeg", None),
            Verdict::Valid(ImageInfo {
                format: Format::Jpeg,
                width: 1200,
                height: 1600
            })
        );

        // Same frame, but the scan data never terminates.
        let mut cut = jpeg.clone();
        cut.truncate(cut.len() - 2);
        assert_eq!(
            inspect(&cut, "image/jpeg", None),
            Verdict::Corrupt(Corruption::Truncated {
                format: Format::Jpeg
            })
        );

        // A segment header claiming more bytes than exist.
        let mut liar = vec![0xFF, 0xD8, 0xFF, 0xE0];
        liar.extend_from_slice(&[0x7F, 0xFF]);
        liar.extend_from_slice(&[0x00; 20]);
        assert!(matches!(
            inspect(&liar, "image/jpeg", None),
            Verdict::Corrupt(Corruption::Truncated { .. })
        ));
    }

    #[test]
    fn crc32_matches_the_known_vector() {
        assert_eq!(crc32(b"IEND"), 0xAE_42_60_82);
        assert_eq!(crc32(b"123456789"), 0xCB_F4_39_26);
    }
}
