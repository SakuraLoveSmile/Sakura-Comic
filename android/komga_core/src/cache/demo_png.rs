//! Deterministic demo covers (offline mode): valid PNG bytes generated in
//! pure Rust with no image crate. Mirrors the Swift app's `DemoCoverFetcher`
//! (solid color derived from a seed), so the cover wall is demonstrable
//! without a Komga server.
//!
//! The encoder writes RGB8 PNGs with non-interleaved stored (uncompressed)
//! deflate blocks — simple, correct, and deterministic.

const WIDTH: u32 = 200;
const HEIGHT: u32 = 300;

const PNG_SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];

/// Demo cover bytes (200x300 RGB PNG) for a seed (typically the cover URL).
pub fn demo_cover_bytes(seed: &str) -> Vec<u8> {
    let (r, g, b) = color_from_seed(seed);
    encode_rgb_png(WIDTH, HEIGHT, (r, g, b))
}

/// Size of the fixture image for one page.
///
/// The width encodes the page number, so a reader can prove from the decoded
/// bytes that page N is the page it asked for. An off-by-one between the
/// manifest and the image endpoint is invisible in a wall of identical images
/// and unmistakable here.
pub fn page_dimensions(number: u32) -> (u32, u32) {
    (64 + number, 96 + (number % 5))
}

/// Fixture page image (RGB PNG) for one canonical 1-based page number.
pub fn demo_page_bytes(number: u32) -> Vec<u8> {
    let (width, height) = page_dimensions(number);
    let (r, g, b) = color_from_seed(&format!("page-{number}"));
    encode_rgb_png(width, height, (r, g, b))
}

/// A page of *real* pixel dimensions, for the 4K and tall-strip stress phases.
///
/// The size is not simulated: a 3840x2160 RGB page here is the ~25 MB response a
/// scanner-quality comic actually is, because the encoder emits stored (uncompressed)
/// deflate blocks. That is what makes "one page larger than the whole memory tier"
/// a case the cache has to answer to rather than a number in a comment.
pub fn large_page_bytes(number: u32, width: u32, height: u32) -> Vec<u8> {
    let (r, g, b) = color_from_seed(&format!("page-{number}"));
    encode_rgb_png(width, height, (r, g, b))
}

/// A page padded with a legal ancillary `tEXt` chunk to at least `min_bytes`.
///
/// Padding rather than pixels, because a stress run often needs the *byte volume*
/// of a big response ( eviction, budget, transfer cost ) without needing a big
/// bitmap, and generating thousands of real 4K frames in a test would cost more
/// than it measures.
pub fn padded_page_bytes(number: u32, min_bytes: usize) -> Vec<u8> {
    let (width, height) = page_dimensions(number);
    large_page_bytes_padded(number, width, height, min_bytes)
}

/// A page of the given dimensions, padded to at least `min_bytes` **without
/// changing what it declares itself to be**.
///
/// Padding has to ride in an ancillary chunk of the same image: a "4K page"
/// implemented by falling back to a small bitmap plus filler would let a size
/// ceiling be tested against a lie.
pub fn large_page_bytes_padded(number: u32, width: u32, height: u32, min_bytes: usize) -> Vec<u8> {
    let (r, g, b) = color_from_seed(&format!("page-{number}"));
    let bare = large_page_len(width, height);
    // A tEXt chunk costs 12 framing bytes plus "pad" + NUL + the filler itself.
    let pad = min_bytes.saturating_sub(bare + 16);
    encode_rgb_png_padded(width, height, (r, g, b), pad)
}

/// Exact length [`large_page_bytes_padded`] will produce.
pub fn large_page_padded_len(width: u32, height: u32, min_bytes: usize) -> usize {
    large_page_len(width, height).max(min_bytes)
}

/// Exact byte length [`large_page_bytes`] will produce, without producing it.
/// The manifest endpoint has to declare a page's size for all 500 pages, and
/// generating 500 real 4K frames to count their bytes is not a thing.
pub fn large_page_len(width: u32, height: u32) -> usize {
    let raw = (height as usize) * (1 + (width as usize) * 3);
    let header = PNG_SIGNATURE.len()
        + 12 + 13 // IHDR
        + 12; // IEND
    header + 12 + zlib_stored_len(raw)
}

