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

fn encode_rgb_png(width: u32, height: u32, (r, g, b): (u8, u8, u8)) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&PNG_SIGNATURE);

    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]); // bit depth 8, color type 2 (RGB)
    push_chunk(&mut out, b"IHDR", &ihdr);

    // Raw scanlines, each prefixed with filter byte 0 (None).
    let stride = width as usize * 3;
    let pixel = [r, g, b];
    let mut raw = Vec::with_capacity((stride + 1) * height as usize);
    for _ in 0..height {
        raw.extend_from_slice(&[0]);
        for _ in 0..width {
            raw.extend_from_slice(&pixel);
        }
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
    fn color_from_seed_is_stable() {
        // FNV-1a over "series-1" -> fixed hue; assert the exact color so any
        // accidental algorithm change is caught.
        let hash = fnv1a(b"series-1");
        let hue = (hash % 360) as f64 / 360.0;
        let (r, g, b) = hsv_to_rgb(hue, 0.55, 0.85);
        assert_eq!((r, g, b), color_from_seed("series-1"));
    }
}
