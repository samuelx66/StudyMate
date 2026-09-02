//! StudyMate's cross-platform dictionary core.
//!
//! The core deliberately knows nothing about SwiftUI, AppKit, or the host
//! operating system. It keeps standard MDX/MDD files in a portable directory
//! package and exposes deterministic exact/prefix lookup by reading only the
//! relevant compressed blocks on demand.
//! The JSONL process in studymate-dict is only one adapter; mobile and
//! Windows clients can link this crate through a C ABI in a later release.

use anyhow::{anyhow, bail, Context, Result};
use encoding_rs::{BIG5, GBK, UTF_16LE, UTF_8};
use flate2::read::ZlibDecoder;
use ripemd::{Digest, Ripemd128};
use serde::{Deserialize, Serialize};
use std::collections::{hash_map::DefaultHasher, HashMap, HashSet, VecDeque};
use std::fs::{self, File};
use std::hash::{Hash, Hasher};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const PACKAGE_VERSION: u32 = 4;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DictionaryManifest {
    pub version: u32,
    pub id: String,
    pub title: String,
    pub source_file: String,
    pub encoding: String,
    pub format: String,
    #[serde(default)]
    pub key_case_sensitive: bool,
    pub entry_count: u64,
    pub resource_count: u64,
    pub imported_at: u64,
    /// Relative MDD volume paths in the self-contained source directory.
    /// This preserves explicitly selected non-standard volumes when a
    /// dictionary also has conventional `<stem>.mdd` volumes.
    #[serde(default)]
    pub mdd_files: Vec<String>,
    /// Hex-encoded key derived during import for encrypted MDX/MDD files.
    /// This is package metadata, not a content index; without it an encrypted
    /// dictionary would become unreadable after the import dialog closes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encryption_key: Option<String>,
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
    pub format: String,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceDataResult {
    pub key: String,
    pub data_base64: String,
    pub mime_type: String,
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
    version: f32,
    title: String,
    encoding: String,
    format: String,
    encrypted: u8,
    is_mdd: bool,
    compact: bool,
    key_case_sensitive: bool,
    stylesheet: HashMap<String, (String, String)>,
    registration_code: Option<Vec<u8>>,
    register_by: Option<String>,
}

#[derive(Debug, Clone)]
struct RawKey {
    key: String,
    offset: u64,
}

#[derive(Debug, Clone)]
struct KeyBlockIndex {
    first_key: String,
    last_key: String,
    compressed_offset: u64,
    compressed_size: u64,
    decompressed_size: usize,
}

#[derive(Debug, Clone)]
struct RecordBlockIndex {
    compressed_offset: u64,
    compressed_size: u64,
    decompressed_size: usize,
    uncompressed_offset: u64,
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

fn normalize_search_key(value: &str, case_sensitive: bool) -> String {
    let collapsed = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if case_sensitive {
        collapsed
    } else {
        collapsed.to_lowercase()
    }
}

/// MDict builders do not order key blocks by the display spelling verbatim.
/// Their conventional ordering compares (1) a key with punctuation removed,
/// then (2) a version where punctuation is replaced with `~`, and finally
/// the original lower-cased key.  Using ordinary `String` ordering here makes
/// dictionaries such as OALD skip otherwise valid blocks at punctuation and
/// whitespace boundaries.
fn mdict_sort_key(value: &str, case_sensitive: bool) -> (String, String, String) {
    let key = normalize_search_key(value, case_sensitive);
    let mut compact = String::with_capacity(key.len());
    let mut punctuation_order = String::with_capacity(key.len());
    for character in key.chars() {
        if character.is_alphanumeric() || character as u32 >= 128 {
            compact.push(character);
            punctuation_order.push(character);
        } else {
            punctuation_order.push('~');
        }
    }
    (compact, punctuation_order, key)
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

fn unique_named_path(directory: &Path, file_name: &str) -> PathBuf {
    let original = Path::new(file_name);
    let stem = original
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("file");
    let extension = original.extension().and_then(|value| value.to_str());
    let mut candidate = directory.join(file_name);
    let mut suffix = 1u64;
    while candidate.exists() {
        let name = match extension {
            Some(extension) => format!("{stem}-{suffix}.{extension}"),
            None => format!("{stem}-{suffix}"),
        };
        candidate = directory.join(name);
        suffix = suffix.saturating_add(1);
    }
    candidate
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
    let wanted = name.to_ascii_lowercase();
    let bytes = header.as_bytes();
    let mut cursor = 0;
    while cursor < bytes.len() {
        while cursor < bytes.len()
            && (bytes[cursor].is_ascii_whitespace() || matches!(bytes[cursor], b'<' | b'>' | b'/'))
        {
            cursor += 1;
        }
        let name_start = cursor;
        while cursor < bytes.len()
            && !bytes[cursor].is_ascii_whitespace()
            && !matches!(bytes[cursor], b'=' | b'>' | b'/')
        {
            cursor += 1;
        }
        if name_start == cursor {
            cursor += 1;
            continue;
        }
        let candidate = header.get(name_start..cursor)?.to_ascii_lowercase();
        while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= bytes.len() || bytes[cursor] != b'=' {
            continue;
        }
        cursor += 1;
        while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
            cursor += 1;
        }
        if cursor >= bytes.len() {
            return None;
        }
        let quote = matches!(bytes[cursor], b'\'' | b'"').then_some(bytes[cursor]);
        if quote.is_some() {
            cursor += 1;
        }
        let value_start = cursor;
        if let Some(quote) = quote {
            while cursor < bytes.len() && bytes[cursor] != quote {
                cursor += 1;
            }
        } else {
            while cursor < bytes.len()
                && !bytes[cursor].is_ascii_whitespace()
                && !matches!(bytes[cursor], b'>' | b'/')
            {
                cursor += 1;
            }
        }
        let value = decode_xml_entities(header.get(value_start..cursor)?);
        if candidate == wanted {
            return Some(value);
        }
        if quote.is_some() && cursor < bytes.len() {
            cursor += 1;
        }
    }
    None
}

/// MDict headers are XML attributes, but the reverse-engineered readers only
/// need the four predefined XML entities used by real dictionaries. Decode
/// them after locating the quoted value so an escaped quote cannot terminate
/// attribute scanning early. Keep replacement order compatible with the
/// established mdict-utils reader: `&amp;` is last so `&amp;lt;` remains the
/// literal text `&lt;` rather than becoming `<`.
fn decode_xml_entities(value: &str) -> String {
    value
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&amp;", "&")
}

fn decode_text(bytes: &[u8], encoding: &str) -> String {
    let normalized = encoding.replace('-', "").to_ascii_uppercase();
    let (text, _, _) = match normalized.as_str() {
        "UTF16" | "UTF16LE" => UTF_16LE.decode(bytes),
        "GBK" | "CP936" => GBK.decode(bytes),
        "BIG5" => BIG5.decode(bytes),
        _ => UTF_8.decode(bytes),
    };
    text.trim_matches('\0').to_owned()
}

fn decode_header(bytes: &[u8]) -> Result<String> {
    if bytes.len() % 2 != 0 {
        bail!("MDX header has an odd UTF-16 length")
    }
    Ok(decode_text(bytes, "UTF-16LE"))
}

fn parse_header_version(header: &str) -> Result<f32> {
    let raw = parse_attr(header, "GeneratedByEngineVersion")
        .or_else(|| parse_attr(header, "RequiredEngineVersion"))
        .unwrap_or_else(|| "2.0".to_owned());
    let version = raw
        .trim()
        .parse::<f32>()
        .with_context(|| format!("invalid MDX engine version {raw:?}"))?;
    if !version.is_finite() || version < 1.0 {
        bail!("unsupported MDX engine version {raw:?}")
    }
    if version >= 3.0 {
        bail!("MDX/MDD v{version:.1} is not supported by this v1/v2 importer")
    }
    Ok(version)
}

fn parse_yes(value: Option<String>) -> bool {
    value
        .as_deref()
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "yes" | "true" | "1"
            )
        })
        .unwrap_or(false)
}