fn zlib_stored_len(raw: usize) -> usize {
    // Stored blocks: 2 zlib bytes, then 5 header bytes per block plus its
    // payload, then the adler32 tail. At least one block, even for nothing.
    let blocks = raw.div_ceil(0xFFFF).max(1);
    2 + blocks * 5 + raw + 4
}

fn encode_rgb_png(width: u32, height: u32, rgb: (u8, u8, u8)) -> Vec<u8> {
    encode_rgb_png_padded(width, height, rgb, 0)
}

fn encode_rgb_png_padded(
    width: u32,
    height: u32,
    (r, g, b): (u8, u8, u8),
    text_pad: usize,
) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&PNG_SIGNATURE);

    if text_pad > 0 {
        // tEXt: keyword, NUL, then filler. Ancillary, so it may sit before IDAT.
        let mut text = b"pad\x00".to_vec();
        text.extend(std::iter::repeat(b'x').take(text_pad));
        push_chunk(&mut out, b"tEXt", &text);
    }

    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]); // bit depth 8, color type 2 (RGB)
    push_chunk(&mut out, b"IHDR", &ihdr);

    // Raw scanlines, each prefixed with filter byte 0 (None).
    let stride = width as usize * 3;
    let pixel = [r, g, b];
    let mut raw = Vec::with_capacity((stride + 1) * height as usize);
    let row = {
        let mut row = Vec::with_capacity(stride + 1);
        row.push(0);
        for _ in 0..width {
            row.extend_from_slice(&pixel);
        }
        row
    };
    for _ in 0..height {
        raw.extend_from_slice(&row);
    }
    push_chunk(&mut out, b"IDAT", &zlib_stored(&raw));
    push_chunk(&mut out, b"IEND", &[]);
    out
}

/// zlib wrapper with deflate stored (BTYPE=00) blocks of <= 65535 bytes.
fn zlib_stored(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + data.len() / 0xFFFF * 5 + 8);
    out.extend_from_slice(&[0x78, 0x01]); // CMF/FLG: deflate, 32K window, no dict
    const BLOCK: usize = 0xFFFF;
    let mut pos = 0;
    loop {
        let len = (data.len() - pos).min(BLOCK);
        let final_bit: u8 = if pos + len == data.len() { 1 } else { 0 };
        out.push(final_bit); // BFINAL | BTYPE=00
        out.extend_from_slice(&(len as u16).to_le_bytes());
        out.extend_from_slice(&(!(len as u16)).to_le_bytes());
        out.extend_from_slice(&data[pos..pos + len]);
        pos += len;
        if pos == data.len() {
            break;
        }
    }
    out.extend_from_slice(&adler32(data).to_be_bytes());
    out
}

fn push_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut crc_input = Vec::with_capacity(kind.len() + data.len());
    crc_input.extend_from_slice(kind);
    crc_input.extend_from_slice(data);
    out.extend_from_slice(&crc32(&crc_input).to_be_bytes());
}

