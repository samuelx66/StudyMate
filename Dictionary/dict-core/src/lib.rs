//! StudyMate's cross-platform dictionary core.
//!
//! The core deliberately knows nothing about SwiftUI, AppKit, or the host
//! operating system. It imports standard MDX/MDD v2 files into a small,
//! portable directory package and exposes deterministic exact/prefix lookup.
//! The JSONL process in studymate-dict is only one adapter; mobile and
//! Windows clients can link this crate through a C ABI in a later release.

use anyhow::{anyhow, bail, Context, Result};
use encoding_rs::{BIG5, GBK, UTF_16LE, UTF_8};
use flate2::read::ZlibDecoder;
use ripemd::{Digest, Ripemd128};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::{hash_map::DefaultHasher, HashMap};
use std::fs::{self, File, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const PACKAGE_VERSION: u32 = 3;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DictionaryManifest {
    pub version: u32,
    pub id: String,
    pub title: String,
    pub source_file: String,
    pub encoding: String,
    pub format: String,
    pub entry_count: u64,
    pub resource_count: u64,
    pub imported_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DictionarySummary {
    pub id: String,
    pub title: String,
    pub encoding: String,
    pub format: String,
    pub entry_count: u64,
    pub resource_count: u64,
    pub imported_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LookupEntry {
    pub key: String,
    pub text: String,
    pub dictionary_id: String,
    pub dictionary_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub css: Option<String>,
    /// Absolute package resources directory.  Keeping this with the lookup
    /// result avoids guessing a package path from a sanitized dictionary id
    /// in the UI (ids may contain punctuation and unicode).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_root: Option<String>,
}

/// Lightweight dictionary row used by live search. Full record HTML is
/// fetched only after the user selects a key.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LookupKey {
    pub key: String,
    pub dictionary_id: String,
    pub dictionary_title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_root: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportResult {
    pub dictionary: DictionarySummary,
    pub package_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceResult {
    pub key: String,
    pub path: String,
    pub size: u64,
}

#[derive(Debug, Clone)]
pub struct ImportOptions {
    pub root: PathBuf,
    pub mdx: PathBuf,
    pub mdd: Vec<PathBuf>,
    pub id: Option<String>,
    /// Optional MDict registration code (32 hexadecimal digits).  It is used
    /// only when `Encrypted` includes the keyword-header bit (1).
    pub registration_code: Option<String>,
    /// User identity used by MDict to unwrap the registration code.  This is
    /// normally an e-mail address or device id.  An empty identity is tried
    /// when the dictionary does not require a user-specific license.
    pub user_id: Option<String>,
}

#[derive(Debug, Clone)]
struct Header {
    title: String,
    encoding: String,
    format: String,
    encrypted: u8,
    is_mdd: bool,
    registration_code: Option<Vec<u8>>,
    register_by: Option<String>,
}

#[derive(Debug, Clone)]
struct RawKey {
    key: String,
    offset: u64,
}

struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    fn remaining(&self) -> usize {
        self.bytes.len().saturating_sub(self.pos)
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8]> {
        let end = self
            .pos
            .checked_add(count)
            .ok_or_else(|| anyhow!("MDX offset overflow"))?;
        if end > self.bytes.len() {
            bail!(
                "MDX block is truncated (wanted {} bytes at {})",
                count,
                self.pos
            )
        }
        let out = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(out)
    }

    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().unwrap()))
    }

    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }

    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }
}

fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default()
}

fn normalize_key(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn escape_like_pattern(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('%', "\\%")
        .replace('_', "\\_")
}

fn configure_read_connection(connection: &Connection) -> Result<()> {
    // Prefix lookup is deliberately case-sensitive because `normalized` is
    // already lower-cased by normalize_key.  With this pragma SQLite can use
    // idx_entries_normalized for `LIKE 'prefix%'` instead of scanning every
    // row in large imported dictionaries.
    connection.execute_batch(
        "PRAGMA busy_timeout = 5000;
         PRAGMA case_sensitive_like = ON;
         PRAGMA query_only = ON;
         PRAGMA temp_store = MEMORY;",
    )?;
    Ok(())
}

fn sanitize_id(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') {
            out.push(ch.to_ascii_lowercase());
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        "dictionary".to_owned()
    } else {
        trimmed.chars().take(80).collect()
    }
}

fn stable_id(path: &Path) -> String {
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("dictionary");
    let mut hasher = DefaultHasher::new();
    path.to_string_lossy().hash(&mut hasher);
    format!("{}-{:08x}", sanitize_id(stem), hasher.finish() as u32)
}

/// Return the resource volumes belonging to an MDX file.
///
/// MDict normally names these `<stem>.mdd`, `<stem>.1.mdd`, ... .  The
/// explicit paths are retained as well because some vendors keep resources
/// in a separate directory or use a non-standard filename.  Directory
/// enumeration can be denied by the macOS sandbox, so the fallback probes a
/// bounded range of conventional numbered names instead of silently losing
/// the resource volumes.
pub fn discover_mdd_paths(mdx: &Path, explicit: &[PathBuf]) -> Vec<PathBuf> {
    let directory = mdx.parent().unwrap_or_else(|| Path::new("."));
    let stem = mdx
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    let lower_stem = stem.to_lowercase();
    let mut discovered: Vec<(PathBuf, usize)> = Vec::new();
    let mut sibling_mdds = Vec::new();
    let mut found_conventional_volume = false;

    if let Ok(entries) = fs::read_dir(directory) {
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file()
                || !path
                    .extension()
                    .and_then(|value| value.to_str())
                    .map(|value| value.eq_ignore_ascii_case("mdd"))
                    .unwrap_or(false)
            {
                continue;
            }
            sibling_mdds.push(path.clone());
            let sibling_stem = path
                .file_stem()
                .and_then(|value| value.to_str())
                .unwrap_or("");
            let lower_sibling_stem = sibling_stem.to_lowercase();
            let order = if lower_sibling_stem == lower_stem {
                Some(0)
            } else {
                lower_sibling_stem
                    .strip_prefix(&(lower_stem.clone() + "."))
                    .and_then(|value| value.parse::<usize>().ok())
                    .filter(|value| *value > 0)
                    .map(|value| value.saturating_add(1))
            };
            if let Some(order) = order {
                found_conventional_volume = true;
                discovered.push((path, order));
            }
        }

        // Some dictionary vendors use a descriptive resource filename (for
        // example `resources.mdd`) instead of the standard `<stem>.mdd`.
        // If no conventional volume was found, retain every MDD beside the
        // selected MDX as a resource candidate. This is deliberately a
        // fallback: when standard volumes exist we must not import unrelated
        // MDD files that happen to share the directory.
        if !found_conventional_volume {
            for path in sibling_mdds {
                discovered.push((path, usize::MAX));
            }
        }
    } else {
        // The parent may be visible as a security-scoped file URL while
        // contentsOfDirectory/read_dir is unavailable.  Probe enough
        // numbered volumes for normal MDict packages and do not stop at the
        // first gap (vendors occasionally omit a volume number).
        for number in 0usize..=64 {
            let filename = if number == 0 {
                format!("{stem}.mdd")
            } else {
                format!("{stem}.{number}.mdd")
            };
            let path = directory.join(filename);
            if path.is_file() {
                discovered.push((path, number.saturating_add(1)));
            }
        }
    }

    // Explicit selections may include a conventional sibling or a vendor's
    // non-standard resource volume. Put both sources through the same stable
    // ordering before deduplicating so the import order is reproducible.
    for path in explicit {
        let sibling_stem = path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("")
            .to_lowercase();
        let order = if sibling_stem == lower_stem {
            0
        } else {
            sibling_stem
                .strip_prefix(&(lower_stem.clone() + "."))
                .and_then(|value| value.parse::<usize>().ok())
                .filter(|value| *value > 0)
                .map(|value| value.saturating_add(1))
                .unwrap_or(usize::MAX)
        };
        discovered.push((path.clone(), order));
    }

    discovered.sort_by(|lhs, rhs| {
        lhs.1
            .cmp(&rhs.1)
            .then_with(|| lhs.0.to_string_lossy().cmp(&rhs.0.to_string_lossy()))
    });

    let mut result = Vec::new();
    let mut add_unique = |path: PathBuf| {
        let identity = fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
        if !result.iter().any(|existing: &PathBuf| {
            fs::canonicalize(existing).unwrap_or_else(|_| existing.clone()) == identity
        }) {
            result.push(path);
        }
    };
    for (path, _) in discovered {
        add_unique(path);
    }
    result
}

// MDict v2 uses RIPEMD-128 and Salsa20 reduced to eight rounds for its
// optional keyword-header encryption.  The digest comes from the small,
// portable `ripemd` crate; Salsa20/8 and the MDict nibble cipher remain local
// so the same reader can be reused by iOS/Android later without platform APIs.
fn ripemd128(input: &[u8]) -> [u8; 16] {
    let mut digest = Ripemd128::new();
    digest.update(input);
    digest.finalize().into()
}