fn parse_stylesheet(value: Option<String>) -> Result<HashMap<String, (String, String)>> {
    let mut stylesheet = HashMap::new();
    let Some(value) = value else {
        return Ok(stylesheet);
    };
    if value.is_empty() {
        return Ok(stylesheet);
    }
    // `str::lines()` discards the final empty line, which is meaningful here:
    // a stylesheet group may deliberately have an empty style_end. Split on
    // LF instead, normalize CRLF, and discard only separator newlines that
    // leave a complete three-line group behind.
    let mut lines = value
        .split('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line))
        .collect::<Vec<_>>();
    while lines.last().is_some_and(|line| line.is_empty()) && lines.len() % 3 != 0 {
        lines.pop();
    }
    if lines.is_empty() {
        return Ok(stylesheet);
    }
    if lines.len() % 3 != 0 {
        bail!(
            "MDX StyleSheet has {} lines; expected groups of three",
            lines.len()
        )
    }
    for group in lines.chunks_exact(3) {
        let number = group[0].trim();
        if number.is_empty() || !number.chars().all(|character| character.is_ascii_digit()) {
            bail!("MDX StyleSheet has invalid style number {:?}", group[0])
        }
        stylesheet.insert(
            number.to_owned(),
            (group[1].to_owned(), group[2].to_owned()),
        );
    }
    Ok(stylesheet)
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
    let expected_checksum = u32::from_le_bytes(checksum);
    if expected_checksum != 0 && expected_checksum != adler32(&header_bytes) {
        bail!("MDX header checksum mismatch")
    }
    let header_string = decode_header(&header_bytes)?;
    let version = parse_header_version(&header_string)?;
    let is_mdd = header_string.to_ascii_lowercase().contains("library_data");
    let encrypted = parse_attr(&header_string, "Encrypted")
        .map(|value| match value.trim().to_ascii_lowercase().as_str() {
            "yes" => 1,
            "no" => 0,
            other => other.parse::<u8>().unwrap_or_default(),
        })
        .unwrap_or_default();
    if encrypted > 3 {
        bail!("invalid MDX Encrypted value {encrypted}; expected 0..3")
    }
    let encoding = if is_mdd {
        "UTF-16".to_owned()
    } else {
        parse_attr(&header_string, "Encoding").unwrap_or_else(|| "UTF-8".to_owned())
    };
    let title = parse_attr(&header_string, "Title")
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "未命名词典".to_owned());
    let format = parse_attr(&header_string, "Format").unwrap_or_else(|| "Html".to_owned());
    let compact = parse_yes(parse_attr(&header_string, "Compact"))
        || parse_yes(parse_attr(&header_string, "Compat"));
    let stylesheet = parse_stylesheet(parse_attr(&header_string, "StyleSheet"))?;
    let key_case_sensitive = parse_yes(parse_attr(&header_string, "KeyCaseSensitive"));
    let registration_code = parse_attr(&header_string, "RegCode")
        .and_then(|value| parse_hex_key(&value).filter(|bytes| bytes.len() == 16));
    let register_by = parse_attr(&header_string, "RegisterBy");
    Ok((
        Header {
            version,
            title,
            encoding,
            format,
            encrypted,
            is_mdd,
            compact,
            key_case_sensitive,
            stylesheet,
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
    let expected_checksum = u32::from_be_bytes(block[4..8].try_into().unwrap());
    let mut compressed = block[8..].to_vec();
    if encryption_method != 0 {
        let size = encryption_size;
        if size > compressed.len() {
            bail!(
                "encrypted MDX block is truncated (wanted {} bytes, got {})",
                size,
                compressed.len()
            )
        }
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
    if expected_checksum != 0 && expected_checksum != adler32(&output) {
        bail!("MDX block checksum mismatch")
    }
    Ok(output)
}

fn expand_compact_record(record: &str, stylesheet: &HashMap<String, (String, String)>) -> String {
    if stylesheet.is_empty() {
        return record.to_owned();
    }
    let mut expanded = String::with_capacity(record.len());
    let mut cursor = 0;
    let mut active_end: Option<&str> = None;
    while cursor < record.len() {
        let remaining = &record[cursor..];
        let Some(open_offset) = remaining.find('`') else {
            expanded.push_str(remaining);
            break;
        };
        let open = cursor + open_offset;
        let Some(close_offset) = record[open + 1..].find('`') else {
            // Preserve malformed/unknown compact text for diagnosis rather
            // than dropping the tail of a definition.
            if let Some(end) = active_end.take() {
                expanded.push_str(end);
            }
            expanded.push_str(&record[cursor..]);
            break;
        };
        let close = open + 1 + close_offset;
        if let Some(end) = active_end.take() {
            expanded.push_str(end);
        }
        expanded.push_str(&record[cursor..open]);
        let style_number = &record[open + 1..close];
        if let Some((begin, end)) = stylesheet.get(style_number) {
            expanded.push_str(begin);
            active_end = Some(end.as_str());
        } else {
            expanded.push_str(&record[open..=close]);
        }
        cursor = close + 1;
    }
    if let Some(end) = active_end {
        expanded.push_str(end);
    }
    expanded
}

fn decode_record_text(bytes: &[u8], header: &Header) -> String {
    let text = decode_text(bytes, &header.encoding);
    if header.compact {
        expand_compact_record(&text, &header.stylesheet)
    } else {
        text
    }
}

fn parse_key_index_layout(
    bytes: &[u8],
    blocks: usize,
    encoding: &str,
    includes_terminators: bool,
    sizes_are_code_units: bool,
) -> Result<Vec<(u64, String, String, usize, usize)>> {
    let mut reader = Reader::new(bytes);
    let unit = if encoding.to_ascii_uppercase().contains("UTF-16") {
        2
    } else {
        1
    };
    let mut block_sizes = Vec::with_capacity(blocks);
    for _ in 0..blocks {
        let entries = reader.u64()?;
        let first_units = reader.u16()? as usize;
        let first_size = if sizes_are_code_units {
            first_units
                .checked_mul(unit)
                .ok_or_else(|| anyhow!("MDX key index word length overflow"))?
        } else {
            first_units
        };
        let first = decode_text(reader.take(first_size)?, encoding);
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
        let last = decode_text(reader.take(last_size)?, encoding);
        if includes_terminators {
            reader.take(unit)?;
        }
        let compressed_size = reader.u64()? as usize;
        let decompressed_size = reader.u64()? as usize;
        block_sizes.push((entries, first, last, compressed_size, decompressed_size));
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

fn parse_key_index(
    bytes: &[u8],
    blocks: usize,
    encoding: &str,
) -> Result<Vec<(u64, String, String, usize, usize)>> {
    // MDX v2's canonical layout stores the NUL-terminated first/last words.
    // Their length fields are measured in bytes for single-byte encodings and
    // in UTF-16 code units for UTF-16.  Try that layout first; accepting a
    // legacy layout is still useful, but trying it first can accidentally
    // consume a valid UTF-16 index at the wrong byte boundaries and make every
    // subsequent lookup point at the wrong key blocks.
    let is_utf16 = encoding.to_ascii_uppercase().contains("UTF-16");
    let layouts = if is_utf16 {
        [(true, true), (true, false), (false, true), (false, false)]
    } else {
        [(true, false), (true, true), (false, false), (false, true)]
    };
    let mut last_error = None;
    for (includes_terminators, sizes_are_code_units) in layouts {
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
    Err(last_error.unwrap_or_else(|| anyhow!("MDX key index is invalid")))
}

fn parse_key_index_v1(
    bytes: &[u8],
    blocks: usize,
    encoding: &str,
) -> Result<Vec<(u64, String, String, usize, usize)>> {
    let mut reader = Reader::new(bytes);
    let unit = if encoding.to_ascii_uppercase().contains("UTF-16") {
        2
    } else {
        1
    };
    let mut block_sizes = Vec::with_capacity(blocks);
    for _ in 0..blocks {
        let entries = reader.u32()? as u64;
        let first_size = reader.take(1)?[0] as usize;
        let first = decode_text(
            reader.take(
                first_size
                    .checked_mul(unit)
                    .ok_or_else(|| anyhow!("MDX v1 key index word length overflow"))?,
            )?,
            encoding,
        );
        let last_size = reader.take(1)?[0] as usize;
        let last = decode_text(
            reader.take(
                last_size
                    .checked_mul(unit)
                    .ok_or_else(|| anyhow!("MDX v1 key index word length overflow"))?,
            )?,
            encoding,
        );
        let compressed_size = reader.u32()? as usize;
        let decompressed_size = reader.u32()? as usize;
        block_sizes.push((entries, first, last, compressed_size, decompressed_size));
    }
    if reader.remaining() != 0 {
        bail!(
            "MDX v1 key index has {} trailing bytes after {} blocks",
            reader.remaining(),
            blocks
        )
    }
    Ok(block_sizes)
}

fn parse_key_block(bytes: &[u8], header: &Header) -> Result<Vec<RawKey>> {
    let is_v2 = header.version >= 2.0;
    let mut raw_keys = Vec::new();
    let mut key_reader = Reader::new(bytes);
    while key_reader.remaining() > 0 {
        let offset = if is_v2 {
            key_reader.u64()?
        } else {
            key_reader.u32()? as u64
        };
        let key_bytes = if header.encoding.to_ascii_uppercase().contains("UTF-16") {
            let start = key_reader.pos;
            let mut end = start;
            let mut has_terminator = false;
            while end + 1 < bytes.len() {
                if bytes[end] == 0 && bytes[end + 1] == 0 {
                    has_terminator = true;
                    break;
                }
                end += 2;
            }
            let length = if has_terminator {
                end.saturating_sub(start)
            } else {
                // The last key in a number of real dictionaries has no NUL
                // terminator. The remaining complete UTF-16 code units are
                // still a valid key and must not be rejected as truncated.
                key_reader.remaining()
            };
            if length % 2 != 0 {
                bail!("unterminated UTF-16 MDX keyword has an odd byte length")
            }
            let bytes = key_reader.take(length)?.to_vec();
            if has_terminator {
                key_reader.take(2)?;
            }
            bytes
        } else {
            let start = key_reader.pos;
            let tail = &bytes[start..];
            let terminator = tail.iter().position(|b| *b == 0);
            let length = terminator.unwrap_or(tail.len());
            let bytes = key_reader.take(length)?.to_vec();
            if terminator.is_some() {
                key_reader.take(1)?;
            }
            bytes
        };
        let key = decode_text(&key_bytes, &header.encoding).trim().to_owned();
        if !key.is_empty() {
            raw_keys.push(RawKey { key, offset });
        }
    }
    Ok(raw_keys)
}

fn read_key_section_index(
    file: &mut File,
    header: &Header,
    encryption_key: Option<&[u8; 16]>,
) -> Result<(Vec<KeyBlockIndex>, u64)> {
    let is_v2 = header.version >= 2.0;
    let fixed_len = if is_v2 { 44 } else { 16 };
    let mut fixed = vec![0u8; fixed_len];
    file.read_exact(&mut fixed)
        .context("read MDX key section")?;
    if header.encrypted & 1 != 0 {
        let key = encryption_key.ok_or_else(|| {
            anyhow!(
                "this encrypted dictionary requires a registration code and user identity (RegisterBy={})",
                header.register_by.as_deref().unwrap_or("unknown")
            )
        })?;
        let encrypted_len = if is_v2 { 40 } else { 16 };
        let decrypted = salsa20_8_xor(&fixed[..encrypted_len], key);
        fixed[..encrypted_len].copy_from_slice(&decrypted);
        if is_v2 {
            let expected = u32::from_be_bytes(fixed[40..44].try_into().unwrap());
            let actual = adler32(&fixed[..40]);
            if expected != 0 && expected != actual {
                bail!("encrypted MDX key header could not be verified; check the user identity or registration code")
            }
        }
    }
    let mut reader = Reader::new(&fixed);
    let number = |reader: &mut Reader<'_>| -> Result<u64> {
        if is_v2 {
            reader.u64()
        } else {
            Ok(reader.u32()? as u64)
        }
    };
    let block_count = number(&mut reader)? as usize;
    let entry_count = number(&mut reader)?;
    let key_index_decomp_len = if is_v2 {
        number(&mut reader)? as usize
    } else {
        0
    };
    let key_index_comp_len = number(&mut reader)? as usize;
    let key_blocks_len = number(&mut reader)?;
    if is_v2 {
        let _ = reader.u32()?;
    }
    if block_count == 0 || block_count > 1_000_000 {
        bail!("invalid MDX key block count {}", block_count)
    }
    if key_index_comp_len > 512 * 1024 * 1024 {
        bail!("MDX key index is unreasonably large")
    }
    let mut key_index_compressed = vec![0u8; key_index_comp_len];
    file.read_exact(&mut key_index_compressed)
        .context("read MDX key index")?;
    if header.encrypted & 2 != 0 && !is_v2 {
        bail!("MDX v1 key index encryption is not supported")
    }
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
    let key_index = if is_v2 {
        decompress_block(&key_index_compressed, key_index_decomp_len, encryption_key)?
    } else {
        key_index_compressed
    };
    let descriptors = if is_v2 {
        parse_key_index(&key_index, block_count, &header.encoding)
    } else {
        parse_key_index_v1(&key_index, block_count, &header.encoding)
    }
    .context("parse MDX key index")?;
    let key_data_start = file.stream_position()?;
    let file_len = file.metadata()?.len();
    let mut offset = key_data_start;
    let mut blocks = Vec::with_capacity(descriptors.len());
    for (entries, first, last, compressed_size, decompressed_size) in descriptors {
        if compressed_size < 8 || compressed_size > 512 * 1024 * 1024 {
            bail!("invalid MDX key block size {}", compressed_size)
        }
        let compressed_size = compressed_size as u64;
        let end = offset
            .checked_add(compressed_size)
            .ok_or_else(|| anyhow!("MDX key block offset overflow"))?;
        if end > file_len {
            bail!(
                "MDX key block is truncated (wanted {} bytes at {})",
                compressed_size,
                offset
            )
        }
        let _ = entries;
        blocks.push(KeyBlockIndex {
            first_key: first,
            last_key: last,
            compressed_offset: offset,
            compressed_size,
            decompressed_size,
        });
        offset = end;
    }
    if offset - key_data_start != key_blocks_len {
        bail!(
            "MDX key blocks length mismatch (declared {}, consumed {})",
            key_blocks_len,
            offset - key_data_start
        )
    }
    file.seek(SeekFrom::Start(offset))?;
    Ok((blocks, entry_count))
}

fn read_record_section_index(
    file: &mut File,
    header: &Header,
) -> Result<(Vec<RecordBlockIndex>, u64, u64)> {
    let is_v2 = header.version >= 2.0;
    let fixed_len = if is_v2 { 32 } else { 16 };
    let mut fixed = vec![0u8; fixed_len];
    file.read_exact(&mut fixed)
        .context("read MDX record section")?;
    let mut reader = Reader::new(&fixed);
    let number = |reader: &mut Reader<'_>| -> Result<u64> {
        if is_v2 {
            reader.u64()
        } else {
            Ok(reader.u32()? as u64)
        }
    };
    let block_count = number(&mut reader)? as usize;
    let entry_count = number(&mut reader)?;
    let index_len = number(&mut reader)? as usize;
    let blocks_len = number(&mut reader)?;
    let width = if is_v2 { 8 } else { 4 };
    let expected_index_len = block_count
        .checked_mul(width * 2)
        .ok_or_else(|| anyhow!("MDX record index is unreasonably large"))?;
    if block_count > 1_000_000 || index_len != expected_index_len {
        bail!("invalid MDX record section")
    }
    let mut index = vec![0u8; index_len];
    file.read_exact(&mut index)
        .context("read MDX record index")?;
    let mut index_reader = Reader::new(&index);
    let data_start = file.stream_position()?;
    let file_len = file.metadata()?.len();
    let mut compressed_offset = data_start;
    let mut uncompressed_offset = 0u64;
    let mut blocks = Vec::with_capacity(block_count);
    for _ in 0..block_count {
        let compressed_size = number(&mut index_reader)?;
        let decompressed_size = usize::try_from(number(&mut index_reader)?)
            .map_err(|_| anyhow!("MDX record block size overflows platform usize"))?;
        if compressed_size < 8 || compressed_size > 1024 * 1024 * 1024 {
            bail!("invalid MDX record block size {}", compressed_size)
        }
        let end = compressed_offset
            .checked_add(compressed_size)
            .ok_or_else(|| anyhow!("MDX record block offset overflow"))?;
        if end > file_len {
            bail!(
                "MDX record block is truncated (wanted {} bytes at {})",
                compressed_size,
                compressed_offset
            )
        }
        blocks.push(RecordBlockIndex {
            compressed_offset,
            compressed_size,
            decompressed_size,
            uncompressed_offset,
        });
        compressed_offset = end;
        uncompressed_offset = uncompressed_offset
            .checked_add(decompressed_size as u64)
            .ok_or_else(|| anyhow!("MDX record bytes are too large"))?;
    }
    if index_reader.remaining() != 0 {
        bail!("MDX record index has trailing bytes")
    }
    if compressed_offset - data_start != blocks_len {
        bail!(
            "MDX record blocks length mismatch (declared {}, consumed {})",
            blocks_len,
            compressed_offset - data_start
        )
    }
    Ok((blocks, uncompressed_offset, entry_count))
}

fn safe_relative_path(value: &str) -> Option<PathBuf> {
    let normalized = value.replace('\\', "/");
    let trimmed = normalized.trim_start_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    let mut result = PathBuf::new();
    for component in Path::new(trimmed).components() {
        match component {
            std::path::Component::Normal(part) => result.push(part),
            // Resource keys are not allowed to escape the package resource
            // root. Empty and current-directory components are harmless and
            // are removed by the normalization above; parent/root/prefix
            // components are rejected instead of being silently rewritten.
            std::path::Component::CurDir => {}
            _ => return None,
        }
    }
    (!result.as_os_str().is_empty()).then_some(result)
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
    let source_dir = temp_package.join("source");
    fs::create_dir_all(&source_dir)?;
    if let Some(p) = progress.as_deref_mut() {
        p("正在复制词典目录…", 0.15);
    }

    let selected_mdx = fs::canonicalize(&options.mdx)
        .with_context(|| format!("resolve MDX source {}", options.mdx.display()))?;
    let original_root = selected_mdx
        .parent()
        .filter(|p| p.is_dir())
        .ok_or_else(|| anyhow!("MDX parent directory is not readable"))?
        .to_path_buf();
    let package_root = fs::canonicalize(&temp_package).unwrap_or_else(|_| temp_package.clone());
    let mut source_files = Vec::new();
    collect_source_files(
        &original_root,
        &original_root,
        &package_root,
        &mut source_files,
    )?;
    source_files.sort_by(|a, b| a.to_string_lossy().cmp(&b.to_string_lossy()));
    for path in &source_files {
        let relative = path
            .strip_prefix(&original_root)
            .map_err(|_| anyhow!("source file is outside MDX directory: {}", path.display()))?;
        let relative = safe_relative_path(&relative.to_string_lossy())
            .ok_or_else(|| anyhow!("unsafe source path: {}", relative.display()))?;
        let target = source_dir.join(&relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(path, &target).with_context(|| {
            format!(
                "copy dictionary file {} -> {}",
                path.display(),
                target.display()
            )
        })?;
    }
    let selected_mdds = discover_mdd_paths(&selected_mdx, &options.mdd);
    // Explicitly selected non-sibling MDD volumes are copied into the same
    // source folder, so the package is self-contained after import. Keep the
    // resulting relative paths in the manifest because a non-standard volume
    // must remain active even when conventional volumes are also present.
    let mut copied_mdd_paths = Vec::new();
    for mdd in &selected_mdds {
        if !mdd.is_file() {
            bail!("MDD file does not exist: {}", mdd.display())
        }
        let canonical = fs::canonicalize(&mdd)?;
        let target = if canonical.starts_with(&original_root) {
            let relative = canonical.strip_prefix(&original_root).map_err(|_| {
                anyhow!(
                    "MDD source is outside its parent directory: {}",
                    canonical.display()
                )
            })?;
            let target = source_dir.join(relative);
            if !target.is_file() {
                bail!("copied MDD source is missing: {}", target.display())
            }
            target
        } else {
            let name = mdd
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("resources.mdd");
            let target = unique_named_path(&source_dir, name);
            fs::copy(&mdd, &target).with_context(|| {
                format!("copy MDD source {} -> {}", mdd.display(), target.display())
            })?;
            target
        };
        copied_mdd_paths.push(target);
    }
    let relative_mdx = selected_mdx.strip_prefix(&original_root).map_err(|_| {
        anyhow!(
            "MDX source is outside its parent directory: {}",
            selected_mdx.display()
        )
    })?;
    let source_mdx = source_dir.join(relative_mdx);
    if !source_mdx.is_file() {
        bail!("copied MDX source is missing: {}", source_mdx.display())
    }

    if let Some(p) = progress.as_deref_mut() {
        p("正在读取 MDX/MDD 块索引…", 0.45);
    }
    let mdx_reader = NativeDictionaryFile::open_with_options(&source_mdx, false, options)?;
    let header = mdx_reader.header.clone();
    let encryption_key = mdx_reader.encryption_key;
    let mut mdd_readers = Vec::new();
    for mdd in &copied_mdd_paths {
        let reader = NativeDictionaryFile::open(&mdd, true, encryption_key)?;
        mdd_readers.push(reader);
    }
    let mut container_paths = HashSet::new();
    container_paths.insert(selected_mdx.clone());
    for path in &selected_mdds {
        container_paths.insert(fs::canonicalize(&path).unwrap_or_else(|_| path.to_path_buf()));
    }
    let key_path = options.mdx.with_extension("key");
    container_paths.insert(fs::canonicalize(&key_path).unwrap_or(key_path));
    let copied_assets = source_files
        .iter()
        .filter(|path| {
            !container_paths.contains(&fs::canonicalize(path).unwrap_or_else(|_| (*path).clone()))
        })
        .count() as u64;
    let resource_count = copied_assets.saturating_add(
        mdd_readers
            .iter()
            .map(|reader| reader.entry_count)
            .sum::<u64>(),
    );
    let manifest = DictionaryManifest {
        version: PACKAGE_VERSION,
        id: id.clone(),
        title: header.title.clone(),
        source_file: source_mdx
            .strip_prefix(&source_dir)
            .unwrap_or(&source_mdx)
            .to_string_lossy()
            .replace('\\', "/"),
        encoding: header.encoding.clone(),
        format: header.format.clone(),
        key_case_sensitive: header.key_case_sensitive,
        entry_count: mdx_reader.entry_count,
        resource_count,
        imported_at: now_seconds(),
        mdd_files: copied_mdd_paths
            .iter()
            .filter_map(|path| {
                path.strip_prefix(&source_dir)
                    .ok()
                    .and_then(|relative| safe_relative_path(&relative.to_string_lossy()))
                    .map(|relative| relative.to_string_lossy().replace('\\', "/"))
            })
            .collect(),
        encryption_key: encryption_key
            .map(|key| key.iter().map(|byte| format!("{byte:02x}")).collect()),
    };
    drop(mdd_readers);
    drop(mdx_reader);
    if let Some(p) = progress.as_deref_mut() {
        p("正在保存词典元数据…", 0.90);
    }
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

fn collect_source_files(
    root: &Path,
    directory: &Path,
    excluded_root: &Path,
    files: &mut Vec<PathBuf>,
) -> Result<()> {
    for entry in fs::read_dir(directory)
        .with_context(|| format!("read dictionary source directory {}", directory.display()))?
    {
        let entry =
            entry.with_context(|| format!("read source entry in {}", directory.display()))?;
        let path = entry.path();
        if path == excluded_root || path.starts_with(excluded_root) {
            continue;
        }
        let file_type = entry
            .file_type()
            .with_context(|| format!("inspect dictionary source entry {}", path.display()))?;
        if file_type.is_dir() {
            collect_source_files(root, &path, excluded_root, files)?;
        } else if file_type.is_file() {
            files.push(path);
        } else if file_type.is_symlink() {
            let target = fs::canonicalize(&path)
                .with_context(|| format!("resolve dictionary source symlink {}", path.display()))?;
            if !target.starts_with(root) {
                bail!(
                    "dictionary source symlink escapes its directory: {}",
                    path.display()
                )
            }
            let metadata = fs::metadata(&path)
                .with_context(|| format!("inspect dictionary source symlink {}", path.display()))?;
            if metadata.is_dir() {
                bail!(
                    "dictionary source symlink directory is not supported: {}",
                    path.display()
                )
            }
            if metadata.is_file() {
                files.push(path);
            } else {
                bail!("unsupported dictionary source symlink: {}", path.display())
            }
        } else {
            bail!("unsupported dictionary source entry: {}", path.display())
        }
    }
    Ok(())
}

fn decode_resource_text(bytes: &[u8]) -> String {
    if bytes.starts_with(&[0xff, 0xfe]) || (bytes.len() >= 2 && bytes[1] == 0) {
        decode_text(bytes, "UTF-16LE")
    } else {
        decode_text(bytes, "UTF-8")
    }
}

fn find_source_file(base: &Path, key: &str) -> Option<PathBuf> {
    let relative = safe_relative_path(key)?;
    let mut current = base.to_path_buf();
    for component in relative.components() {
        let wanted = component.as_os_str();
        let exact = current.join(wanted);
        if exact.exists() {
            current = exact;
            continue;
        }
        let entries = fs::read_dir(&current).ok()?;
        let found = entries.flatten().find_map(|entry| {
            entry
                .file_name()
                .to_str()
                .filter(|name| name.eq_ignore_ascii_case(&wanted.to_string_lossy()))
                .map(|_| entry.path())
        })?;
        current = found;
    }
    current.is_file().then_some(current)
}

fn find_same_stem_asset(source_dir: &Path, stem: &str, extension: &str) -> Option<PathBuf> {
    let entries = fs::read_dir(source_dir).ok()?;
    entries.flatten().find_map(|entry| {
        let path = entry.path();
        let file_stem = path.file_stem()?.to_str()?;
        let file_extension = path.extension()?.to_str()?;
        (path.is_file()
            && file_stem.eq_ignore_ascii_case(stem)
            && file_extension.eq_ignore_ascii_case(extension))
        .then_some(path)
    })
}

const RESOURCE_SCHEME: &str = "studymate-resource";

fn resource_root(dictionary_id: &str) -> String {
    format!("{RESOURCE_SCHEME}://{dictionary_id}/")
}

fn encode_base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let first = chunk[0] as usize;
        let second = chunk.get(1).copied().unwrap_or(0) as usize;
        let third = chunk.get(2).copied().unwrap_or(0) as usize;
        output.push(TABLE[first >> 2] as char);
        output.push(TABLE[((first & 3) << 4) | (second >> 4)] as char);
        output.push(if chunk.len() > 1 {
            TABLE[((second & 15) << 2) | (third >> 6)] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            TABLE[third & 63] as char
        } else {
            '='
        });
    }
    output
}

fn mime_type_for_key(key: &str) -> &'static str {
    match Path::new(key)
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "css" => "text/css",
        "js" | "mjs" => "text/javascript",
        "html" | "htm" => "text/html",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "m4a" => "audio/mp4",
        "ogg" => "audio/ogg",
        "flac" => "audio/flac",
        _ => "application/octet-stream",
    }
}

struct SmallBlockCache {
    entries: VecDeque<(u64, Vec<u8>)>,
    bytes: usize,
    max_entries: usize,
    max_bytes: usize,
}

impl SmallBlockCache {
    fn new(max_entries: usize, max_bytes: usize) -> Self {
        Self {
            entries: VecDeque::new(),
            bytes: 0,
            max_entries,
            max_bytes,
        }
    }

    fn get(&mut self, key: u64) -> Option<Vec<u8>> {
        let position = self
            .entries
            .iter()
            .position(|(entry_key, _)| *entry_key == key)?;
        let (entry_key, value) = self.entries.remove(position)?;
        let copy = value.clone();
        self.entries.push_back((entry_key, value));
        Some(copy)
    }

    fn insert(&mut self, key: u64, value: Vec<u8>) {
        if value.len() > self.max_bytes {
            return;
        }
        if let Some(position) = self
            .entries
            .iter()
            .position(|(entry_key, _)| *entry_key == key)
        {
            if let Some((_, old)) = self.entries.remove(position) {
                self.bytes = self.bytes.saturating_sub(old.len());
            }
        }
        self.bytes = self.bytes.saturating_add(value.len());
        self.entries.push_back((key, value));
        while self.entries.len() > self.max_entries || self.bytes > self.max_bytes {
            if let Some((_, old)) = self.entries.pop_front() {
                self.bytes = self.bytes.saturating_sub(old.len());
            } else {
                break;
            }
        }
    }
}

struct NativeDictionaryFile {
    path: PathBuf,
    header: Header,
    encryption_key: Option<[u8; 16]>,
    entry_count: u64,
    key_blocks: Vec<KeyBlockIndex>,
    record_blocks: Vec<RecordBlockIndex>,
    record_bytes: u64,
    file: File,
    key_cache: SmallBlockCache,
    record_cache: SmallBlockCache,
}

impl NativeDictionaryFile {
    fn open(path: &Path, is_mdd: bool, encryption_key: Option<[u8; 16]>) -> Result<Self> {
        let mut file = File::open(path).with_context(|| format!("open {}", path.display()))?;
        let (header, _) = read_header(&mut file)?;
        if header.is_mdd != is_mdd {
            bail!("file type does not match its extension: {}", path.display())
        }
        let (key_blocks, entry_count) =
            read_key_section_index(&mut file, &header, encryption_key.as_ref())?;
        let key_end = key_blocks
            .last()
            .map(|block| block.compressed_offset + block.compressed_size)
            .unwrap_or_else(|| file.stream_position().unwrap_or_default());
        file.seek(SeekFrom::Start(key_end))?;
        let (record_blocks, record_bytes, _) = read_record_section_index(&mut file, &header)?;
        if record_bytes == 0 && entry_count > 0 {
            bail!("MDX has keys but no record bytes")
        }
        Ok(Self {
            path: path.to_path_buf(),
            header,
            encryption_key,
            entry_count,
            key_blocks,
            record_blocks,
            record_bytes,
            file,
            key_cache: SmallBlockCache::new(2, 4 * 1024 * 1024),
            record_cache: SmallBlockCache::new(2, 8 * 1024 * 1024),
        })
    }

    fn open_with_options(path: &Path, is_mdd: bool, options: &ImportOptions) -> Result<Self> {
        let mut file = File::open(path).with_context(|| format!("open {}", path.display()))?;
        let (header, _) = read_header(&mut file)?;
        let key = derive_encryption_key(path, &header, options)?;
        drop(file);
        Self::open(path, is_mdd, key)
    }

    fn read_compressed(&mut self, offset: u64, size: u64) -> Result<Vec<u8>> {
        let size = usize::try_from(size)
            .map_err(|_| anyhow!("MDX block is too large for this platform"))?;
        self.file.seek(SeekFrom::Start(offset))?;
        let mut data = vec![0u8; size];
        self.file
            .read_exact(&mut data)
            .with_context(|| format!("read MDX block in {}", self.path.display()))?;
        Ok(data)
    }

    fn key_block(&mut self, index: usize) -> Result<Vec<RawKey>> {
        let block = self
            .key_blocks
            .get(index)
            .ok_or_else(|| anyhow!("MDX key block index out of range"))?
            .clone();
        let cache_key = block.compressed_offset;
        let bytes = if let Some(bytes) = self.key_cache.get(cache_key) {
            bytes
        } else {
            let compressed =
                self.read_compressed(block.compressed_offset, block.compressed_size)?;
            let bytes = decompress_block(
                &compressed,
                block.decompressed_size,
                self.encryption_key.as_ref(),
            )?;
            self.key_cache.insert(cache_key, bytes.clone());
            bytes
        };
        parse_key_block(&bytes, &self.header)
    }

    fn record_block(&mut self, index: usize) -> Result<Vec<u8>> {
        let block = self
            .record_blocks
            .get(index)
            .ok_or_else(|| anyhow!("MDX record block index out of range"))?
            .clone();
        let cache_key = block.compressed_offset;
        if let Some(bytes) = self.record_cache.get(cache_key) {
            return Ok(bytes);
        }
        let compressed = self.read_compressed(block.compressed_offset, block.compressed_size)?;
        let bytes = decompress_block(
            &compressed,
            block.decompressed_size,
            self.encryption_key.as_ref(),
        )?;
        self.record_cache.insert(cache_key, bytes.clone());
        Ok(bytes)
    }

    fn record_for_key(
        &mut self,
        block_index: usize,
        key_index: usize,
        keys: &[RawKey],
    ) -> Result<Vec<u8>> {
        let raw = keys
            .get(key_index)
            .ok_or_else(|| anyhow!("MDX key index out of range"))?;
        let end = if let Some(next) = keys.get(key_index + 1) {
            next.offset
        } else {
            let mut next = None;
            for index in block_index + 1..self.key_blocks.len() {
                let following = self.key_block(index)?;
                if let Some(first) = following.first() {
                    next = Some(first.offset);
                    break;
                }
            }
            next.unwrap_or(self.record_bytes)
        };
        self.record_range(raw.offset, end)
    }

    fn record_range(&mut self, start: u64, end: u64) -> Result<Vec<u8>> {
        if end < start || end > self.record_bytes {
            bail!(
                "invalid MDX record offset {}..{} of {}",
                start,
                end,
                self.record_bytes
            )
        }
        let size = usize::try_from(end - start)
            .map_err(|_| anyhow!("MDX record is too large for this platform"))?;
        let mut output = Vec::with_capacity(size);
        for index in 0..self.record_blocks.len() {
            let block = self.record_blocks[index].clone();
            let block_end = block.uncompressed_offset + block.decompressed_size as u64;
            if start >= block_end || end <= block.uncompressed_offset {
                continue;
            }
            let bytes = self.record_block(index)?;
            let from = start.max(block.uncompressed_offset) - block.uncompressed_offset;
            let to = end.min(block_end) - block.uncompressed_offset;
            output.extend_from_slice(
                &bytes[usize::try_from(from).unwrap()..usize::try_from(to).unwrap()],
            );
        }
        if output.len() != size {
            bail!("MDX record range is not fully covered by record blocks")
        }
        Ok(output)
    }

    fn candidate_key_blocks(&self, query: &str, exact: bool) -> Vec<usize> {
        let normalized = |value: &str| normalize_search_key(value, self.header.key_case_sensitive);
        let sort_key = |value: &str| mdict_sort_key(value, self.header.key_case_sensitive);
        let query_sort_key = sort_key(query);
        // The block index is normally sorted by the same key order as the
        // key blocks. A few dictionary builders emit incomplete or
        // punctuation-sensitive first/last metadata, however. Do not turn a
        // malformed range into a false negative: fall back to the block
        // sequence and still decode one block at a time.
        let metadata_is_ordered = self.key_blocks.iter().all(|block| {
            let first = sort_key(&block.first_key);
            let last = sort_key(&block.last_key);
            !first.2.is_empty() && !last.2.is_empty() && first <= last
        }) && self.key_blocks.windows(2).all(|blocks| {
            sort_key(&blocks[0].first_key) <= sort_key(&blocks[1].first_key)
                && sort_key(&blocks[0].last_key) <= sort_key(&blocks[1].last_key)
        });
        if !metadata_is_ordered {
            return (0..self.key_blocks.len()).collect();
        }
        let first = self
            .key_blocks
            .partition_point(|block| sort_key(&block.last_key) < query_sort_key);
        let mut result = Vec::new();
        for index in first..self.key_blocks.len() {
            let block = &self.key_blocks[index];
            let block_first = sort_key(&block.first_key);
            let block_last = sort_key(&block.last_key);
            if exact {
                if block_first > query_sort_key {
                    break;
                }
                if block_first <= query_sort_key && query_sort_key <= block_last {
                    result.push(index);
                }
            } else {
                if block_first > query_sort_key
                    && !normalized(&block.first_key).starts_with(&normalized(query))
                {
                    break;
                }
                if block_last >= query_sort_key {
                    result.push(index);
                }
            }
        }
        result
    }

    fn matching_keys(
        &mut self,
        query: &str,
        exact: bool,
        max: usize,
    ) -> Result<Vec<(usize, usize, RawKey)>> {
        let normalized = normalize_search_key(query, self.header.key_case_sensitive);
        let mut result = Vec::new();
        let mut original_case_match = None;
        let mut seen = HashSet::new();
        for block_index in self.candidate_key_blocks(&normalized, exact) {
            let keys = self.key_block(block_index)?;
            for (key_index, raw) in keys.into_iter().enumerate() {
                let key = normalize_search_key(&raw.key, self.header.key_case_sensitive);
                if (exact && key != normalized) || (!exact && !key.starts_with(&normalized)) {
                    continue;
                }
                if !seen.insert(raw.key.clone()) {
                    continue;
                }
                if exact && raw.key == query {
                    if max == 1 {
                        return Ok(vec![(block_index, key_index, raw)]);
                    }
                    original_case_match = Some((block_index, key_index, raw));
                } else {
                    result.push((block_index, key_index, raw));
                    if exact {
                        result.sort_by(|left, right| left.2.key.cmp(&right.2.key));
                        if result.len() > max {
                            result.pop();
                        }
                    }
                }
                if !exact && result.len() >= max {
                    return Ok(result);
                }
            }
        }
        if exact {
            result.sort_by(|left, right| left.2.key.cmp(&right.2.key));
            if let Some(preferred) = original_case_match {
                result.insert(0, preferred);
            }
            result.truncate(max);
            return Ok(result);
        }
        Ok(result)
    }

    fn exact_records(
        &mut self,
        query: &str,
        max: usize,
    ) -> Result<Vec<(usize, usize, RawKey, String)>> {
        let matches = self.matching_keys(query, true, max)?;
        let mut result = Vec::with_capacity(matches.len());
        for (block, position, raw) in matches {
            let keys = self.key_block(block)?;
            let text =
                decode_record_text(&self.record_for_key(block, position, &keys)?, &self.header);
            result.push((block, position, raw, text));
        }
        // MDict lookup is normally case-insensitive, but a package may carry
        // distinct records such as `Relate` and `relate`. Preserve the caller's
        // original spelling when choosing one record for a detail request;
        // alphabetical ordering would otherwise select the wrong definition.
        result.sort_by(|left, right| {
            (left.2.key != query)
                .cmp(&(right.2.key != query))
                .then_with(|| left.2.key.cmp(&right.2.key))
        });
        Ok(result)
    }

    fn lookup_records(&mut self, query: &str, limit: usize) -> Result<Vec<(RawKey, String)>> {
        let normalized = normalize_search_key(query, self.header.key_case_sensitive);
        if normalized.is_empty() {
            return Ok(Vec::new());
        }
        let exact = self.exact_records(query, limit)?;
        let mut result = Vec::with_capacity(limit);
        for (block, position, raw, text) in exact {
            result.push((raw, self.resolve_link(&text, &mut HashSet::new())?));
            if result.len() >= limit {
                return Ok(result);
            }
            let _ = (block, position);
        }
        if result.len() < limit {
            let matches = self.matching_keys(&normalized, false, 8192)?;
            let mut prefix = Vec::new();
            for (block, position, raw) in matches {
                if normalize_search_key(&raw.key, self.header.key_case_sensitive) == normalized {
                    continue;
                }
                let keys = self.key_block(block)?;
                let text =
                    decode_record_text(&self.record_for_key(block, position, &keys)?, &self.header);
                prefix.push((raw, self.resolve_link(&text, &mut HashSet::new())?));
            }
            prefix.sort_by(|left, right| {
                normalize_search_key(&left.0.key, self.header.key_case_sensitive)
                    .len()
                    .cmp(&normalize_search_key(&right.0.key, self.header.key_case_sensitive).len())
                    .then_with(|| left.0.key.cmp(&right.0.key))
            });
            result.extend(prefix.into_iter().take(limit - result.len()));
        }
        Ok(result)
    }

    fn resolve_link(&mut self, record: &str, visited: &mut HashSet<String>) -> Result<String> {
        let original = record.to_owned();
        let mut current = original.clone();
        for _ in 0..MAX_MDX_LINK_DEPTH {
            let Some(target) = mdict_link_target(&current) else {
                return Ok(current);
            };
            let normalized = normalize_search_key(&target, self.header.key_case_sensitive);
            if normalized.is_empty() || !visited.insert(normalized.clone()) {
                return Ok(original);
            }
            let linked = self.exact_records(&normalized, 64)?;
            let concrete = linked
                .iter()
                .find(|(_, _, _, text)| mdict_link_target(text).is_none())
                .cloned();
            let fallback = linked.into_iter().next();
            let Some((_, _, _, text)) = concrete.or(fallback) else {
                return Ok(original);
            };
            current = text;
        }
        Ok(original)
    }

    fn exact_resource(&mut self, query: &str) -> Result<Option<(String, Vec<u8>)>> {
        let normalized = normalize_resource_key(query);
        if normalized.is_empty() {
            return Ok(None);
        }
        // MDD keys use UTF-16 and frequently mix leading separators and
        // backslashes. The block index is still used to narrow the read, but
        // comparison must use the resource-specific normalizer rather than
        // the MDX word normalizer.
        let first = self
            .key_blocks
            .partition_point(|block| normalize_resource_key(&block.last_key) < normalized);
        for block in first..self.key_blocks.len() {
            let first_key = normalize_resource_key(&self.key_blocks[block].first_key);
            let last_key = normalize_resource_key(&self.key_blocks[block].last_key);
            if first_key > normalized {
                break;
            }
            if normalized > last_key {
                continue;
            }
            let keys = self.key_block(block)?;
            for (position, raw) in keys.iter().enumerate() {
                if normalize_resource_key(&raw.key) == normalized {
                    return Ok(Some((
                        raw.key.clone(),
                        self.record_for_key(block, position, &keys)?,
                    )));
                }
            }
        }
        // Keep a correctness fallback for MDD writers that do not sort the
        // first/last words in key-block metadata. It still reads one key
        // block at a time and never constructs a complete resource table.
        for block_index in 0..self.key_blocks.len() {
            let keys = self.key_block(block_index)?;
            for (position, raw) in keys.iter().enumerate() {
                if normalize_resource_key(&raw.key) == normalized {
                    return Ok(Some((
                        raw.key.clone(),
                        self.record_for_key(block_index, position, &keys)?,
                    )));
                }
            }
        }
        Ok(None)
    }

    /// Find a resource by its filename while keeping the same bounded-memory
    /// behavior as normal lookups. This is needed for pronunciation assets:
    /// many MDX records refer to `cat.mp3`, while the MDD stores it under a
    /// vendor-specific directory such as `audio/en/cat.mp3`.
    fn resource_by_basename(&mut self, query: &str) -> Result<Option<(String, Vec<u8>)>> {
        let normalized = normalize_resource_key(query);
        let basename = Path::new(&normalized)
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or(&normalized)
            .to_owned();
        self.resource_by_basenames(&[basename])
    }

    fn resource_by_basenames(&mut self, basenames: &[String]) -> Result<Option<(String, Vec<u8>)>> {
        let wanted = basenames
            .iter()
            .map(|value| normalize_resource_key(value))
            .filter_map(|value| {
                let basename = Path::new(&value)
                    .file_name()
                    .and_then(|part| part.to_str())
                    .unwrap_or(&value)
                    .to_owned();
                (!basename.is_empty()).then_some(basename)
            })
            .enumerate()
            .map(|(rank, basename)| (basename, rank))
            .collect::<HashMap<_, _>>();
        if wanted.is_empty() {
            return Ok(None);
        }
        let mut best: Option<(usize, String, Vec<u8>)> = None;
        for block_index in 0..self.key_blocks.len() {
            let keys = self.key_block(block_index)?;
            for (position, raw) in keys.iter().enumerate() {
                let candidate = normalize_resource_key(&raw.key);
                let candidate_basename = Path::new(&candidate)
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or(&candidate);
                let Some(&rank) = wanted.get(candidate_basename) else {
                    continue;
                };
                if best
                    .as_ref()
                    .map(|current| rank >= current.0)
                    .unwrap_or(false)
                {
                    continue;
                }
                let bytes = self.record_for_key(block_index, position, &keys)?;
                best = Some((rank, raw.key.clone(), bytes));
            }
        }
        Ok(best.map(|(_, key, bytes)| (key, bytes)))
    }
}

struct NativeDictionary {
    manifest: DictionaryManifest,
    source_dir: PathBuf,
    mdx: NativeDictionaryFile,
    mdds: Vec<NativeDictionaryFile>,
    css: Option<String>,
    last_used: u64,
}

impl NativeDictionary {
    fn open(package: PathBuf, manifest: DictionaryManifest) -> Result<Self> {
        let source_root = package.join("source");
        let mdx_path = source_root.join(&manifest.source_file);
        if !mdx_path.is_file() {
            bail!("dictionary MDX source is missing: {}", mdx_path.display())
        }
        let encryption_key = manifest
            .encryption_key
            .as_deref()
            .and_then(parse_hex_key)
            .and_then(|bytes| {
                (bytes.len() == 16).then(|| {
                    let mut key = [0u8; 16];
                    key.copy_from_slice(&bytes);
                    key
                })
            });
        let mdx = NativeDictionaryFile::open(&mdx_path, false, encryption_key)?;
        let explicit_mdds = manifest
            .mdd_files
            .iter()
            .filter_map(|value| safe_relative_path(value))
            .map(|relative| source_root.join(relative))
            .collect::<Vec<_>>();
        let mdds = discover_mdd_paths(&mdx_path, &explicit_mdds)
            .into_iter()
            .map(|path| NativeDictionaryFile::open(&path, true, encryption_key))
            .collect::<Result<Vec<_>>>()?;
        let mut dictionary = Self {
            manifest,
            source_dir: mdx_path.parent().unwrap_or(&source_root).to_path_buf(),
            mdx,
            mdds,
            css: None,
            last_used: 0,
        };
        dictionary.css = dictionary.load_css();
        Ok(dictionary)
    }

    fn load_css(&mut self) -> Option<String> {
        let stem = self
            .mdx
            .path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if let Some(path) = find_same_stem_asset(&self.source_dir, stem, "css") {
            if let Ok(bytes) = fs::read(path) {
                return Some(decode_resource_text(&bytes));
            }
        }
        for mdd in &mut self.mdds {
            if let Ok(Some((_, bytes))) = mdd.exact_resource(&format!("{stem}.css")) {
                return Some(decode_resource_text(&bytes));
            }
        }
        None
    }

    fn preferred_external(&self, key: &str) -> Option<PathBuf> {
        let normalized = normalize_resource_key(key);
        let extension = Path::new(&normalized)
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if !matches!(extension.to_ascii_lowercase().as_str(), "css" | "js") {
            return None;
        }
        let stem = self
            .mdx
            .path
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        let file_name = Path::new(&normalized)
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        let expected = format!("{stem}.{extension}");
        if !file_name.eq_ignore_ascii_case(&expected) || normalized.contains('/') {
            return None;
        }
        find_same_stem_asset(&self.source_dir, stem, extension)
    }

    fn resource_bytes(&mut self, key: &str) -> Result<Option<(String, Vec<u8>, Option<PathBuf>)>> {
        let normalized = normalize_resource_key(key);
        if normalized.is_empty() {
            return Ok(None);
        }
        if let Some(path) = self.preferred_external(&normalized) {
            let bytes = fs::read(&path)
                .with_context(|| format!("read dictionary resource {}", path.display()))?;
            return Ok(Some((normalized, bytes, Some(path))));
        }
        for mdd in &mut self.mdds {
            if let Some((stored, bytes)) = mdd.exact_resource(&normalized)? {
                return Ok(Some((stored, bytes, None)));
            }
        }
        if let Some(path) = find_source_file(&self.source_dir, &normalized) {
            let bytes = fs::read(&path)
                .with_context(|| format!("read dictionary resource {}", path.display()))?;
            return Ok(Some((normalized, bytes, Some(path))));
        }
        Ok(None)
    }

    fn lookup_keys(&mut self, query: &str, limit: usize) -> Result<Vec<LookupKey>> {
        let limit = limit.clamp(1, 100);
        let normalized = normalize_search_key(query, self.manifest.key_case_sensitive);
        if normalized.is_empty() {
            return Ok(Vec::new());
        }
        let mut matches = self.mdx.matching_keys(&normalized, true, limit)?;
        if matches.len() < limit {
            matches.extend(self.mdx.matching_keys(&normalized, false, 8192)?);
        }
        let mut exact = Vec::new();
        let mut prefix = Vec::new();
        let mut seen = HashSet::new();
        for (block, position, raw) in matches {
            let key = normalize_search_key(&raw.key, self.manifest.key_case_sensitive);
            if !seen.insert(raw.key.clone()) {
                continue;
            }
            let item = (block, position, raw);
            if key == normalized {
                exact.push(item);
            } else if key.starts_with(&normalized) {
                prefix.push(item);
            }
        }
        exact.sort_by(|left, right| left.2.key.cmp(&right.2.key));
        prefix.sort_by(|left, right| {
            normalize_search_key(&left.2.key, self.manifest.key_case_sensitive)
                .len()
                .cmp(&normalize_search_key(&right.2.key, self.manifest.key_case_sensitive).len())
                .then_with(|| left.2.key.cmp(&right.2.key))
        });
        exact.extend(prefix);
        Ok(exact
            .into_iter()
            .take(limit)
            .map(|(_, _, raw)| LookupKey {
                key: raw.key,
                dictionary_id: self.manifest.id.clone(),
                dictionary_title: self.manifest.title.clone(),
                resource_root: Some(resource_root(&self.manifest.id)),
            })
            .collect())
    }

    fn lookup(&mut self, query: &str, limit: usize) -> Result<Vec<LookupEntry>> {
        let limit = limit.clamp(1, 100);
        let records = self.mdx.lookup_records(query, limit)?;
        let css = self.css.clone();
        let id = self.manifest.id.clone();
        Ok(records
            .into_iter()
            .map(|(raw, text)| LookupEntry {
                key: raw.key,
                text,
                dictionary_id: id.clone(),
                dictionary_title: self.manifest.title.clone(),
                format: self.manifest.format.clone(),
                css: css.clone(),
                resource_root: Some(resource_root(&id)),
            })
            .collect())
    }

    fn resource_data(&mut self, key: &str) -> Result<Option<ResourceDataResult>> {
        let Some((stored, bytes, _)) = self.resource_bytes(key)? else {
            return Ok(None);
        };
        let size = bytes.len() as u64;
        Ok(Some(ResourceDataResult {
            key: stored.clone(),
            data_base64: encode_base64(&bytes),
            mime_type: mime_type_for_key(&stored).to_owned(),
            size,
        }))
    }

    fn find_audio(&mut self, word: &str) -> Result<Option<ResourceDataResult>> {
        // Do not use `exact_records` here. Some valid MDX files (including
        // OALD9) have block boundary metadata that makes the strict block
        // range miss an otherwise valid key. `lookup_records` keeps exact
        // matches first, then applies the reader's prefix fallback, so audio
        // lookup follows the same resilient path as the visible definition.
        let records = self.mdx.lookup_records(word, 64)?;
        let mut explicit_keys = Vec::new();
        for (_, record) in records {
            for key in explicit_sound_resource_keys(&record) {
                if !explicit_keys.contains(&key) {
                    explicit_keys.push(key);
                }
            }
        }
        let mut ranked_explicit_keys = explicit_keys.clone();
        ranked_explicit_keys.sort_by_key(|key| audio_key_score(key, word));
        for key in ranked_explicit_keys {
            if let Some(resource) = self.resource_data(&key)? {
                if resource.size > 0 {
                    return Ok(Some(resource));
                }
            }
            // Preserve compatibility with dictionaries whose HTML uses a
            // full URL/path but whose MDD key uses another directory.
            for mdd in &mut self.mdds {
                if let Some((stored, bytes)) = mdd.resource_by_basename(&key)? {
                    if !bytes.is_empty() {
                        let size = bytes.len() as u64;
                        return Ok(Some(ResourceDataResult {
                            key: stored.clone(),
                            data_base64: encode_base64(&bytes),
                            mime_type: mime_type_for_key(&stored).to_owned(),
                            size,
                        }));
                    }
                }
            }
        }
        let mut basename_candidates = explicit_keys
            .iter()
            .filter_map(|key| {
                Path::new(key)
                    .file_name()
                    .and_then(|value| value.to_str())
                    .map(str::to_owned)
            })
            .collect::<Vec<_>>();
        for variant in audio_word_variants(word) {
            for extension in AUDIO_EXTENSIONS {
                basename_candidates.push(format!("{variant}{extension}"));
            }
        }
        for mdd in &mut self.mdds {
            if let Some((stored, bytes)) = mdd.resource_by_basenames(&basename_candidates)? {
                if !bytes.is_empty() {
                    let size = bytes.len() as u64;
                    return Ok(Some(ResourceDataResult {
                        key: stored.clone(),
                        data_base64: encode_base64(&bytes),
                        mime_type: mime_type_for_key(&stored).to_owned(),
                        size,
                    }));
                }
            }
        }
        // MDD volumes have priority. If none contains an audio resource, a
        // copied sibling audio file is still a valid dictionary asset.
        for candidate in basename_candidates {
            if let Some(path) = find_source_file(&self.source_dir, &candidate) {
                let bytes = fs::read(&path)
                    .with_context(|| format!("read dictionary audio {}", path.display()))?;
                if !bytes.is_empty() {
                    let size = bytes.len() as u64;
                    return Ok(Some(ResourceDataResult {
                        key: candidate,
                        data_base64: encode_base64(&bytes),
                        mime_type: mime_type_for_key(&path.to_string_lossy()).to_owned(),
                        size,
                    }));
                }
            }
        }
        Ok(None)
    }
}

const MAX_MDX_LINK_DEPTH: usize = 32;

/// MDict uses a record containing `@@@LINK=<keyword>` as an alias entry. The
/// directive is metadata, not user-facing dictionary markup, so resolve it
/// before handing the record to WebKit. A few dictionaries add a BOM or
/// trailing line ending; tolerate those without accepting arbitrary HTML that
/// merely happens to contain the marker.
fn mdict_link_target(record: &str) -> Option<String> {
    let trimmed = record.trim_start_matches('\u{feff}').trim();
    let prefix = "@@@LINK=";
    if trimmed.len() < prefix.len() || !trimmed[..prefix.len()].eq_ignore_ascii_case(prefix) {
        return None;
    }
    let target = trimmed[prefix.len()..].trim();
    (!target.is_empty()).then(|| target.to_owned())
}

/// Reusable query state for the long-lived JSONL helper. The process handles
/// requests serially, so a mutable cache is sufficient and keeps only open
/// file handles plus the small block indexes in memory.
pub struct DictionaryReaderCache {
    root: Option<PathBuf>,
    summaries: Option<Vec<DictionarySummary>>,
    dictionaries: HashMap<String, NativeDictionary>,
    access_counter: u64,
    max_cached_dictionaries: usize,
}

impl Default for DictionaryReaderCache {
    fn default() -> Self {
        Self {
            root: None,
            summaries: None,
            dictionaries: HashMap::new(),
            access_counter: 0,
            // Keeping a few hot dictionaries open avoids reparsing the small
            // block indexes while bounding RAM/file-descriptor use.
            max_cached_dictionaries: 4,
        }
    }
}

impl DictionaryReaderCache {
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

    fn dictionary_mut(&mut self, root: &Path, id: &str) -> Result<&mut NativeDictionary> {
        self.ensure_root(root);
        if !self.dictionaries.contains_key(id) {
            let (package, manifest) = open_manifest(root, id)?;
            let dictionary = NativeDictionary::open(package, manifest)?;
            self.access_counter = self.access_counter.wrapping_add(1);
            self.dictionaries.insert(
                id.to_owned(),
                NativeDictionary {
                    last_used: self.access_counter,
                    ..dictionary
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
        dictionary.lookup_keys(query, limit)
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
        dictionary.lookup(query, limit)
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
    let mut dictionary = NativeDictionary::open(package, manifest)?;
    dictionary.lookup(query, limit)
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
    let (package, manifest) = open_manifest(root, dictionary_id)?;
    let mut dictionary = NativeDictionary::open(package, manifest)?;
    let Some((stored, bytes, source_path)) = dictionary.resource_bytes(key)? else {
        return Ok(None);
    };
    let path = source_path
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|| format!("{}{}", resource_root(&dictionary.manifest.id), stored));
    Ok(Some(ResourceResult {
        key: stored,
        path,
        size: bytes.len() as u64,
    }))
}

pub fn resource_data(
    root: &Path,
    dictionary_id: &str,
    key: &str,
) -> Result<Option<ResourceDataResult>> {
    let (package, manifest) = open_manifest(root, dictionary_id)?;
    let mut dictionary = NativeDictionary::open(package, manifest)?;
    dictionary.resource_data(key)
}

const AUDIO_EXTENSIONS: [&str; 10] = [
    ".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac", ".aiff", ".aif", ".caf", ".opus",
];

/// Normalize the path portion of an MDD resource key. MDict files commonly
/// mix `/`, `\\`, leading separators, repeated separators, and casing between
/// an HTML sound reference and the resource table key.
fn normalize_resource_key(value: &str) -> String {
    value
        .trim()
        .replace('\\', "/")
        .split('/')
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("/")
        .to_lowercase()
}

/// Extract explicit sound URLs from one MDX record. The delimiters cover the
/// quoted HTML attributes used by LDOCE-style dictionaries as well as common
/// unquoted/script forms. The returned values intentionally omit the
/// `sound://` scheme and URL query/fragment so they can be matched to MDD
/// resource keys.
fn explicit_sound_resource_keys(record: &str) -> Vec<String> {
    let lower = record.to_ascii_lowercase();
    let mut keys = Vec::new();

    for (start, _) in lower.match_indices("sound:") {
        let scheme_end = start + "sound:".len();
        let after_scheme = &lower[scheme_end..];
        let body_start = if after_scheme.starts_with("//") {
            scheme_end + 2
        } else if after_scheme.starts_with('/') {
            scheme_end + 1
        } else {
            continue;
        };

        let body = &record[body_start..];
        let end = body
            .char_indices()
            .find(|(_, character)| {
                matches!(
                    character,
                    '"' | '\'' | '<' | '>' | ')' | ']' | '}' | ',' | ';' | '\n' | '\r' | '\t' | ' '
                )
            })
            .map(|(index, _)| index)
            .unwrap_or(body.len());
        let mut reference = &body[..end];
        if let Some(index) = reference.find(['?', '#']) {
            reference = &reference[..index];
        }

        let normalized = normalize_resource_key(reference);
        if !normalized.is_empty() && !keys.contains(&normalized) {
            keys.push(normalized);
        }
    }

    keys
}

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

/// Rank an explicit pronunciation key for the requested word. A dictionary
/// entry may contain the headword pronunciation plus inflected-form and
/// example pronunciations; taking the first `sound://` link can therefore
/// play a different word's recording. Prefer a basename equal to the query
/// (or followed by its pronunciation separator), then a basename that merely
/// contains the query, while preserving source order for ties.
fn audio_key_score(key: &str, word: &str) -> u8 {
    let basename = Path::new(key)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or(key)
        .trim_matches('_')
        .to_ascii_lowercase();
    let variants = audio_word_variants(word);
    if variants
        .iter()
        .any(|variant| basename == *variant || basename.starts_with(&format!("{variant}_")))
    {
        return 0;
    }
    if variants.iter().any(|variant| basename.contains(variant)) {
        return 1;
    }
    2
}

/// Find an audio resource for one dictionary only. Explicit `sound://` URLs
/// from the matching MDX entry take priority; the basename search remains as
/// a fallback for dictionaries that expose pronunciation files without a
/// usable sound reference in their HTML. The Swift adapter searches installed
/// packages in UI priority order.
pub fn find_audio_resource(
    root: &Path,
    dictionary_id: &str,
    word: &str,
) -> Result<Option<ResourceResult>> {
    let (package, manifest) = open_manifest(root, dictionary_id)?;
    let mut dictionary = NativeDictionary::open(package, manifest)?;
    let Some(resource) = dictionary.find_audio(word)? else {
        return Ok(None);
    };
    let key = resource.key;
    let path = dictionary
        .resource_bytes(&key)?
        .and_then(|(_, _, source)| source)
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|| format!("{}{}", resource_root(&dictionary.manifest.id), key));
    Ok(Some(ResourceResult {
        key,
        path,
        size: resource.size,
    }))
}

pub fn find_audio_data(
    root: &Path,
    dictionary_id: &str,
    word: &str,
) -> Result<Option<ResourceDataResult>> {
    let (package, manifest) = open_manifest(root, dictionary_id)?;
    let mut dictionary = NativeDictionary::open(package, manifest)?;
    dictionary.find_audio(word)
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

    fn mdx_text_fixture(entries: &[(&str, &str)]) -> Vec<u8> {
        let header = "<Dictionary GeneratedByEngineVersion=\"2.0\" RequiredEngineVersion=\"2.0\" Encrypted=\"0\" Encoding=\"UTF-8\" Format=\"Html\" Title=\"Link Fixture\"/>";
        let header_bytes: Vec<u8> = header.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut output = Vec::new();
        be_u32(header_bytes.len() as u32, &mut output);
        output.extend_from_slice(&header_bytes);
        output.extend_from_slice(&[0, 0, 0, 0]);

        let mut records = Vec::new();
        let mut keys = Vec::new();
        let mut record_offset = 0u64;
        for (key, text) in entries {
            be_u64(record_offset, &mut keys);
            keys.extend_from_slice(key.as_bytes());
            keys.push(0);
            records.extend_from_slice(text.as_bytes());
            records.push(0);
            record_offset = records.len() as u64;
        }

        let key_block = block(&keys);
        let first = entries.first().map(|(key, _)| *key).unwrap_or("");
        let last = entries.last().map(|(key, _)| *key).unwrap_or("");
        let mut key_index = Vec::new();
        be_u64(entries.len() as u64, &mut key_index);
        be_u16(first.len() as u16, &mut key_index);
        key_index.extend_from_slice(first.as_bytes());
        be_u16(last.len() as u16, &mut key_index);
        key_index.extend_from_slice(last.as_bytes());
        be_u64(key_block.len() as u64, &mut key_index);
        be_u64(keys.len() as u64, &mut key_index);
        let key_index_block = block(&key_index);

        be_u64(1, &mut output);
        be_u64(entries.len() as u64, &mut output);
        be_u64(key_index.len() as u64, &mut output);
        be_u64(key_index_block.len() as u64, &mut output);
        be_u64(key_block.len() as u64, &mut output);
        be_u32(0, &mut output);
        output.extend_from_slice(&key_index_block);
        output.extend_from_slice(&key_block);

        let record_block = block(&records);
        be_u64(1, &mut output);
        be_u64(entries.len() as u64, &mut output);
        be_u64(16, &mut output);
        be_u64(record_block.len() as u64, &mut output);
        be_u64(record_block.len() as u64, &mut output);
        be_u64(records.len() as u64, &mut output);
        output.extend_from_slice(&record_block);
        output
    }

    fn mdx_v1_fixture(header: &str, entries: &[(&str, &str)]) -> Vec<u8> {
        let header_bytes: Vec<u8> = header.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut output = Vec::new();
        be_u32(header_bytes.len() as u32, &mut output);
        output.extend_from_slice(&header_bytes);
        output.extend_from_slice(&[0, 0, 0, 0]);

        let mut records = Vec::new();
        let mut keys = Vec::new();
        for (key, text) in entries {
            be_u32(records.len() as u32, &mut keys);
            keys.extend_from_slice(key.as_bytes());
            keys.push(0);
            records.extend_from_slice(text.as_bytes());
            records.push(0);
        }
        let key_block = block(&keys);
        let first = entries.first().map(|(key, _)| *key).unwrap_or("");
        let last = entries.last().map(|(key, _)| *key).unwrap_or("");
        let mut key_index = Vec::new();
        be_u32(entries.len() as u32, &mut key_index);
        key_index.push(first.len() as u8);
        key_index.extend_from_slice(first.as_bytes());
        key_index.push(last.len() as u8);
        key_index.extend_from_slice(last.as_bytes());
        be_u32(key_block.len() as u32, &mut key_index);
        be_u32(keys.len() as u32, &mut key_index);

        be_u32(1, &mut output);
        be_u32(entries.len() as u32, &mut output);
        be_u32(key_index.len() as u32, &mut output);
        be_u32(key_block.len() as u32, &mut output);
        output.extend_from_slice(&key_index);
        output.extend_from_slice(&key_block);

        let record_block = block(&records);
        be_u32(1, &mut output);
        be_u32(entries.len() as u32, &mut output);
        be_u32(8, &mut output);
        be_u32(record_block.len() as u32, &mut output);
        be_u32(record_block.len() as u32, &mut output);
        be_u32(records.len() as u32, &mut output);
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

    #[test]
    fn parses_canonical_v2_utf16_key_index() {
        // In the standard v2 index the length is the number of UTF-16 code
        // units excluding the terminator, while the indexed word itself does
        // include that terminator.
        let mut index = Vec::new();
        be_u64(2, &mut index);
        be_u16(3, &mut index);
        index.extend("cat\0".encode_utf16().flat_map(u16::to_le_bytes));
        be_u16(3, &mut index);
        index.extend("dog\0".encode_utf16().flat_map(u16::to_le_bytes));
        be_u64(32, &mut index);
        be_u64(48, &mut index);

        let parsed = parse_key_index(&index, 1, "UTF-16").unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].0, 2);
        assert_eq!(parsed[0].1, "cat");
        assert_eq!(parsed[0].2, "dog");
        assert_eq!(parsed[0].3, 32);
        assert_eq!(parsed[0].4, 48);
    }

    #[test]
    fn uses_mdict_punctuation_aware_key_order() {
        assert!(mdict_sort_key("beast", false) < mdict_sort_key("be a steal", false));
        assert!(
            mdict_sort_key("be/work to your advantage", false)
                < mdict_sort_key("be worlds apart", false)
        );
        assert!(
            mdict_sort_key("botanical garden", false) < mdict_sort_key("botanic garden", false)
        );
    }

    #[test]
    fn detail_lookup_prefers_original_case_exact_key() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-case-detail-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("fixture.mdx");
        fs::write(
            &mdx,
            mdx_text_fixture(&[
                ("Relate", "short proper-name"),
                ("relate", "full verb definition"),
            ]),
        )
        .unwrap();
        let package_root = root.join("Dictionaries");
        import_fixture(&package_root, &mdx, "fixture");

        let lower = lookup(&package_root, "fixture", "relate", 1).unwrap();
        assert_eq!(lower[0].key, "relate");
        assert_eq!(lower[0].text, "full verb definition");

        let upper = lookup(&package_root, "fixture", "Relate", 1).unwrap();
        assert_eq!(upper[0].key, "Relate");
        assert_eq!(upper[0].text, "short proper-name");
        fs::remove_dir_all(root).unwrap();
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

    fn import_fixture(root: &Path, mdx: &Path, id: &str) -> ImportResult {
        import_dictionary(&ImportOptions {
            root: root.to_path_buf(),
            mdx: mdx.to_path_buf(),
            mdd: Vec::new(),
            id: Some(id.to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap()
    }

    #[test]
    fn copies_every_nested_sibling_file_with_unknown_extension() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-all-assets-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        let mdx = root.join("fixture.mdx");
        let nested = root.join("nested/deeper");
        fs::create_dir_all(&nested).unwrap();
        fs::write(&mdx, fixture()).unwrap();
        fs::write(root.join("README.noextension"), b"unknown root asset").unwrap();
        fs::write(nested.join("data.custom"), b"unknown nested asset").unwrap();
        let package_root = root.join("Dictionaries");
        let result = import_fixture(&package_root, &mdx, "fixture");
        let package = package_root.join("fixture.mabdict");
        assert!(package.join("source/fixture.mdx").is_file());
        assert!(!package.join("Library.sqlite3").exists());

        for (key, contents) in [
            ("README.noextension", b"unknown root asset".as_slice()),
            (
                "nested/deeper/data.custom",
                b"unknown nested asset".as_slice(),
            ),
        ] {
            let resource = resource(&package_root, "fixture", key)
                .unwrap()
                .expect("every sibling file should be indexed");
            assert_eq!(fs::read(resource.path).unwrap(), contents);
        }
        assert_eq!(result.dictionary.resource_count, 2);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn external_same_name_css_and_js_override_mdd_and_aggregate() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-external-assets-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("fixture.mdx");
        fs::write(
            &mdx,
            mdx_text_fixture(&[(
                "cat",
                "<link rel=\"stylesheet\" href=\"fixture.css\"><script src=\"fixture.js\"></script><b>cat</b>",
            )]),
        )
        .unwrap();
        // Deliberately use a different case from the MDD keys. MDict paths
        // are effectively case-insensitive in lookups even though the
        // package filesystem may not be, so this must still be one resource.
        fs::write(root.join("FIXTURE.CSS"), b"external-css").unwrap();
        fs::write(root.join("FIXTURE.JS"), b"external-js").unwrap();
        fs::write(
            root.join("fixture.mdd"),
            mdd_fixture(&[
                ("fixture.css", b"package-css"),
                ("fixture.js", b"package-js"),
            ]),
        )
        .unwrap();

        let package_root = root.join("Dictionaries");
        import_fixture(&package_root, &mdx, "fixture");
        for (key, contents) in [
            ("fixture.css", b"external-css".as_slice()),
            ("fixture.js", b"external-js".as_slice()),
        ] {
            let resource = resource(&package_root, "fixture", key)
                .unwrap()
                .expect("external resource should win over the MDD resource");
            assert_eq!(fs::read(resource.path).unwrap(), contents);
        }
        let style = lookup(&package_root, "fixture", "cat", 1).unwrap()[0]
            .css
            .clone()
            .unwrap();
        assert!(style.contains("external-css"));
        assert!(!style.contains("package-css"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn mdd_wins_over_unrelated_same_key_and_normalized_lookup_is_deterministic() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-resource-precedence-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("fixture.mdx");
        fs::write(&mdx, mdx_text_fixture(&[("cat", "<b>cat</b>")])).unwrap();
        fs::write(root.join("UNRELATED.CSS"), b"sibling-css").unwrap();
        fs::write(
            root.join("fixture.mdd"),
            mdd_fixture(&[("unrelated.css", b"mdd-css")]),
        )
        .unwrap();

        let package_root = root.join("Dictionaries");
        import_fixture(&package_root, &mdx, "fixture");
        let data = resource_data(&package_root, "fixture", "UNRELATED.CSS")
            .unwrap()
            .expect("MDD resource data should be available on demand");
        assert_eq!(data.data_base64, "bWRkLWNzcw==");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn parses_xml_entities_and_preserves_empty_stylesheet_end_lines() {
        let header = r#"<Dictionary Title="A &quot;title&quot; &amp; more" Description="&lt;i&gt;demo&lt;/i&gt;" StyleSheet="1
&lt;b&gt;
"/>"#;
        assert_eq!(
            parse_attr(header, "Title").as_deref(),
            Some("A \"title\" & more")
        );
        assert_eq!(
            parse_attr(header, "Description").as_deref(),
            Some("<i>demo</i>")
        );

        let stylesheet = parse_stylesheet(parse_attr(header, "StyleSheet")).unwrap();
        assert_eq!(
            stylesheet.get("1"),
            Some(&("<b>".to_owned(), "".to_owned()))
        );
        let stylesheet_with_separator = parse_stylesheet(Some("1\n<b>\n\n".to_owned())).unwrap();
        assert_eq!(
            stylesheet_with_separator.get("1"),
            Some(&("<b>".to_owned(), "".to_owned()))
        );
        assert!(parse_stylesheet(Some("1\n<b>".to_owned())).is_err());
    }

    #[test]
    fn mdd_css_and_js_are_used_when_no_external_override_exists() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-package-assets-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("fixture.mdx");
        fs::write(&mdx, mdx_text_fixture(&[("cat", "<b>cat</b>")])).unwrap();
        fs::write(
            root.join("fixture.mdd"),
            mdd_fixture(&[
                ("fixture.css", b"package-css"),
                ("fixture.js", b"package-js"),
            ]),
        )
        .unwrap();

        let package_root = root.join("Dictionaries");
        import_fixture(&package_root, &mdx, "fixture");
        assert_eq!(
            resource_data(&package_root, "fixture", "fixture.css")
                .unwrap()
                .unwrap()
                .data_base64,
            "cGFja2FnZS1jc3M="
        );
        assert_eq!(
            resource_data(&package_root, "fixture", "fixture.js")
                .unwrap()
                .unwrap()
                .data_base64,
            "cGFja2FnZS1qcw=="
        );
        assert!(lookup(&package_root, "fixture", "cat", 1).unwrap()[0]
            .css
            .as_ref()
            .unwrap()
            .contains("package-css"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn expands_compact_stylesheet_records_and_reads_v1_blocks() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-v1-compact-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("compact.mdx");
        let header = "<Dictionary GeneratedByEngineVersion=\"1.2\" RequiredEngineVersion=\"1.2\" Encrypted=\"0\" Encoding=\"UTF-8\" Format=\"Html\" Compact=\"Yes\" Compat=\"Yes\" StyleSheet=\"1\n<b>\n</b>\" Title=\"Compact\"/>";
        fs::write(&mdx, mdx_v1_fixture(header, &[("cat", "`1`cat")])).unwrap();
        let package_root = root.join("Dictionaries");
        import_fixture(&package_root, &mdx, "compact");
        let entries = lookup(&package_root, "compact", "cat", 20).unwrap();
        assert_eq!(entries[0].text, "<b>cat</b>");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn rejects_truncated_mdx_instead_of_importing_partial_data() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-truncated-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let source = root.join("truncated.mdx");
        let bytes = fixture();
        fs::write(&source, &bytes[..bytes.len() - 1]).unwrap();
        let error = import_dictionary(&ImportOptions {
            root: root.join("Dictionaries"),
            mdx: source,
            mdd: Vec::new(),
            id: Some("truncated".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .expect_err("truncated MDX must fail");
        assert!(format!("{error:#}").contains("MDX"));
        fs::remove_dir_all(root).unwrap();
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
        let mut cache = DictionaryReaderCache::default();
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
        let package = package_root.join("tld.mabdict");
        assert!(package.join("source/TLD.mdx").is_file());
        assert!(package.join("source/TLD.mdd").is_file());
        assert!(package.join("source/TLD.1.mdd").is_file());
        assert!(!package.join("Library.sqlite3").exists());

        let audio = find_audio_resource(&package_root, "tld", "CAT")
            .unwrap()
            .expect("MDD audio should match by filename");
        assert_eq!(audio.key, r"\audio/cat.mp3");
        assert_eq!(
            resource_data(&package_root, "tld", "audio/cat.mp3")
                .unwrap()
                .unwrap()
                .data_base64,
            "YXVkaW8tb25l"
        );
        assert!(
            resource(&package_root, "tld", "/audio/cat.mp3")
                .unwrap()
                .is_some(),
            "sound URL should resolve slash-normalized MDD key"
        );
        assert_eq!(
            resource_data(&package_root, "tld", "/audio/cat.mp3")
                .unwrap()
                .unwrap()
                .data_base64,
            "YXVkaW8tb25l"
        );
        assert!(find_audio_resource(&package_root, "tld", "missing")
            .unwrap()
            .is_none());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn keeps_explicit_external_mdd_when_conventional_volume_exists() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-external-mdd-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        let source_dir = root.join("source");
        let external_dir = root.join("external");
        fs::create_dir_all(&source_dir).unwrap();
        fs::create_dir_all(&external_dir).unwrap();
        let mdx = source_dir.join("fixture.mdx");
        let conventional = source_dir.join("fixture.mdd");
        let external = external_dir.join("voice-pack.mdd");
        fs::write(&mdx, fixture()).unwrap();
        fs::write(&conventional, mdd_fixture(&[("cat.mp3", b"base-audio")])).unwrap();
        fs::write(&external, mdd_fixture(&[("extra.mp3", b"external-audio")])).unwrap();

        let package_root = root.join("Dictionaries");
        let imported = import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx,
            mdd: vec![external],
            id: Some("fixture".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();
        assert_eq!(imported.dictionary.resource_count, 2);
        let package = package_root.join("fixture.mabdict");
        assert!(package.join("source/fixture.mdd").is_file());
        assert!(package.join("source/voice-pack.mdd").is_file());
        assert_eq!(
            resource_data(&package_root, "fixture", "extra.mp3")
                .unwrap()
                .unwrap()
                .data_base64,
            "ZXh0ZXJuYWwtYXVkaW8="
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn finds_explicit_sound_reference_before_word_basename_fallback() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-explicit-audio-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("LDOCE.mdx");
        let mdd = root.join("LDOCE.mdd");
        fs::write(
            &mdx,
            mdx_text_fixture(&[(
                "cat",
                "<a href='SOUND://MEDIA/ENGLISH/AMEPRONS/LD45CAT.MP3'>play</a>",
            )]),
        )
        .unwrap();
        fs::write(
            &mdd,
            mdd_fixture(&[
                (r"\media\english\ameProns\ld45cat.mp3", b"explicit-audio"),
                ("cat.mp3", b"basename-fallback"),
            ]),
        )
        .unwrap();

        let package_root = root.join("Dictionaries");
        import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx,
            mdd: Vec::new(),
            id: Some("ldoce".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();

        let audio = find_audio_resource(&package_root, "ldoce", "CAT")
            .unwrap()
            .expect("explicit sound URL should resolve in the same dictionary");
        assert_eq!(audio.key, r"\media\english\ameProns\ld45cat.mp3");
        assert_eq!(
            resource_data(&package_root, "ldoce", &audio.key)
                .unwrap()
                .unwrap()
                .data_base64,
            "ZXhwbGljaXQtYXVkaW8="
        );
        assert_eq!(
            find_audio_data(&package_root, "ldoce", "CAT")
                .unwrap()
                .unwrap()
                .data_base64,
            "ZXhwbGljaXQtYXVkaW8="
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn prefers_the_requested_word_audio_when_one_entry_has_multiple_sounds() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-word-audio-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let mdx = root.join("OALD.mdx");
        let mdd = root.join("OALD.mdd");
        fs::write(
            &mdx,
            mdx_text_fixture(&[(
                "meeting",
                "<a href='sound://audio/meet__gb_1.mp3'>meet</a><a href='sound://audio/meeting__gb_1.mp3'>meeting</a>",
            )]),
        )
        .unwrap();
        fs::write(
            &mdd,
            mdd_fixture(&[
                ("audio/meet__gb_1.mp3", b"headword-audio"),
                ("audio/meeting__gb_1.mp3", b"requested-word-audio"),
            ]),
        )
        .unwrap();

        let package_root = root.join("Dictionaries");
        import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx,
            mdd: Vec::new(),
            id: Some("oald".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();

        assert_eq!(
            find_audio_data(&package_root, "oald", "meeting")
                .unwrap()
                .unwrap()
                .data_base64,
            "cmVxdWVzdGVkLXdvcmQtYXVkaW8="
        );
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
    fn resolves_nested_mdict_links_and_protects_against_cycles() {
        let root = std::env::temp_dir().join(format!(
            "studymate-dict-link-test-{}-{}",
            std::process::id(),
            now_seconds()
        ));
        fs::create_dir_all(&root).unwrap();
        let source = root.join("links.mdx");
        fs::write(
            &source,
            mdx_text_fixture(&[
                ("alias", "@@@LINK=relate"),
                ("cycle-a", "@@@LINK=cycle-b"),
                ("cycle-b", "@@@LINK=cycle-a"),
                ("missing", "@@@LINK=does-not-exist"),
                ("nested", "@@@LINK=alias"),
                ("relate", "<b>the related definition</b>"),
            ]),
        )
        .unwrap();
        let package_root = root.join("Dictionaries");
        import_dictionary(&ImportOptions {
            root: package_root.clone(),
            mdx: source,
            mdd: Vec::new(),
            id: Some("links".to_owned()),
            registration_code: None,
            user_id: None,
        })
        .unwrap();

        let alias = lookup(&package_root, "links", "alias", 20).unwrap();
        assert_eq!(alias.len(), 1);
        assert_eq!(alias[0].key, "alias");
        assert_eq!(alias[0].text, "<b>the related definition</b>");

        let nested = lookup(&package_root, "links", "nested", 20).unwrap();
        assert_eq!(nested[0].text, "<b>the related definition</b>");

        let missing = lookup(&package_root, "links", "missing", 20).unwrap();
        assert_eq!(missing[0].text, "@@@LINK=does-not-exist");

        let cycle = lookup(&package_root, "links", "cycle-a", 20).unwrap();
        assert_eq!(cycle[0].text, "@@@LINK=cycle-b");

        let mut cache = DictionaryReaderCache::default();
        let cached = cache.lookup(&package_root, "links", "alias", 20).unwrap();
        assert_eq!(cached[0].text, "<b>the related definition</b>");

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