fn crc32(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (i, entry) in table.iter_mut().enumerate() {
        let mut c = i as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 {
                0xEDB8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
        }
        *entry = c;
    }
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in data {
        crc = table[((crc ^ byte as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    crc ^ 0xFFFF_FFFF
}

fn adler32(data: &[u8]) -> u32 {
    const MOD: u32 = 65521;
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in data {
        a = (a + byte as u32) % MOD;
        b = (b + a) % MOD;
    }
    (b << 16) | a
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash = 0xCBF2_9CE4_8422_2325u64;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
    }
    hash
}

fn color_from_seed(seed: &str) -> (u8, u8, u8) {
    let hash = fnv1a(seed.as_bytes());
    let hue = (hash % 360) as f64 / 360.0;
    hsv_to_rgb(hue, 0.55, 0.85)
}

fn hsv_to_rgb(h: f64, s: f64, v: f64) -> (u8, u8, u8) {
    let i = (h * 6.0).floor() as i32;
    let f = h * 6.0 - i as f64;
    let p = v * (1.0 - s);
    let q = v * (1.0 - f * s);
    let t = v * (1.0 - (1.0 - f) * s);
    let (r, g, b) = match i.rem_euclid(6) {
        0 => (v, t, p),
        1 => (q, v, p),
        2 => (p, v, t),
        3 => (p, q, v),
        4 => (t, p, v),
        _ => (v, p, q),
    };
    ((r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Walk the PNG chunk stream; verify structure and CRCs. Returns
    /// (ihdr_width, ihdr_height, idat_bytes) so callers can dig deeper.
    fn parse_png(bytes: &[u8]) -> (u32, u32, Vec<u8>) {
        assert_eq!(&bytes[..8], &PNG_SIGNATURE, "PNG signature");
        let mut pos = 8usize;
        let mut seen_ihdr = false;
        let mut idat = Vec::new();
        while pos + 8 <= bytes.len() {
            let len = u32::from_be_bytes(bytes[pos..pos + 4].try_into().unwrap()) as usize;
            let kind = &bytes[pos + 4..pos + 8];
            let data = &bytes[pos + 8..pos + 8 + len];
            let expected_crc =
                u32::from_be_bytes(bytes[pos + 8 + len..pos + 12 + len].try_into().unwrap());
            let mut crc_input = kind.to_vec();
            crc_input.extend_from_slice(data);
            assert_eq!(crc32(&crc_input), expected_crc, "CRC of chunk {:?}", kind);
            match kind {
                b"IHDR" => {
                    assert!(!seen_ihdr);
                    seen_ihdr = true;
                    let width = u32::from_be_bytes(data[0..4].try_into().unwrap());
                    let height = u32::from_be_bytes(data[4..8].try_into().unwrap());
                    assert_eq!(&data[8..13], &[8, 2, 0, 0, 0], "8-bit RGB, no interlace");
                    assert_eq!((width, height), (WIDTH, HEIGHT));
                }
                b"IDAT" => idat.extend_from_slice(data),
                b"IEND" => {
                    assert!(data.is_empty());
                    assert_eq!(pos + 12 + len, bytes.len(), "IEND must be the last chunk");
                }
                _ => {}
            }
            pos += 12 + len;
        }
        assert!(seen_ihdr, "IHDR present");
        assert!(!idat.is_empty(), "IDAT present");
        (WIDTH, HEIGHT, idat)
    }

    /// Walk the chunk stream of an image of any size, checking structure/CRCs.
    fn parse_png_at(bytes: &[u8]) -> (u32, u32, Vec<u8>) {
        assert_eq!(&bytes[..8], &PNG_SIGNATURE);
        let mut pos = 8usize;
        let mut width = 0u32;
        let mut height = 0u32;
        let mut idat = Vec::new();
        let mut saw_iend = false;
        while pos + 8 <= bytes.len() {
            let len = u32::from_be_bytes(bytes[pos..pos + 4].try_into().unwrap()) as usize;
            let kind = &bytes[pos + 4..pos + 8];
            let data = &bytes[pos + 8..pos + 8 + len];
            let expected =
                u32::from_be_bytes(bytes[pos + 8 + len..pos + 12 + len].try_into().unwrap());
            let mut crc_input = kind.to_vec();
            crc_input.extend_from_slice(data);
            assert_eq!(crc32(&crc_input), expected, "CRC of {:?}", kind);
            match kind {
                b"IHDR" => {
                    width = u32::from_be_bytes(data[0..4].try_into().unwrap());
                    height = u32::from_be_bytes(data[4..8].try_into().unwrap());
                }
                b"IDAT" => idat.extend_from_slice(data),
                b"IEND" => {
                    saw_iend = true;
                    assert_eq!(pos + 12 + len, bytes.len(), "IEND is last");
                }
                _ => {}
            }
            pos += 12 + len;
        }
        assert!(saw_iend, "IEND present");
        (width, height, idat)
    }

    fn unzlib_stored(idat: &[u8]) -> Vec<u8> {
        assert_eq!(&idat[..2], &[0x78, 0x01], "zlib header");
        let mut pos = 2usize;
        let mut raw = Vec::new();
        loop {
            let header = idat[pos];
            pos += 1;
            // Bits 1-2 are BTYPE; stored (00) is the only type we emit.
            assert_eq!(header & 0x06, 0, "BTYPE must be stored (00)");
            let len = u16::from_le_bytes(idat[pos..pos + 2].try_into().unwrap()) as usize;
            let nlen = u16::from_le_bytes(idat[pos + 2..pos + 4].try_into().unwrap()) as usize;
            pos += 4;
            assert_eq!(
                len ^ 0xFFFF,
                nlen,
                "NLEN must be the one's complement of LEN"
            );
            raw.extend_from_slice(&idat[pos..pos + len]);
            pos += len;
            if header & 1 != 0 {
                break;
            }
        }
        let expected_adler = u32::from_be_bytes(idat[pos..pos + 4].try_into().unwrap());
        assert_eq!(expected_adler, adler32(&raw), "zlib adler32");
        raw
    }

    #[test]
    fn generates_structurally_valid_png() {
        let bytes = demo_cover_bytes("https://demo.local/api/v1/series/s-berserk/thumbnail");
        let (_w, _h, idat) = parse_png(&bytes);
        let raw = unzlib_stored(&idat);
        // 300 rows of (filter byte + 200*3 RGB)
        assert_eq!(raw.len(), 300 * (1 + 200 * 3));
    }

    #[test]
    fn deterministic_and_seed_varied() {
        let a = demo_cover_bytes("seed-a");
        let b = demo_cover_bytes("seed-a");
        assert_eq!(a, b, "same seed must produce identical bytes");
        let c = demo_cover_bytes("seed-b");
        assert_ne!(a, c, "different seeds must produce different bytes");
    }

    #[test]
    fn padding_reaches_the_requested_volume_and_stays_valid() {
        let padded = padded_page_bytes(4, 40_000);
        assert!(padded.len() >= 40_000, "got {}", padded.len());
        // Still a walkable PNG: signature, IHDR, tEXt, IDAT, IEND.
        let (_w, _h, idat) = parse_png_at(&padded);
        assert!(!idat.is_empty());
        // Padding is an ancillary chunk, so the image data stays exactly what it
        // was: the same page at the same dimensions, just heavier on the wire.
        // Compared by length and checksum so a failure prints numbers, not 25 MB.
        let plain_raw = unzlib_stored_idat(&demo_page_bytes(4));
        let padded_raw = unzlib_stored(&idat);
        assert_eq!(padded_raw.len(), plain_raw.len());
        assert_eq!(adler32(&padded_raw), adler32(&plain_raw));
    }

    #[test]
    fn the_declared_length_formula_is_exact() {
        for (width, height) in [(64u32, 96u32), (100, 150), (1080, 2400)] {
            let real = large_page_bytes(7, width, height).len();
            assert_eq!(real, large_page_len(width, height), "{width}x{height}");
        }
        // The 4K case the stress phase uses: 2160 rows of 3840 RGB pixels plus a
        // filter byte each. Just under 24 MiB, comfortably over 24 million bytes,
        // and deliberately stated in both units because a MiB/MB slip is exactly
        // the kind of error a size ceiling is made of.
        let four_k = large_page_len(3840, 2160);
        assert!(four_k > 24_000_000, "4K page is {four_k} bytes");
        assert!(
            four_k > 23 * 1024 * 1024 && four_k < 24 * 1024 * 1024,
            "4K page is {four_k} bytes"
        );
    }

    /// The IDAT payload of a page, for comparing a padded page against the plain
    /// bytes of the same page number.
    fn unzlib_stored_idat(bytes: &[u8]) -> Vec<u8> {
        let (_w, _h, idat) = parse_png_at(bytes);
        unzlib_stored(&idat)
    }

    #[test]
    fn a_padded_page_still_reports_its_real_dimensions() {
        let bytes = padded_page_bytes(2, 5_000);
        let width = u32::from_be_bytes(bytes[16..20].try_into().unwrap());
        let height = u32::from_be_bytes(bytes[20..24].try_into().unwrap());
        assert_eq!((width, height), page_dimensions(2));
    }

    #[test]
    fn color_from_seed_is_stable() {
        // FNV-1a over "series-1" -> fixed hue; assert the exact color so any
        // accidental algorithm change is caught.
        let hash = fnv1a(b"series-1");
        let hue = (hash % 360) as f64 / 360.0;
        let (r, g, b) = hsv_to_rgb(hue, 0.55, 0.85);
        assert_eq!((r, g, b), color_from_seed("series-1"));
    }
}