fn salsa20_8_xor(input: &[u8], key: &[u8; 16]) -> Vec<u8> {
    const SIGMA: [u8; 16] = *b"expand 16-byte k";
    fn qr(x: &mut [u32; 16]) {
        // column round
        x[4] ^= (x[0].wrapping_add(x[12])).rotate_left(7);
        x[8] ^= (x[4].wrapping_add(x[0])).rotate_left(9);
        x[12] ^= (x[8].wrapping_add(x[4])).rotate_left(13);
        x[0] ^= (x[12].wrapping_add(x[8])).rotate_left(18);
        x[9] ^= (x[5].wrapping_add(x[1])).rotate_left(7);
        x[13] ^= (x[9].wrapping_add(x[5])).rotate_left(9);
        x[1] ^= (x[13].wrapping_add(x[9])).rotate_left(13);
        x[5] ^= (x[1].wrapping_add(x[13])).rotate_left(18);
        x[14] ^= (x[10].wrapping_add(x[6])).rotate_left(7);
        x[2] ^= (x[14].wrapping_add(x[10])).rotate_left(9);
        x[6] ^= (x[2].wrapping_add(x[14])).rotate_left(13);
        x[10] ^= (x[6].wrapping_add(x[2])).rotate_left(18);
        x[3] ^= (x[15].wrapping_add(x[11])).rotate_left(7);
        x[7] ^= (x[3].wrapping_add(x[15])).rotate_left(9);
        x[11] ^= (x[7].wrapping_add(x[3])).rotate_left(13);
        x[15] ^= (x[11].wrapping_add(x[7])).rotate_left(18);
        // row round
        x[1] ^= (x[0].wrapping_add(x[3])).rotate_left(7);
        x[2] ^= (x[1].wrapping_add(x[0])).rotate_left(9);
        x[3] ^= (x[2].wrapping_add(x[1])).rotate_left(13);
        x[0] ^= (x[3].wrapping_add(x[2])).rotate_left(18);
        x[6] ^= (x[5].wrapping_add(x[4])).rotate_left(7);
        x[7] ^= (x[6].wrapping_add(x[5])).rotate_left(9);
        x[4] ^= (x[7].wrapping_add(x[6])).rotate_left(13);
        x[5] ^= (x[4].wrapping_add(x[7])).rotate_left(18);
        x[11] ^= (x[10].wrapping_add(x[9])).rotate_left(7);
        x[8] ^= (x[11].wrapping_add(x[10])).rotate_left(9);
        x[9] ^= (x[8].wrapping_add(x[11])).rotate_left(13);
        x[10] ^= (x[9].wrapping_add(x[8])).rotate_left(18);
        x[12] ^= (x[15].wrapping_add(x[14])).rotate_left(7);
        x[13] ^= (x[12].wrapping_add(x[15])).rotate_left(9);
        x[14] ^= (x[13].wrapping_add(x[12])).rotate_left(13);
        x[15] ^= (x[14].wrapping_add(x[13])).rotate_left(18);
    }
    let mut output = Vec::with_capacity(input.len());
    let mut counter = 0u64;
    for chunk in input.chunks(64) {
        let kw = key
            .chunks_exact(4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
            .collect::<Vec<_>>();
        let sw = SIGMA
            .chunks_exact(4)
            .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
            .collect::<Vec<_>>();
        let mut state = [0u32; 16];
        state[0] = sw[0];
        state[1..5].copy_from_slice(&kw[..4]);
        state[5] = sw[1];
        // MDict's Salsa20 IV is eight zero bytes.  The block counter is the
        // 64-bit little-endian word pair at positions 8 and 9.
        state[6] = 0;
        state[7] = 0;
        state[8] = counter as u32;
        state[9] = (counter >> 32) as u32;
        state[10] = sw[2];
        state[11..15].copy_from_slice(&kw[..4]);
        state[15] = sw[3];
        let original = state;
        let mut work = state;
        for _ in 0..4 {
            qr(&mut work);
        }
        for i in 0..16 {
            work[i] = work[i].wrapping_add(original[i]);
        }
        let mut keystream = [0u8; 64];
        for (dst, word) in keystream.chunks_exact_mut(4).zip(work) {
            dst.copy_from_slice(&word.to_le_bytes());
        }
        output.extend(
            chunk
                .iter()
                .enumerate()
                .map(|(i, byte)| byte ^ keystream[i]),
        );
        counter = counter.wrapping_add(1);
    }
    output
}

fn fast_decrypt(data: &[u8], key: &[u8; 16]) -> Vec<u8> {
    let mut output = Vec::with_capacity(data.len());
    let mut previous = 0x36u8;
    for (index, &cipher) in data.iter().enumerate() {
        let swapped = cipher.rotate_right(4);
        output.push(swapped ^ previous ^ (index as u8) ^ key[index % key.len()]);
        previous = cipher;
    }
    output
}

fn adler32(bytes: &[u8]) -> u32 {
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in bytes {
        a = (a + byte as u32) % 65_521;
        b = (b + a) % 65_521;
    }
    (b << 16) | a
}

fn parse_hex_key(value: &str) -> Option<Vec<u8>> {
    let compact: String = value.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    if compact.len() % 2 != 0 || compact.is_empty() {
        return None;
    }
    let mut bytes = Vec::with_capacity(compact.len() / 2);
    let chars = compact.as_bytes();
    for pair in chars.chunks_exact(2) {
        let high = (pair[0] as char).to_digit(16)? as u8;
        let low = (pair[1] as char).to_digit(16)? as u8;
        bytes.push((high << 4) | low);
    }
    Some(bytes)
}

fn derive_encryption_key(
    source: &Path,
    header: &Header,
    options: &ImportOptions,
) -> Result<Option<[u8; 16]>> {
    if header.encrypted & 1 == 0 {
        return Ok(None);
    }
    let sidecar = source.with_extension("key");
    let registration_code = options
        .registration_code
        .as_deref()
        .and_then(parse_hex_key)
        .or_else(|| header.registration_code.clone())
        .or_else(|| {
            fs::read_to_string(sidecar)
                .ok()
                .and_then(|value| parse_hex_key(&value))
        })
        .filter(|bytes| bytes.len() == 16)
        .ok_or_else(|| {
            anyhow!(
                "Encrypted={} requires a 32-digit registration code (RegCode or a matching .key file)",
                header.encrypted
            )
        })?;
    let user_id = options.user_id.as_deref().unwrap_or("");
    let user_digest = ripemd128(user_id.as_bytes());
    let unwrapped = salsa20_8_xor(&registration_code, &user_digest);
    let mut key = [0u8; 16];
    key.copy_from_slice(&unwrapped[..16]);
    Ok(Some(key))
}

fn package_name(id: &str) -> String {
    format!("{}.mabdict", sanitize_id(id))
}

/// Removes an unpublished import package if any later import step fails.  A
/// failed/ cancelled import must never leave a large `.import-*` directory in
/// Application Support that is invisible to the dictionary list but looks
/// like a failed deletion to the user.
struct TempPackageGuard {
    path: PathBuf,
    committed: bool,
}

impl TempPackageGuard {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            committed: false,
        }
    }

    fn commit(&mut self) {
        self.committed = true;
    }
}

impl Drop for TempPackageGuard {
    fn drop(&mut self) {
        if !self.committed && self.path.exists() {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

fn parse_attr(header: &str, name: &str) -> Option<String> {
    let lower = header.to_ascii_lowercase();
    let needle = format!("{}=\"", name.to_ascii_lowercase());
    let start = lower.find(&needle)? + needle.len();
    let rest = &header[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_owned())
}

fn decode_text(bytes: &[u8], encoding: &str) -> String {
    let normalized = encoding.replace('-', "").to_ascii_uppercase();
    let (text, _, _) = match normalized.as_str() {
        "UTF16" | "UTF16LE" => UTF_16LE.decode(bytes),
        "GBK" | "CP936" => GBK.decode(bytes),
        "BIG5" => BIG5.decode(bytes),
        _ => UTF_8.decode(bytes),
    };
    text.trim_matches('\0').trim().to_owned()
}

fn decode_header(bytes: &[u8]) -> Result<String> {
    if bytes.len() % 2 != 0 {
        bail!("MDX header has an odd UTF-16 length")
    }
    Ok(decode_text(bytes, "UTF-16LE"))
}

fn read_header(file: &mut File) -> Result<(Header, u64)> {
    let mut len = [0u8; 4];
    file.read_exact(&mut len)
        .context("read MDX header length")?;
    let header_len = u32::from_be_bytes(len) as usize;
    if header_len > 16 * 1024 * 1024 {
        bail!("MDX header is unreasonably large")
    }
    let mut header_bytes = vec![0u8; header_len];
    file.read_exact(&mut header_bytes)
        .context("read MDX header")?;
    let mut checksum = [0u8; 4];
    file.read_exact(&mut checksum)
        .context("read MDX header checksum")?;
    let header_string = decode_header(&header_bytes)?;
    let is_mdd = header_string.to_ascii_lowercase().contains("library_data");
    let encrypted = parse_attr(&header_string, "Encrypted")
        .map(|value| match value.trim().to_ascii_lowercase().as_str() {
            "yes" => 1,
            "no" => 0,
            other => other.parse::<u8>().unwrap_or_default(),
        })
        .unwrap_or_default();
    let encoding = if is_mdd {
        "UTF-16".to_owned()
    } else {
        parse_attr(&header_string, "Encoding").unwrap_or_else(|| "UTF-8".to_owned())
    };
    let title = parse_attr(&header_string, "Title")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "未命名词典".to_owned());
    let format = parse_attr(&header_string, "Format").unwrap_or_else(|| "Html".to_owned());
    let registration_code = parse_attr(&header_string, "RegCode")
        .and_then(|value| parse_hex_key(&value).filter(|bytes| bytes.len() == 16));
    let register_by = parse_attr(&header_string, "RegisterBy");
    Ok((
        Header {
            title,
            encoding,
            format,
            encrypted,
            is_mdd,
            registration_code,
            register_by,
        },
        file.stream_position()?,
    ))
}

fn decompress_block(
    block: &[u8],
    expected_len: usize,
    encryption_key: Option<&[u8; 16]>,
) -> Result<Vec<u8>> {
    if block.len() < 8 {
        bail!("compressed MDX block is shorter than its header")
    }
    // v2 files store the block descriptor little-endian, while a number of
    // older writers emitted the same values big-endian.  Accept both forms
    // without changing the existing fixture/legacy reader behavior.
    let little = u32::from_le_bytes(block[0..4].try_into().unwrap());
    let big = u32::from_be_bytes(block[0..4].try_into().unwrap());
    let little_compression = little & 0x0f;
    let big_compression = big & 0x0f;
    let info = if little_compression != 0 || big_compression == 0 {
        little
    } else {
        big
    };
    let kind = info & 0x0f;
    let encryption_method = ((info >> 4) & 0x0f) as u8;
    let encryption_size = ((info >> 8) & 0xff) as usize;
    let mut compressed = block[8..].to_vec();
    if encryption_method != 0 {
        let size = encryption_size.min(compressed.len());
        let key = if let Some(key) = encryption_key {
            *key
        } else {
            ripemd128(&block[4..8])
        };
        let encrypted = &compressed[..size];
        let decrypted = match encryption_method {
            1 => fast_decrypt(encrypted, &key),
            2 => salsa20_8_xor(encrypted, &key),
            other => bail!("unsupported MDX encryption method {other}"),
        };
        compressed[..size].copy_from_slice(&decrypted);
    }
    let output = match kind {
        0 => compressed,
        1 => lzo::decompress(&compressed, expected_len.max(1))
            .map_err(|e| anyhow!("LZO decompression failed: {e:?}"))?,
        2 => {
            let mut decoder = ZlibDecoder::new(&compressed[..]);
            let mut output = Vec::with_capacity(expected_len);
            decoder
                .read_to_end(&mut output)
                .context("zlib decompression failed")?;
            output
        }
        other => bail!("unsupported MDX compression type 0x{other:08x}"),
    };
    if expected_len != 0 && output.len() != expected_len {
        bail!(
            "MDX decompressed length mismatch (expected {}, got {})",
            expected_len,
            output.len()
        )
    }
    Ok(output)
}

fn parse_key_index_layout(
    bytes: &[u8],
    blocks: usize,
    encoding: &str,
    includes_terminators: bool,
    sizes_are_code_units: bool,
) -> Result<Vec<(usize, usize)>> {
    let mut reader = Reader::new(bytes);
    let unit = if encoding.to_ascii_uppercase().contains("UTF-16") {
        2
    } else {
        1
    };
    let mut block_sizes = Vec::with_capacity(blocks);
    for _ in 0..blocks {
        let _entries = reader.u64()?;
        let first_units = reader.u16()? as usize;
        let first_size = if sizes_are_code_units {
            first_units
                .checked_mul(unit)
                .ok_or_else(|| anyhow!("MDX key index word length overflow"))?
        } else {
            first_units
        };
        reader.take(first_size)?;
        // The standard v2 layout stores the first/last words with their
        // terminating NUL unit, while a few older builders omit those units.
        // The lengths themselves exclude the terminator in both variants.
        if includes_terminators {
            reader.take(unit)?;
        }
        let last_units = reader.u16()? as usize;
        let last_size = if sizes_are_code_units {
            last_units
                .checked_mul(unit)
                .ok_or_else(|| anyhow!("MDX key index word length overflow"))?
        } else {
            last_units
        };
        reader.take(last_size)?;
        if includes_terminators {
            reader.take(unit)?;
        }
        let compressed_size = reader.u64()? as usize;
        let decompressed_size = reader.u64()? as usize;
        block_sizes.push((compressed_size, decompressed_size));
    }
    if reader.remaining() != 0 {
        bail!(
            "MDX key index has {} trailing bytes after {} blocks",
            reader.remaining(),
            blocks
        )
    }
    Ok(block_sizes)
}

fn parse_key_index(bytes: &[u8], blocks: usize, encoding: &str) -> Result<Vec<(usize, usize)>> {
    let mut last_error = None;
    for includes_terminators in [true, false] {
        for sizes_are_code_units in [false, true] {
            match parse_key_index_layout(
                bytes,
                blocks,
                encoding,
                includes_terminators,
                sizes_are_code_units,
            ) {
                Ok(block_sizes) => return Ok(block_sizes),
                Err(error) => last_error = Some(error),
            }
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow!("MDX key index is invalid")))
}

fn parse_dictionary_keys(
    file: &mut File,
    header: &Header,
    encryption_key: Option<&[u8; 16]>,
) -> Result<Vec<RawKey>> {
    let mut fixed = [0u8; 44];
    file.read_exact(&mut fixed)
        .context("read MDX key section")?;
    if header.encrypted & 1 != 0 {
        let key = encryption_key.ok_or_else(|| {
            anyhow!(
                "this encrypted dictionary requires a registration code and user identity (RegisterBy={})",
                header.register_by.as_deref().unwrap_or("unknown")
            )
        })?;
        let decrypted = salsa20_8_xor(&fixed[..40], key);
        fixed[..40].copy_from_slice(&decrypted);
        let expected = u32::from_be_bytes(fixed[40..44].try_into().unwrap());
        let actual = adler32(&fixed[..40]);
        if expected != 0 && expected != actual {
            bail!(
                "encrypted MDX key header could not be verified; check the user identity or registration code"
            )
        }
    }
    let mut reader = Reader::new(&fixed);
    let block_count = reader.u64()? as usize;
    let _entry_count = reader.u64()?;
    let key_index_decomp_len = reader.u64()? as usize;
    let key_index_comp_len = reader.u64()? as usize;
    let key_blocks_len = reader.u64()?;
    let _checksum = reader.u32()?;
    if block_count == 0 || block_count > 1_000_000 {
        bail!("invalid MDX key block count {}", block_count)
    }
    if key_index_comp_len > 512 * 1024 * 1024 {
        bail!("MDX key index is unreasonably large")
    }
    let mut key_index_compressed = vec![0u8; key_index_comp_len];
    file.read_exact(&mut key_index_compressed)
        .context("read MDX key index")?;
    if header.encrypted & 2 != 0 {
        if key_index_compressed.len() < 8 {
            bail!("encrypted MDX key index is truncated")
        }
        let mut key_material = Vec::with_capacity(8);
        key_material.extend_from_slice(&key_index_compressed[4..8]);
        key_material.extend_from_slice(&[0x95, 0x36, 0x00, 0x00]);
        let key = ripemd128(&key_material);
        let decrypted = fast_decrypt(&key_index_compressed[8..], &key);
        key_index_compressed[8..].copy_from_slice(&decrypted);
    }
    let key_index = decompress_block(&key_index_compressed, key_index_decomp_len, encryption_key)?;
    let block_sizes = parse_key_index(&key_index, block_count, &header.encoding)
        .context("parse MDX key index")?;

    let mut raw_keys = Vec::new();
    let mut consumed = 0u64;
    for (comp_size, decomp_size) in block_sizes {
        if comp_size < 8 || comp_size > 512 * 1024 * 1024 {
            bail!("invalid MDX key block size {}", comp_size)
        }
        let mut compressed = vec![0u8; comp_size];
        file.read_exact(&mut compressed)
            .context("read MDX key block")?;
        let decompressed = decompress_block(&compressed, decomp_size, encryption_key)?;
        let mut key_reader = Reader::new(&decompressed);
        while key_reader.remaining() > 0 {
            let offset = key_reader.u64()?;
            let key_bytes = if header.encoding.to_ascii_uppercase().contains("UTF-16") {
                let start = key_reader.pos;
                let mut end = start;
                let mut has_terminator = false;
                while end + 1 < decompressed.len() {
                    if decompressed[end] == 0 && decompressed[end + 1] == 0 {
                        has_terminator = true;
                        break;
                    }
                    end += 2;
                }
                // Some dictionaries omit the final UTF-16 NUL unit at the
                // end of a key block. Treat the remaining even bytes as the
                // final key instead of asking Reader for a terminator that is
                // not present (the old path reported a misleading truncated
                // two-byte block).
                let length = if has_terminator {
                    end.saturating_sub(start)
                } else {
                    key_reader.remaining()
                };
                if length % 2 != 0 {
                    bail!("unterminated UTF-16 MDX keyword has an odd byte length")
                }
                let bytes = key_reader.take(length)?.to_vec();
                if has_terminator {
                    let _ = key_reader.take(2)?;
                }
                bytes
            } else {
                let start = key_reader.pos;
                let tail = &decompressed[start..];
                let terminator = tail.iter().position(|b| *b == 0);
                let length = terminator.unwrap_or(tail.len());
                let bytes = key_reader.take(length)?.to_vec();
                if terminator.is_some() {
                    let _ = key_reader.take(1)?;
                }
                bytes
            };
            let key = decode_text(&key_bytes, &header.encoding);
            if !key.is_empty() {
                raw_keys.push(RawKey { key, offset });
            }
        }
        consumed = consumed.saturating_add(comp_size as u64);
    }
    if consumed > key_blocks_len {
        bail!("MDX key blocks exceed their declared length")
    }
    Ok(raw_keys)
}

fn create_schema(connection: &Connection) -> Result<()> {
    connection.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA busy_timeout = 5000;
         CREATE TABLE IF NOT EXISTS metadata (
           key TEXT PRIMARY KEY NOT NULL,
           value TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS entries (
           id INTEGER PRIMARY KEY,
           key TEXT NOT NULL,
           normalized TEXT NOT NULL,
           record_text TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_entries_normalized ON entries(normalized);
         CREATE TABLE IF NOT EXISTS resources (
           key TEXT PRIMARY KEY NOT NULL,
           path TEXT NOT NULL,
           size INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS idx_resources_key ON resources(key);",
    )?;
    Ok(())
}

fn read_record(file: &mut File, start: u64, end: u64) -> Result<Vec<u8>> {
    if end < start || end - start > usize::MAX as u64 {
        bail!("invalid MDX record offset")
    }
    file.seek(SeekFrom::Start(start))?;
    let mut data = vec![0u8; (end - start) as usize];
    file.read_exact(&mut data)?;
    Ok(data)
}

fn import_file(
    source: &Path,
    is_mdd_expected: bool,
    records_path: &Path,
    connection: &Connection,
    resources_dir: &Path,
    resource_offset: u64,
    options: &ImportOptions,
) -> Result<(Header, u64, u64)> {
    let mut source_file =
        File::open(source).with_context(|| format!("open {}", source.display()))?;
    let (header, _) = read_header(&mut source_file)?;
    if header.is_mdd != is_mdd_expected {
        bail!(
            "file type does not match its extension: {}",
            source.display()
        )
    }
    let encryption_key = derive_encryption_key(source, &header, options)?;
    let keys = parse_dictionary_keys(&mut source_file, &header, encryption_key.as_ref())?;
    let mut fixed = [0u8; 32];
    source_file
        .read_exact(&mut fixed)
        .context("read MDX record section")?;
    let mut record_reader = Reader::new(&fixed);
    let record_blocks = record_reader.u64()? as usize;
    let record_entries = record_reader.u64()?;
    let index_len = record_reader.u64()? as usize;
    let blocks_len = record_reader.u64()?;
    if record_blocks == 0 || record_blocks > 1_000_000 || index_len < record_blocks * 16 {
        bail!("invalid MDX record section")
    }
    let mut index = vec![0u8; index_len];
    source_file.read_exact(&mut index)?;
    let mut index_reader = Reader::new(&index);
    let mut record_sizes = Vec::with_capacity(record_blocks);
    for _ in 0..record_blocks {
        record_sizes.push((index_reader.u64()? as usize, index_reader.u64()? as usize));
    }
    let mut records_file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(records_path)?;
    let mut total_records = 0u64;
    for (comp_size, decomp_size) in record_sizes {
        if comp_size < 8 || comp_size > 1024 * 1024 * 1024 {
            bail!("invalid MDX record block size {}", comp_size)
        }
        let mut compressed = vec![0u8; comp_size];
        source_file.read_exact(&mut compressed)?;
        let decompressed = decompress_block(&compressed, decomp_size, encryption_key.as_ref())?;
        records_file.write_all(&decompressed)?;
        total_records = total_records
            .checked_add(decompressed.len() as u64)
            .ok_or_else(|| anyhow!("MDX records are too large"))?;
    }
    records_file.flush()?;
    drop(records_file);
    if total_records == 0 && !keys.is_empty() {
        bail!("MDX has keys but no record bytes")
    }
    if blocks_len == 0 && total_records > 0 {
        bail!("MDX record section length is invalid")
    }
    if record_entries != keys.len() as u64 {
        // Duplicate-key folding in some builders makes this count differ; the
        // offsets remain authoritative and are used below.
    }

    let mut records_file = File::open(records_path)?;
    let tx = connection.unchecked_transaction()?;
    let mut entry_count = 0u64;
    let mut resource_count = 0u64;
    for (index, raw) in keys.iter().enumerate() {
        let end = keys
            .get(index + 1)
            .map(|next| next.offset)
            .unwrap_or(total_records);
        if raw.offset > end || end > total_records {
            continue;
        }
        let bytes = read_record(&mut records_file, raw.offset, end)?;
        if header.is_mdd {
            let resource_name = format!("resource_{:08}.bin", resource_offset + index as u64);
            let resource_path = resources_dir.join(&resource_name);
            fs::write(&resource_path, &bytes)?;
            tx.execute(
                "INSERT OR REPLACE INTO resources(key, path, size) VALUES (?1, ?2, ?3)",
                params![raw.key, resource_name, bytes.len() as i64],
            )?;

            let clean_rel = raw.key.trim_start_matches(['\\', '/']).replace('\\', "/");
            if !clean_rel.is_empty() && !clean_rel.contains("..") {
                let named_path = resources_dir.join(&clean_rel);
                if named_path != resource_path {
                    if let Some(parent) = named_path.parent() {
                        fs::create_dir_all(parent).with_context(|| {
                            format!("create resource directory {}", parent.display())
                        })?;
                    }
                    // The SQLite index uses the generated path while HTML
                    // resources use their original MDD name. Keep both
                    // lookups without writing the potentially large payload
                    // twice. Fall back to a copy only on filesystems that do
                    // not support hard links.
                    if fs::hard_link(&resource_path, &named_path).is_err() {
                        fs::copy(&resource_path, &named_path).with_context(|| {
                            format!("write named resource {}", named_path.display())
                        })?;
                    }
                }
            }

            let lower_key = raw.key.to_lowercase();
            if lower_key.ends_with(".css") {
                let css_text = decode_text(&bytes, &header.encoding);
                if let Some(pkg_dir) = resources_dir.parent() {
                    let style_path = pkg_dir.join("style.css");
                    let mut existing = if style_path.is_file() {
                        fs::read_to_string(&style_path)
                            .with_context(|| format!("read {}", style_path.display()))?
                    } else {
                        String::new()
                    };
                    existing.push_str(&css_text);
                    existing.push('\n');
                    fs::write(&style_path, existing)
                        .with_context(|| format!("write {}", style_path.display()))?;
                }
            }

            resource_count += 1;
        } else {
            let text = decode_text(&bytes, &header.encoding);
            tx.execute(
                "INSERT INTO entries(key, normalized, record_text) VALUES (?1, ?2, ?3)",
                params![raw.key, normalize_key(&raw.key), text],
            )?;
            entry_count += 1;
        }
    }
    tx.commit()?;
    Ok((header, entry_count, resource_count))
}

fn manifest_to_summary(manifest: &DictionaryManifest) -> DictionarySummary {
    DictionarySummary {
        id: manifest.id.clone(),
        title: manifest.title.clone(),
        encoding: manifest.encoding.clone(),
        format: manifest.format.clone(),
        entry_count: manifest.entry_count,
        resource_count: manifest.resource_count,
        imported_at: manifest.imported_at,
    }
}

pub fn import_dictionary(options: &ImportOptions) -> Result<ImportResult> {
    import_dictionary_with_progress(options, None)
}

pub fn import_dictionary_with_progress(
    options: &ImportOptions,
    mut progress: Option<&mut dyn FnMut(&str, f64)>,
) -> Result<ImportResult> {
    if !options.mdx.is_file() {
        bail!("MDX file does not exist: {}", options.mdx.display())
    }
    if let Some(p) = progress.as_deref_mut() {
        p("正在准备导入目录…", 0.05);
    }
    fs::create_dir_all(&options.root)?;
    // The JSONL helper processes one request at a time, so no import can be
    // active while this cleanup runs.  This also recovers temporary packages
    // left behind when an older app version was force-quit or crashed.
    cleanup_all_import_packages(&options.root);
    let default_id = stable_id(&options.mdx);
    let id = sanitize_id(options.id.as_deref().unwrap_or(&default_id));
    let package = options.root.join(package_name(&id));
    if package.exists() {
        bail!("dictionary package already exists: {}", package.display())
    }
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or_default();
    let temp_package = options
        .root
        .join(format!(".{}.import-{suffix}", package_name(&id)));
    let mut temp_guard = TempPackageGuard::new(temp_package.clone());
    fs::create_dir_all(temp_package.join("source"))?;
    fs::create_dir_all(temp_package.join("resources"))?;
    let source_mdx = temp_package.join("source").join(
        options
            .mdx
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("dictionary.mdx"),
    );
    if let Some(p) = progress.as_deref_mut() {
        p("正在复制源文件…", 0.15);
    }
    fs::copy(&options.mdx, &source_mdx).with_context(|| {
        format!(
            "copy MDX source {} -> {}",
            options.mdx.display(),
            source_mdx.display()
        )
    })?;
    // MDict permits a sibling `<dictionary>.key` file containing the
    // registration code.  Keep it inside the package while importing so the
    // encrypted reader behaves the same after the source file is copied.
    let source_key = options.mdx.with_extension("key");
    if source_key.is_file() {
        let target_key = source_mdx.with_extension("key");
        fs::copy(source_key, target_key)?;
    }
    let records_path = temp_package.join("records.tmp");
    let index_path = temp_package.join("Library.sqlite3");
    let connection = Connection::open(&index_path)?;
    create_schema(&connection)?;
    let sibling_resources = copy_sibling_assets(
        &options.mdx,
        &temp_package.join("resources"),
        &temp_package.join("style.css"),
        &connection,
    )?;
    if let Some(p) = progress.as_deref_mut() {
        p("正在解析并解压词条…", 0.35);
    }
    let (header, entry_count, mut resource_count) = import_file(
        &source_mdx,
        false,
        &records_path,
        &connection,
        &temp_package.join("resources"),
        sibling_resources,
        options,
    )
    .with_context(|| format!("import MDX {}", options.mdx.display()))?;
    resource_count += sibling_resources;
    if let Some(p) = progress.as_deref_mut() {
        p("正在导入多媒体资源…", 0.70);
    }
    for mdd in discover_mdd_paths(&options.mdx, &options.mdd) {
        if !mdd.is_file() {
            bail!("MDD file does not exist: {}", mdd.display())
        }
        let source_mdd = temp_package.join("source").join(
            mdd.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("resources.mdd"),
        );
        fs::copy(&mdd, &source_mdd).with_context(|| {
            format!(
                "copy MDD source {} -> {}",
                mdd.display(),
                source_mdd.display()
            )
        })?;
        let mdd_records = temp_package.join(format!("records-{}.tmp", resource_count));
        let (_mdd_header, _entries, resources) = import_file(
            &source_mdd,
            true,
            &mdd_records,
            &connection,
            &temp_package.join("resources"),
            resource_count,
            options,
        )
        .with_context(|| format!("import MDD {}", mdd.display()))?;
        resource_count += resources;
        let _ = fs::remove_file(mdd_records);
    }
    let _ = fs::remove_file(&records_path);
    if let Some(p) = progress.as_deref_mut() {
        p("正在整理词典数据库…", 0.90);
    }
    // Build SQLite statistics once, after the bulk insert.  This lets the
    // prefix planner choose the normalized index reliably on large packages;
    // doing it here avoids repeated ANALYZE work on every lookup.
    connection.execute_batch("ANALYZE entries; ANALYZE resources;")?;
    connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")?;
    drop(connection);
    let manifest = DictionaryManifest {
        version: PACKAGE_VERSION,
        id: id.clone(),
        title: header.title,
        source_file: source_mdx
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("dictionary.mdx")
            .to_owned(),
        encoding: header.encoding,
        format: header.format,
        entry_count,
        resource_count,
        imported_at: now_seconds(),
    };
    fs::write(
        temp_package.join("manifest.json"),
        serde_json::to_vec_pretty(&manifest)?,
    )?;
    if let Some(p) = progress.as_deref_mut() {
        p("正在完成词典导入…", 0.98);
    }
    fs::rename(&temp_package, &package).with_context(|| {
        format!(
            "publish dictionary package {} -> {}",
            temp_package.display(),
            package.display()
        )
    })?;
    temp_guard.commit();
    if let Some(p) = progress.as_deref_mut() {
        p("导入完成", 1.0);
    }
    Ok(ImportResult {
        dictionary: manifest_to_summary(&manifest),
        package_path: package.to_string_lossy().into_owned(),
    })
}

pub fn list_dictionaries(root: &Path) -> Result<Vec<DictionarySummary>> {
    if !root.exists() {
        return Ok(Vec::new());
    }
    // Only published packages have a manifest and are shown below.  Remove
    // every hidden import staging directory first so an interrupted import
    // cannot accumulate indefinitely in Application Support.
    cleanup_all_import_packages(root);
    let mut result = Vec::new();
    for item in fs::read_dir(root)? {
        let path = item?.path();
        if !path.is_dir()
            || path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .starts_with('.')
        {
            continue;
        }
        let manifest_path = path.join("manifest.json");
        if !manifest_path.is_file() {
            continue;
        }
        let manifest: DictionaryManifest = serde_json::from_slice(&fs::read(manifest_path)?)?;
        if manifest.version <= PACKAGE_VERSION {
            result.push(manifest_to_summary(&manifest));
        }
    }
    result.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    Ok(result)
}

pub fn delete_dictionary(root: &Path, id: &str) -> Result<bool> {
    if !root.exists() {
        return Ok(false);
    }
    let safe = sanitize_id(id);
    let package = root.join(package_name(&safe));
    if package.exists() {
        fs::remove_dir_all(&package)?;
        cleanup_all_import_packages(root);
        return Ok(true);
    }
    if let Ok(entries) = fs::read_dir(root) {
        for item in entries.flatten() {
            let path = item.path();
            if !path.is_dir() {
                continue;
            }
            let manifest_path = path.join("manifest.json");
            if manifest_path.is_file() {
                if let Ok(data) = fs::read(&manifest_path) {
                    if let Ok(manifest) = serde_json::from_slice::<DictionaryManifest>(&data) {
                        if manifest.id == id || manifest.title == id {
                            fs::remove_dir_all(&path)?;
                            cleanup_all_import_packages(root);
                            return Ok(true);
                        }
                    }
                }
            }
        }
    }
    // A previous interrupted import may have left only hidden temporary
    // packages behind. They are not returned by `list_dictionaries`, but are
    // never usable dictionaries and must not survive a delete request.
    cleanup_all_import_packages(root);
    Ok(false)
}

/// Remove all unpublished import staging directories.  A package is only
/// published after its manifest is written and its directory is atomically
/// renamed to the visible `*.mabdict` name, so a hidden `.mabdict.import-*`
/// directory can never be a usable dictionary.  The helper's request loop is
/// serial, which means this is not racing an active import in this app.
fn cleanup_all_import_packages(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let is_import_temp = path.is_dir()
            && path
                .file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.starts_with('.') && name.contains(".mabdict.import-"))
                .unwrap_or(false);
        if is_import_temp {
            let _ = fs::remove_dir_all(path);
        }
    }
}

fn open_manifest(root: &Path, id: &str) -> Result<(PathBuf, DictionaryManifest)> {
    let safe = sanitize_id(id);
    let package = root.join(package_name(&safe));
    let manifest_path = package.join("manifest.json");
    let manifest: DictionaryManifest = serde_json::from_slice(
        &fs::read(&manifest_path).with_context(|| format!("read {}", manifest_path.display()))?,
    )?;
    Ok((package, manifest))
}

fn copy_sibling_assets(
    mdx_path: &Path,
    resources_dir: &Path,
    style_css_path: &Path,
    connection: &Connection,
) -> Result<u64> {
    let mut added = 0u64;
    let parent = match mdx_path.parent() {
        Some(p) if p.is_dir() => p,
        _ => return Ok(0),
    };
    let entries = match fs::read_dir(parent) {
        Ok(entries) => entries,
        // A sandboxed import can have access to the selected file without
        // access to enumerate its parent. The Swift adapter keeps the
        // security scope alive for the helper import; retain this fallback
        // only for environments where the source has no readable sibling
        // directory. The MDX itself must still be allowed to import.
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => return Ok(0),
        Err(error) => {
            return Err(error)
                .with_context(|| format!("read sibling assets in {}", parent.display()))
        }
    };
    let mut combined_css = String::new();
    for entry in entries {
        let entry = entry.with_context(|| format!("read sibling asset in {}", parent.display()))?;
        let path = entry.path();
        let file_type = entry
            .file_type()
            .with_context(|| format!("inspect sibling asset {}", path.display()))?;
        if file_type.is_file() {
            let ext = path
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_lowercase();
            let file_name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if file_name.is_empty() || ext == "mdx" || ext == "mdd" || ext == "key" {
                continue;
            }
            if matches!(
                ext.as_str(),
                "css"
                    | "js"
                    | "ini"
                    | "json"
                    | "xml"
                    | "html"
                    | "htm"
                    | "txt"
                    | "wasm"
                    | "webmanifest"
                    | "map"
                    | "png"
                    | "jpg"
                    | "jpeg"
                    | "gif"
                    | "svg"
                    | "webp"
                    | "avif"
                    | "bmp"
                    | "ico"
                    | "ttf"
                    | "otf"
                    | "eot"
                    | "woff"
                    | "woff2"
                    | "mp3"
                    | "wav"
                    | "ogg"
                    | "oga"
                    | "m4a"
                    | "aac"
                    | "flac"
                    | "mp4"
                    | "webm"
                    | "mov"
            ) {
                let target_path = resources_dir.join(file_name);
                fs::copy(&path, &target_path).with_context(|| {
                    format!(
                        "copy sibling asset {} -> {}",
                        path.display(),
                        target_path.display()
                    )
                })?;
                let size = fs::metadata(&path)
                    .with_context(|| format!("inspect sibling asset {}", path.display()))?
                    .len();
                connection
                    .execute(
                        "INSERT OR REPLACE INTO resources(key, path, size) VALUES (?1, ?2, ?3)",
                        params![file_name, file_name, size as i64],
                    )
                    .with_context(|| format!("register resource {}", file_name))?;
                connection
                    .execute(
                        "INSERT OR REPLACE INTO resources(key, path, size) VALUES (?1, ?2, ?3)",
                        params![format!("\\{}", file_name), file_name, size as i64],
                    )
                    .with_context(|| format!("register resource \\{}", file_name))?;
                connection
                    .execute(
                        "INSERT OR REPLACE INTO resources(key, path, size) VALUES (?1, ?2, ?3)",
                        params![format!("/{}", file_name), file_name, size as i64],
                    )
                    .with_context(|| format!("register resource /{}", file_name))?;
                if ext == "css" {
                    let bytes = fs::read(&path)
                        .with_context(|| format!("read sibling stylesheet {}", path.display()))?;
                    combined_css.push_str(&decode_text(&bytes, "utf-8"));
                    combined_css.push('\n');
                }
                added += 1;
            }
        } else if file_type.is_dir() {
            let dir_name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
            if matches!(
                dir_name.to_lowercase().as_str(),
                "fonts"
                    | "images"
                    | "img"
                    | "css"
                    | "js"
                    | "script"
                    | "scripts"
                    | "assets"
                    | "data"
                    | "audio"
                    | "sounds"
                    | "sound"
                    | "media"
                    | "resources"
            ) {
                let target_subdir = resources_dir.join(dir_name);
                copy_dir_all(&path, &target_subdir)
                    .with_context(|| format!("copy sibling asset directory {}", path.display()))?;
            }
        }
    }
    if !combined_css.is_empty() {
        let mut existing = if style_css_path.is_file() {
            fs::read_to_string(style_css_path)
                .with_context(|| format!("read {}", style_css_path.display()))?
        } else {
            String::new()
        };
        existing.push_str(&combined_css);
        fs::write(style_css_path, existing)
            .with_context(|| format!("write {}", style_css_path.display()))?;
    }
    Ok(added)
}

fn copy_dir_all(src: &Path, dst: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dst)?;
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        if ty.is_dir() {
            copy_dir_all(&entry.path(), &dst.join(entry.file_name()))?;
        } else {
            fs::copy(entry.path(), dst.join(entry.file_name()))?;
        }
    }
    Ok(())
}

pub fn load_package_css(package: &Path) -> Option<String> {
    let style_path = package.join("style.css");
    if style_path.is_file() {
        if let Ok(css) = fs::read_to_string(&style_path) {
            if !css.trim().is_empty() {
                return Some(css);
            }
        }
    }
    let mut combined = String::new();
    let resources = package.join("resources");
    if resources.is_dir() {
        if let Ok(entries) = fs::read_dir(&resources) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_file()
                    && p.extension()
                        .and_then(|s| s.to_str())
                        .map(|e| e.eq_ignore_ascii_case("css"))
                        .unwrap_or(false)
                {
                    if let Ok(c) = fs::read_to_string(&p) {
                        combined.push_str(&c);
                        combined.push('\n');
                    }
                }
            }
        }
    }
    let source_dir = package.join("source");
    if source_dir.is_dir() {
        if let Ok(entries) = fs::read_dir(&source_dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_file()
                    && p.extension()
                        .and_then(|s| s.to_str())
                        .map(|e| e.eq_ignore_ascii_case("css"))
                        .unwrap_or(false)
                {
                    if let Ok(c) = fs::read_to_string(&p) {
                        combined.push_str(&c);
                        combined.push('\n');
                    }
                }
            }
        }
    }
    if combined.trim().is_empty() {
        if let Ok(connection) = Connection::open(package.join("Library.sqlite3")) {
            if let Ok(mut stmt) =
                connection.prepare("SELECT path FROM resources WHERE lower(key) LIKE '%.css'")
            {
                if let Ok(rows) = stmt.query_map([], |row| row.get::<_, String>(0)) {
                    for path in rows.flatten() {
                        let res_path = package.join("resources").join(path);
                        if let Ok(bytes) = fs::read(&res_path) {
                            let text = decode_text(&bytes, "utf-8");
                            combined.push_str(&text);
                            combined.push('\n');
                        }
                    }
                }
            }
        }
    }
    if combined.trim().is_empty() {
        if let Ok(entries) = fs::read_dir(&source_dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_file() {
                    let ext = p.extension().and_then(|s| s.to_str()).unwrap_or("");
                    if ext.eq_ignore_ascii_case("mdx") {
                        if let Ok(target) = fs::canonicalize(&p) {
                            if let Some(parent) = target.parent() {
                                if let Ok(parent_entries) = fs::read_dir(parent) {
                                    for pe in parent_entries.flatten() {
                                        let pep = pe.path();
                                        if pep.is_file()
                                            && pep
                                                .extension()
                                                .and_then(|s| s.to_str())
                                                .map(|e| e.eq_ignore_ascii_case("css"))
                                                .unwrap_or(false)
                                        {
                                            if let Ok(c) = fs::read_to_string(&pep) {
                                                combined.push_str(&c);
                                                combined.push('\n');
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if !combined.trim().is_empty() {
        return Some(combined);
    }
    None
}

struct CachedDictionary {
    manifest: DictionaryManifest,
    css: Option<String>,
    connection: Connection,
    last_used: u64,
}

/// Reusable query state for the long-lived JSONL helper. The process handles
/// requests serially, so a mutable cache is sufficient and avoids the
/// overhead of reopening manifests, CSS files and SQLite connections for
/// every keystroke.
pub struct DictionaryQueryCache {
    root: Option<PathBuf>,
    summaries: Option<Vec<DictionarySummary>>,
    dictionaries: HashMap<String, CachedDictionary>,
    access_counter: u64,
    max_cached_dictionaries: usize,
}

impl Default for DictionaryQueryCache {
    fn default() -> Self {
        Self {
            root: None,
            summaries: None,
            dictionaries: HashMap::new(),
            access_counter: 0,
            // Keeping a few hot dictionaries open avoids repeated SQLite
            // startup while bounding RAM/file-descriptor use for users who
            // import a large collection.
            max_cached_dictionaries: 4,
        }
    }
}

impl DictionaryQueryCache {
    fn ensure_root(&mut self, root: &Path) {
        if self.root.as_deref() != Some(root) {
            self.root = Some(root.to_path_buf());
            self.summaries = None;
            self.dictionaries.clear();
            self.access_counter = 0;
        }
    }

    /// Invalidate cached package handles after import or deletion.
    pub fn invalidate(&mut self) {
        self.summaries = None;
        self.dictionaries.clear();
        self.access_counter = 0;
    }

    pub fn list(&mut self, root: &Path) -> Result<Vec<DictionarySummary>> {
        self.ensure_root(root);
        if self.summaries.is_none() {
            self.summaries = Some(list_dictionaries(root)?);
        }
        Ok(self.summaries.clone().unwrap_or_default())
    }

    fn dictionary_mut(&mut self, root: &Path, id: &str) -> Result<&mut CachedDictionary> {
        self.ensure_root(root);
        if !self.dictionaries.contains_key(id) {
            let (package, manifest) = open_manifest(root, id)?;
            let css = load_package_css(&package);
            let connection = Connection::open(package.join("Library.sqlite3"))?;
            configure_read_connection(&connection)?;
            self.access_counter = self.access_counter.wrapping_add(1);
            self.dictionaries.insert(
                id.to_owned(),
                CachedDictionary {
                    manifest,
                    css,
                    connection,
                    last_used: self.access_counter,
                },
            );
            if self.dictionaries.len() > self.max_cached_dictionaries {
                if let Some(evicted) = self
                    .dictionaries
                    .iter()
                    .filter(|(key, _)| key.as_str() != id)
                    .min_by_key(|(_, dictionary)| dictionary.last_used)
                    .map(|(key, _)| key.clone())
                {
                    self.dictionaries.remove(&evicted);
                }
            }
        }
        self.access_counter = self.access_counter.wrapping_add(1);
        let dictionary = self
            .dictionaries
            .get_mut(id)
            .ok_or_else(|| anyhow!("dictionary cache entry missing for {id}"))?;
        dictionary.last_used = self.access_counter;
        Ok(dictionary)
    }

    pub fn lookup_keys(
        &mut self,
        root: &Path,
        dictionary_id: &str,
        query: &str,
        limit: usize,
    ) -> Result<Vec<LookupKey>> {
        let dictionary = self.dictionary_mut(root, dictionary_id)?;
        let exact = normalize_key(query);
        if exact.is_empty() {
            return Ok(Vec::new());
        }
        let limit = limit.clamp(1, 100);
        let dictionary_id = dictionary.manifest.id.clone();
        let dictionary_title = dictionary.manifest.title.clone();
        let resource_root = root
            .join(package_name(&dictionary_id))
            .join("resources")
            .to_string_lossy()
            .into_owned();
        let mut result = Vec::with_capacity(limit);
        {
            let mut statement = dictionary.connection.prepare_cached(
                "SELECT DISTINCT key FROM entries WHERE normalized = ?1 ORDER BY key LIMIT ?2",
            )?;
            let rows = statement.query_map(params![exact, limit as i64], |row| {
                Ok(LookupKey {
                    key: row.get(0)?,
                    dictionary_id: dictionary_id.clone(),
                    dictionary_title: dictionary_title.clone(),
                    resource_root: Some(resource_root.clone()),
                })
            })?;
            result.extend(rows.collect::<rusqlite::Result<Vec<_>>>()?);
        }
        if result.len() < limit {
            let remaining = limit - result.len();
            let prefix = format!("{}%", escape_like_pattern(&normalize_key(query)));
            let mut statement = dictionary.connection.prepare_cached(
                "SELECT DISTINCT key FROM entries
                 WHERE normalized LIKE ?1 ESCAPE '\\'
                   AND normalized != ?2
                 ORDER BY length(normalized), key LIMIT ?3",
            )?;
            let rows = statement.query_map(
                params![prefix, normalize_key(query), remaining as i64],
                |row| {
                    Ok(LookupKey {
                        key: row.get(0)?,
                        dictionary_id: dictionary_id.clone(),
                        dictionary_title: dictionary_title.clone(),
                        resource_root: Some(resource_root.clone()),
                    })
                },
            )?;
            result.extend(rows.collect::<rusqlite::Result<Vec<_>>>()?);
        }
        Ok(result)
    }

    pub fn lookup_all_keys(
        &mut self,
        root: &Path,
        query: &str,
        limit_per_dictionary: usize,
    ) -> Result<Vec<LookupKey>> {
        let dictionaries = self.list(root)?;
        let mut result = Vec::new();
        for dictionary in dictionaries {
            result.extend(self.lookup_keys(root, &dictionary.id, query, limit_per_dictionary)?);
        }
        Ok(result)
    }

    pub fn lookup(
        &mut self,
        root: &Path,
        dictionary_id: &str,
        query: &str,
        limit: usize,
    ) -> Result<Vec<LookupEntry>> {
        let dictionary = self.dictionary_mut(root, dictionary_id)?;
        let exact = normalize_key(query);
        if exact.is_empty() {
            return Ok(Vec::new());
        }
        let limit = limit.clamp(1, 100);
        let dictionary_id = dictionary.manifest.id.clone();
        let dictionary_title = dictionary.manifest.title.clone();
        let css = dictionary.css.clone();
        let resource_root = root
            .join(package_name(&dictionary_id))
            .join("resources")
            .to_string_lossy()
            .into_owned();
        let mut result = Vec::with_capacity(limit);
        {
            let mut statement = dictionary.connection.prepare_cached(
                "SELECT key, record_text FROM entries
                 WHERE normalized = ?1 ORDER BY key LIMIT ?2",
            )?;
            let rows = statement.query_map(params![exact, limit as i64], |row| {
                Ok(LookupEntry {
                    key: row.get(0)?,
                    text: row.get(1)?,
                    dictionary_id: dictionary_id.clone(),
                    dictionary_title: dictionary_title.clone(),
                    css: css.clone(),
                    resource_root: Some(resource_root.clone()),
                })
            })?;
            result.extend(rows.collect::<rusqlite::Result<Vec<_>>>()?);
        }
        if result.len() < limit {
            let remaining = limit - result.len();
            let prefix = format!("{}%", escape_like_pattern(&normalize_key(query)));
            let mut statement = dictionary.connection.prepare_cached(
                "SELECT key, record_text FROM entries
                 WHERE normalized LIKE ?1 ESCAPE '\\'
                   AND normalized != ?2
                 ORDER BY length(normalized), key LIMIT ?3",
            )?;
            let rows = statement.query_map(
                params![prefix, normalize_key(query), remaining as i64],
                |row| {
                    Ok(LookupEntry {
                        key: row.get(0)?,
                        text: row.get(1)?,
                        dictionary_id: dictionary_id.clone(),
                        dictionary_title: dictionary_title.clone(),
                        css: css.clone(),
                        resource_root: Some(resource_root.clone()),
                    })
                },
            )?;
            result.extend(rows.collect::<rusqlite::Result<Vec<_>>>()?);
        }
        Ok(result)
    }

    pub fn lookup_all(
        &mut self,
        root: &Path,
        query: &str,
        limit_per_dictionary: usize,
    ) -> Result<Vec<LookupEntry>> {
        let dictionaries = self.list(root)?;
        let mut result = Vec::new();
        for dictionary in dictionaries {
            result.extend(self.lookup(root, &dictionary.id, query, limit_per_dictionary)?);
        }
        Ok(result)
    }
}

pub fn lookup(
    root: &Path,
    dictionary_id: &str,
    query: &str,
    limit: usize,
) -> Result<Vec<LookupEntry>> {
    let (package, manifest) = open_manifest(root, dictionary_id)?;
    let css = load_package_css(&package);
    let connection = Connection::open(package.join("Library.sqlite3"))?;
    configure_read_connection(&connection)?;
    let exact = normalize_key(query);
    if exact.is_empty() {
        return Ok(Vec::new());
    }
    let limit = limit.clamp(1, 100);
    let resource_root = package.join("resources").to_string_lossy().into_owned();
    let mut result = Vec::with_capacity(limit);
    {
        let mut statement = connection.prepare(
            "SELECT key, record_text FROM entries
             WHERE normalized = ?1 ORDER BY key LIMIT ?2",
        )?;
        let rows = statement.query_map(params![exact, limit as i64], |row| {
            Ok(LookupEntry {
                key: row.get(0)?,
                text: row.get(1)?,
                dictionary_id: manifest.id.clone(),
                dictionary_title: manifest.title.clone(),
                css: css.clone(),
                resource_root: Some(resource_root.clone()),
            })
        })?;
        result.extend(rows.collect::<rusqlite::Result<Vec<_>>>()?);
    }
    if result.len() < limit {
        let remaining = limit - result.len();
        let prefix = format!("{}%", escape_like_pattern(&exact));
        let mut statement = connection.prepare(
            "SELECT key, record_text FROM entries
             WHERE normalized LIKE ?1 ESCAPE '\\'
               AND normalized != ?2
             ORDER BY length(normalized), key LIMIT ?3",
        )?;
        let rows = statement.query_map(params![prefix, exact, remaining as i64], |row| {
            Ok(LookupEntry {
                key: row.get(0)?,
                text: row.get(1)?,
                dictionary_id: manifest.id.clone(),
                dictionary_title: manifest.title.clone(),
                css: css.clone(),
                resource_root: Some(resource_root.clone()),
            })
        })?;
        result.extend(rows.collect::<rusqlite::Result<Vec<_>>>()?);
    }
    Ok(result)
}

pub fn lookup_all(
    root: &Path,
    query: &str,
    limit_per_dictionary: usize,
) -> Result<Vec<LookupEntry>> {
    let mut result = Vec::new();
    for dictionary in list_dictionaries(root)? {
        result.extend(lookup(root, &dictionary.id, query, limit_per_dictionary)?);
    }
    Ok(result)
}

pub fn resource(root: &Path, dictionary_id: &str, key: &str) -> Result<Option<ResourceResult>> {
    let (package, _manifest) = open_manifest(root, dictionary_id)?;
    let connection = Connection::open(package.join("Library.sqlite3"))?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    let record: Option<(String, String, i64)> = connection
        .query_row(
            "SELECT key, path, size FROM resources WHERE key = ?1",
            params![key],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let record = match record {
        Some(record) => Some(record),
        None => {
            // MDD keys are commonly written with a leading slash or
            // backslash. WebKit normalizes the sound URL before it reaches
            // this function, so compare a slash-normalized form as well.
            let normalized = key.trim_matches(['/', '\\']).replace('\\', "/");
            connection
                .query_row(
                    "SELECT key, path, size FROM resources
                     WHERE lower(trim(replace(key, char(92), '/'), '/')) = lower(?1)
                     LIMIT 1",
                    params![normalized],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?
        }
    };
    Ok(record.map(|(stored_key, path, size)| ResourceResult {
        key: stored_key,
        path: package
            .join("resources")
            .join(path)
            .to_string_lossy()
            .into_owned(),
        size: size.max(0) as u64,
    }))
}

const AUDIO_EXTENSIONS: [&str; 10] = [
    ".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac", ".aiff", ".aif", ".caf", ".opus",
];

fn audio_word_variants(word: &str) -> Vec<String> {
    let trimmed = word.trim().to_lowercase();
    let normalized = normalize_key(&trimmed);
    let mut variants = Vec::new();
    for value in [
        trimmed,
        normalized.clone(),
        normalized.replace(' ', "_"),
        normalized.replace(' ', "-"),
        normalized.replace(' ', ""),
    ] {
        if !value.is_empty() && !variants.contains(&value) {
            variants.push(value);
        }
    }
    variants
}

/// Find an audio resource whose filename corresponds to a word. MDX entries
/// can still use an explicit `sound:` key, but this fallback is needed for
/// the standalone pronunciation button before a definition has been loaded.
/// The Swift adapter searches installed packages in UI priority order and
/// returns no result when none has a matching audio resource.
pub fn find_audio_resource(
    root: &Path,
    dictionary_id: &str,
    word: &str,
) -> Result<Option<ResourceResult>> {
    let (package, _manifest) = open_manifest(root, dictionary_id)?;
    let connection = Connection::open(package.join("Library.sqlite3"))?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;

    for variant in audio_word_variants(word) {
        for extension in AUDIO_EXTENSIONS {
            let candidate = format!("{variant}{extension}");
            let exact: Option<(String, String, i64)> = connection
                .query_row(
                    "SELECT key, path, size FROM resources
                     WHERE lower(key) = lower(?1) AND size > 0 LIMIT 1",
                    params![candidate],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?;

            let match_result = if exact.is_some() {
                exact
            } else {
                let suffix = format!("%/{}", escape_like_pattern(&candidate));
                connection
                    .query_row(
                        "SELECT key, path, size FROM resources
                         WHERE replace(lower(key), char(92), '/') LIKE ?1 ESCAPE '\\'
                           AND size > 0 LIMIT 1",
                        params![suffix],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                    )
                    .optional()?
            };

            if let Some((key, path, size)) = match_result {
                return Ok(Some(ResourceResult {
                    key,
                    path: package
                        .join("resources")
                        .join(path)
                        .to_string_lossy()
                        .into_owned(),
                    size: size.max(0) as u64,
                }));
            }
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn be_u16(value: u16, out: &mut Vec<u8>) {
        out.extend_from_slice(&value.to_be_bytes());
    }
    fn be_u32(value: u32, out: &mut Vec<u8>) {
        out.extend_from_slice(&value.to_be_bytes());
    }
    fn be_u64(value: u64, out: &mut Vec<u8>) {
        out.extend_from_slice(&value.to_be_bytes());
    }

    fn block(data: &[u8]) -> Vec<u8> {
        let mut out = vec![0, 0, 0, 0, 0, 0, 0, 0];
        out.extend_from_slice(data);
        out
    }

    fn fast_encrypt(data: &[u8], key: &[u8; 16]) -> Vec<u8> {
        let mut output = Vec::with_capacity(data.len());
        let mut previous = 0x36u8;
        for (index, &plain) in data.iter().enumerate() {
            let value = (plain ^ previous ^ (index as u8) ^ key[index % key.len()]).rotate_left(4);
            output.push(value);
            previous = value;
        }
        output
    }

    fn fixture() -> Vec<u8> {
        fixture_with_final_key_terminator(true)
    }

    fn fixture_with_final_key_terminator(final_key_terminator: bool) -> Vec<u8> {
        let header = "<Dictionary GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encrypted=\"0\" Encoding=\"UTF-8\" Format=\"Text\" Title=\"Fixture\"/>";
        let header_bytes: Vec<u8> = header.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut output = Vec::new();
        be_u32(header_bytes.len() as u32, &mut output);
        output.extend_from_slice(&header_bytes);
        output.extend_from_slice(&[0, 0, 0, 0]);

        let records = b"feline\0animal\0";
        let mut keys = Vec::new();
        be_u64(0, &mut keys);
        keys.extend_from_slice(b"cat\0");
        be_u64(7, &mut keys);
        keys.extend_from_slice(b"dog");
        if final_key_terminator {
            keys.push(0);
        }
        let key_block = block(&keys);

        let mut key_index = Vec::new();
        be_u64(2, &mut key_index);
        be_u16(3, &mut key_index);
        key_index.extend_from_slice(b"cat");
        key_index.push(0);
        be_u16(3, &mut key_index);
        key_index.extend_from_slice(b"dog");
        key_index.push(0);
        be_u64(key_block.len() as u64, &mut key_index);
        be_u64(keys.len() as u64, &mut key_index);
        let key_index_block = block(&key_index);

        be_u64(1, &mut output);
        be_u64(2, &mut output);
        be_u64(key_index.len() as u64, &mut output);
        be_u64(key_index_block.len() as u64, &mut output);
        be_u64(key_block.len() as u64, &mut output);
        be_u32(0, &mut output);
        output.extend_from_slice(&key_index_block);
        output.extend_from_slice(&key_block);

        let record_block = block(records);
        be_u64(1, &mut output);
        be_u64(2, &mut output);
        be_u64(16, &mut output);
        be_u64(record_block.len() as u64, &mut output);
        be_u64(record_block.len() as u64, &mut output);
        be_u64(records.len() as u64, &mut output);
        output.extend_from_slice(&record_block);
        output
    }

    fn utf16_fixture_with_final_key_terminator(final_key_terminator: bool) -> Vec<u8> {
        let header = "<Dictionary GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encrypted=\"0\" Encoding=\"UTF-16\" Format=\"Text\" Title=\"UTF16 Fixture\"/>";
        let header_bytes: Vec<u8> = header.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut output = Vec::new();
        be_u32(header_bytes.len() as u32, &mut output);
        output.extend_from_slice(&header_bytes);
        output.extend_from_slice(&[0, 0, 0, 0]);

        let mut records = Vec::new();
        records.extend("feline".encode_utf16().flat_map(u16::to_le_bytes));
        records.extend_from_slice(&[0, 0]);
        records.extend("animal".encode_utf16().flat_map(u16::to_le_bytes));
        records.extend_from_slice(&[0, 0]);

        let mut keys = Vec::new();
        be_u64(0, &mut keys);
        keys.extend("cat".encode_utf16().flat_map(u16::to_le_bytes));
        keys.extend_from_slice(&[0, 0]);
        be_u64(14, &mut keys);
        keys.extend("dog".encode_utf16().flat_map(u16::to_le_bytes));
        if final_key_terminator {
            keys.extend_from_slice(&[0, 0]);
        }
        let key_block = block(&keys);

        let mut key_index = Vec::new();
        be_u64(2, &mut key_index);
        be_u16(6, &mut key_index);
        key_index.extend("cat".encode_utf16().flat_map(u16::to_le_bytes));
        be_u16(6, &mut key_index);
        key_index.extend("dog".encode_utf16().flat_map(u16::to_le_bytes));
        be_u64(key_block.len() as u64, &mut key_index);
        be_u64(keys.len() as u64, &mut key_index);
        let key_index_block = block(&key_index);

        be_u64(1, &mut output);
        be_u64(2, &mut output);
        be_u64(key_index.len() as u64, &mut output);
        be_u64(key_index_block.len() as u64, &mut output);
        be_u64(key_block.len() as u64, &mut output);
        be_u32(0, &mut output);
        output.extend_from_slice(&key_index_block);
        output.extend_from_slice(&key_block);

        let record_block = block(&records);
        be_u64(1, &mut output);
        be_u64(2, &mut output);
        be_u64(16, &mut output);
        be_u64(record_block.len() as u64, &mut output);
        be_u64(record_block.len() as u64, &mut output);
        be_u64(records.len() as u64, &mut output);
        output.extend_from_slice(&record_block);
        output
    }

    fn mdd_fixture(resources: &[(&str, &[u8])]) -> Vec<u8> {
        let header = "<Dictionary GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encrypted=\"0\" Format=\"Binary\" Title=\"Resources\" Library_Data=\"1\"/>";
        let header_bytes: Vec<u8> = header.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut output = Vec::new();
        be_u32(header_bytes.len() as u32, &mut output);
        output.extend_from_slice(&header_bytes);
        output.extend_from_slice(&[0, 0, 0, 0]);

        let mut record_bytes = Vec::new();
        let mut keys = Vec::new();
        for (key, bytes) in resources {
            be_u64(record_bytes.len() as u64, &mut keys);
            keys.extend(key.encode_utf16().flat_map(u16::to_le_bytes));
            keys.extend_from_slice(&[0, 0]);
            record_bytes.extend_from_slice(bytes);
        }
        let key_block = block(&keys);
        let first = resources.first().map(|(key, _)| *key).unwrap_or("");
        let last = resources.last().map(|(key, _)| *key).unwrap_or("");
        let mut key_index = Vec::new();
        be_u64(resources.len() as u64, &mut key_index);
        be_u16(first.encode_utf16().count() as u16 * 2, &mut key_index);
        key_index.extend(first.encode_utf16().flat_map(u16::to_le_bytes));
        be_u16(last.encode_utf16().count() as u16 * 2, &mut key_index);
        key_index.extend(last.encode_utf16().flat_map(u16::to_le_bytes));
        be_u64(key_block.len() as u64, &mut key_index);
        be_u64(keys.len() as u64, &mut key_index);
        let key_index_block = block(&key_index);

        be_u64(1, &mut output);
        be_u64(resources.len() as u64, &mut output);
        be_u64(key_index.len() as u64, &mut output);
        be_u64(key_index_block.len() as u64, &mut output);
        be_u64(key_block.len() as u64, &mut output);
        be_u32(0, &mut output);
        output.extend_from_slice(&key_index_block);
        output.extend_from_slice(&key_block);

        let record_block = block(&record_bytes);
        be_u64(1, &mut output);
        be_u64(resources.len() as u64, &mut output);
        be_u64(16, &mut output);
        be_u64(record_block.len() as u64, &mut output);
        be_u64(record_block.len() as u64, &mut output);
        be_u64(record_bytes.len() as u64, &mut output);
        output.extend_from_slice(&record_block);
        output
    }

    #[test]
    fn imports_and_queries_uncompressed_mdx() {
        let root = std::env::temp_dir().join(format!("studymate-dict-test-{}", now_seconds()));
        let source = root.join("fixture.mdx");
        fs::create_dir_all(&root).unwrap();
        fs::write(&source, fixture()).unwrap();
        // Several production MDX dictionaries load JavaScript configuration
        // from a sibling `.ini` file via `<script src="...">`.
        fs::write(root.join("config.ini"), b"window.fixtureEnabled = true;").unwrap();
        fs::write(root.join("dictionary.js"), b"window.fixtureReady = true").unwrap();
        let package_root = root.join("Dictionaries");
        let result = import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx: source,
            mdd: Vec::new(),
            id: Some("fixture".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();
        assert_eq!(result.dictionary.entry_count, 2);
        assert_eq!(result.dictionary.resource_count, 2);
        let config = resource(&package_root, "fixture", "config.ini")
            .unwrap()
            .expect("script-style ini sibling should be imported");
        assert_eq!(
            fs::read(config.path).unwrap(),
            b"window.fixtureEnabled = true;"
        );
        let script = resource(&package_root, "fixture", "dictionary.js")
            .unwrap()
            .expect("sibling JavaScript should be imported");
        assert_eq!(
            fs::read(script.path).unwrap(),
            b"window.fixtureReady = true"
        );
        let matches = lookup(&package_root, "fixture", "cat", 20).unwrap();
        assert_eq!(matches[0].text, "feline");
        assert_eq!(
            lookup(&package_root, "fixture", "do", 20).unwrap()[0].key,
            "dog"
        );
        let mut cache = DictionaryQueryCache::default();
        let key_hits = cache
            .lookup_keys(&package_root, "fixture", "do", 20)
            .unwrap();
        assert_eq!(key_hits[0].key, "dog");
        let cached_entries = cache.lookup(&package_root, "fixture", "cat", 1).unwrap();
        assert_eq!(cached_entries[0].text, "feline");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn imports_mdx_when_final_utf8_key_has_no_terminator() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-unterminated-key-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        let source = root.join("fixture.mdx");
        fs::create_dir_all(&root).unwrap();
        fs::write(&source, fixture_with_final_key_terminator(false)).unwrap();
        let package_root = root.join("Dictionaries");
        import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx: source,
            mdd: Vec::new(),
            id: Some("fixture".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();
        assert_eq!(
            lookup(&package_root, "fixture", "dog", 20).unwrap()[0].text,
            "animal"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn imports_mdx_when_final_utf16_key_has_no_terminator() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-unterminated-utf16-key-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        let source = root.join("fixture.mdx");
        fs::create_dir_all(&root).unwrap();
        fs::write(&source, utf16_fixture_with_final_key_terminator(false)).unwrap();
        let package_root = root.join("Dictionaries");
        import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx: source,
            mdd: Vec::new(),
            id: Some("fixture".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();
        assert_eq!(
            lookup(&package_root, "fixture", "dog", 20).unwrap()[0].text,
            "animal"
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn deletes_imported_dictionary_and_reports_missing_package() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-delete-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        let source = root.join("fixture.mdx");
        fs::create_dir_all(&root).unwrap();
        fs::write(&source, fixture()).unwrap();
        let package_root = root.join("Dictionaries");
        import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx: source,
            mdd: Vec::new(),
            id: Some("fixture".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();

        let abandoned = package_root.join(".fixture.mabdict.import-abandoned");
        fs::create_dir_all(&abandoned).unwrap();
        fs::write(abandoned.join("records.tmp"), b"partial").unwrap();
        assert_eq!(list_dictionaries(&package_root).unwrap().len(), 1);
        assert!(!abandoned.exists());
        fs::create_dir_all(&abandoned).unwrap();
        fs::write(abandoned.join("records.tmp"), b"partial").unwrap();
        assert!(delete_dictionary(&package_root, "fixture").unwrap());
        assert!(list_dictionaries(&package_root).unwrap().is_empty());
        assert!(!abandoned.exists());
        assert!(!delete_dictionary(&package_root, "fixture").unwrap());
        let orphaned_after_delete = package_root.join(".fixture.mabdict.import-orphaned");
        fs::create_dir_all(&orphaned_after_delete).unwrap();
        assert!(!delete_dictionary(&package_root, "fixture").unwrap());
        assert!(!orphaned_after_delete.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn mdict_crypto_primitives_match_known_vectors() {
        assert_eq!(
            ripemd128(b"")
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>(),
            "cdf26213a150dc3ecb610f18f6b38b46"
        );
        assert_eq!(
            ripemd128(b"a")
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>(),
            "86be7afa339d0fc7cfc785e72f578d33"
        );
        let key = [0x42u8; 16];
        let plaintext = b"encrypted mdx key header";
        let stream = salsa20_8_xor(plaintext, &key);
        assert_eq!(salsa20_8_xor(&stream, &key), plaintext);
    }

    #[test]
    fn imports_matching_numbered_mdd_volumes_and_finds_audio_resource() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-mdd-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("TLD.mdx");
        let mdd = root.join("TLD.mdd");
        let numbered = root.join("TLD.1.mdd");
        fs::write(&mdx, fixture()).unwrap();
        fs::write(&mdd, mdd_fixture(&[(r"\audio/cat.mp3", b"audio-one")])).unwrap();
        fs::write(&numbered, mdd_fixture(&[("audio/dog.mp3", b"audio-two")])).unwrap();

        let discovered = discover_mdd_paths(&mdx, &[]);
        assert_eq!(
            discovered,
            vec![mdd.clone(), numbered.clone()],
            "volumes should be ordered base then numbered"
        );
        assert_eq!(
            discover_mdd_paths(&mdx, &[numbered.clone(), mdd.clone()]),
            vec![mdd.clone(), numbered.clone()],
            "explicit and discovered volumes should be merged and deduplicated"
        );

        let package_root = root.join("Dictionaries");
        let imported = import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx,
            mdd: Vec::new(),
            id: Some("tld".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();
        assert_eq!(imported.dictionary.resource_count, 2);

        let audio = find_audio_resource(&package_root, "tld", "CAT")
            .unwrap()
            .expect("MDD audio should match by filename");
        assert_eq!(audio.key, r"\audio/cat.mp3");
        assert_eq!(fs::read(audio.path).unwrap(), b"audio-one");
        let direct = resource(&package_root, "tld", "/audio/cat.mp3")
            .unwrap()
            .expect("sound URL should resolve slash-normalized MDD key");
        assert_eq!(fs::read(direct.path).unwrap(), b"audio-one");
        assert!(find_audio_resource(&package_root, "tld", "missing")
            .unwrap()
            .is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn imports_nonstandard_sibling_mdd_when_no_conventional_volume_exists() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-nonstandard-mdd-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("LDOCE5++ V 2-15.mdx");
        let resource_volume = root.join("LDOCE5++ resources.mdd");
        fs::write(&mdx, fixture()).unwrap();
        fs::write(
            &resource_volume,
            mdd_fixture(&[
                ("jquery-3.2.1.min.js", b"window.jQuery = {};"),
                ("LM5style_switch.css", b".foldsign_fold { display: none; }"),
            ]),
        )
        .unwrap();

        assert_eq!(discover_mdd_paths(&mdx, &[]), vec![resource_volume.clone()]);

        let package_root = root.join("Dictionaries");
        let imported = import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx,
            mdd: Vec::new(),
            id: Some("ldoce-fixture".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();
        assert_eq!(imported.dictionary.resource_count, 2);
        assert!(
            resource(&package_root, "ldoce-fixture", "jquery-3.2.1.min.js")
                .unwrap()
                .is_some()
        );
        assert!(
            resource(&package_root, "ldoce-fixture", "LM5style_switch.css")
                .unwrap()
                .is_some()
        );

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn imports_encrypted_key_index_without_registration() {
        let mut source_bytes = fixture();
        let header_len = u32::from_be_bytes(source_bytes[..4].try_into().unwrap()) as usize;
        let header_start = 4;
        let marker: Vec<u8> = "Encrypted=\"0\""
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        let marker_pos = source_bytes[header_start..header_start + header_len]
            .windows(marker.len())
            .position(|window| window == marker)
            .expect("fixture encryption marker")
            + header_start;
        source_bytes[marker_pos + marker.len() - 4] = b'2';

        let key_header_start = header_start + header_len + 4;
        let key_index_len = u64::from_be_bytes(
            source_bytes[key_header_start + 24..key_header_start + 32]
                .try_into()
                .unwrap(),
        ) as usize;
        let key_index_start = key_header_start + 44;
        let key = ripemd128(&[0, 0, 0, 0, 0x95, 0x36, 0, 0]);
        let encrypted = fast_encrypt(
            &source_bytes[key_index_start + 8..key_index_start + key_index_len],
            &key,
        );
        assert_eq!(
            fast_decrypt(&encrypted, &key),
            source_bytes[key_index_start + 8..key_index_start + key_index_len]
        );
        source_bytes[key_index_start + 8..key_index_start + key_index_len]
            .copy_from_slice(&encrypted);

        let root = std::env::temp_dir().join(format!("studymate-dict-encrypted-{}", now_seconds()));
        let source = root.join("encrypted-fixture.mdx");
        fs::create_dir_all(&root).unwrap();
        fs::write(&source, source_bytes).unwrap();
        let package_root = root.join("Dictionaries");
        let result = import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx: source,
            mdd: Vec::new(),
            id: Some("encrypted-fixture".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();
        assert_eq!(result.dictionary.entry_count, 2);
        assert_eq!(
            lookup(&package_root, "encrypted-fixture", "cat", 20).unwrap()[0].text,
            "feline"
        );
        fs::remove_dir_all(root).unwrap();
    }
}
