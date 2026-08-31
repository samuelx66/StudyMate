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
use std::collections::hash_map::DefaultHasher;
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

fn parse_key_index(bytes: &[u8], blocks: usize, encoding: &str) -> Result<()> {
    let mut reader = Reader::new(bytes);
    for _ in 0..blocks {
        let _entries = reader.u64()?;
        let first_units = reader.u16()? as usize;
        let unit = if encoding.to_ascii_uppercase().contains("UTF-16") {
            2
        } else {
            1
        };
        reader.take(first_units * unit)?;
        // v2 key-index word lengths exclude the terminating NUL unit.
        reader.take(unit)?;
        let last_units = reader.u16()? as usize;
        reader.take(last_units * unit)?;
        reader.take(unit)?;
        reader.take(16)?;
    }
    Ok(())
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
    parse_key_index(&key_index, block_count, &header.encoding).context("parse MDX key index")?;

    let mut index_reader = Reader::new(&key_index);
    let mut block_sizes = Vec::with_capacity(block_count);
    for _ in 0..block_count {
        let _entries = index_reader.u64()?;
        let first_units = index_reader.u16()? as usize;
        let unit = if header.encoding.to_ascii_uppercase().contains("UTF-16") {
            2
        } else {
            1
        };
        index_reader.take(first_units * unit)?;
        index_reader.take(unit)?;
        let last_units = index_reader.u16()? as usize;
        index_reader.take(last_units * unit)?;
        index_reader.take(unit)?;
        let comp = index_reader.u64()? as usize;
        let decomp = index_reader.u64()? as usize;
        block_sizes.push((comp, decomp));
    }

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
                while end + 1 < decompressed.len()
                    && decompressed[end] != 0
                    && decompressed[end + 1] != 0
                {
                    end += 2;
                }
                let bytes = key_reader.take(end.saturating_sub(start))?.to_vec();
                let _ = key_reader.take(2)?;
                bytes
            } else {
                let start = key_reader.pos;
                let tail = &decompressed[start..];
                let length = tail
                    .iter()
                    .position(|b| *b == 0)
                    .ok_or_else(|| anyhow!("unterminated MDX keyword"))?;
                let bytes = key_reader.take(length)?.to_vec();
                let _ = key_reader.take(1)?;
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
    if !options.mdx.is_file() {
        bail!("MDX file does not exist: {}", options.mdx.display())
    }
    fs::create_dir_all(&options.root)?;
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
    fs::create_dir_all(temp_package.join("source"))?;
    fs::create_dir_all(temp_package.join("resources"))?;
    let source_mdx = temp_package.join("source").join(
        options
            .mdx
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("dictionary.mdx"),
    );
    fs::copy(&options.mdx, &source_mdx)?;
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
    let (header, entry_count, mut resource_count) = import_file(
        &source_mdx,
        false,
        &records_path,
        &connection,
        &temp_package.join("resources"),
        0,
        options,
    )?;
    for mdd in &options.mdd {
        if !mdd.is_file() {
            bail!("MDD file does not exist: {}", mdd.display())
        }
        let source_mdd = temp_package.join("source").join(
            mdd.file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("resources.mdd"),
        );
        fs::copy(mdd, &source_mdd)?;
        let mdd_records = temp_package.join(format!("records-{}.tmp", resource_count));
        let (_mdd_header, _entries, resources) = import_file(
            &source_mdd,
            true,
            &mdd_records,
            &connection,
            &temp_package.join("resources"),
            resource_count,
            options,
        )?;
        resource_count += resources;
        let _ = fs::remove_file(mdd_records);
    }
    let _ = fs::remove_file(&records_path);
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
    fs::rename(&temp_package, &package).with_context(|| {
        format!(
            "publish dictionary package {} -> {}",
            temp_package.display(),
            package.display()
        )
    })?;
    Ok(ImportResult {
        dictionary: manifest_to_summary(&manifest),
        package_path: package.to_string_lossy().into_owned(),
    })
}

pub fn list_dictionaries(root: &Path) -> Result<Vec<DictionarySummary>> {
    if !root.exists() {
        return Ok(Vec::new());
    }
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

fn open_manifest(root: &Path, id: &str) -> Result<(PathBuf, DictionaryManifest)> {
    let safe = sanitize_id(id);
    let package = root.join(package_name(&safe));
    let manifest_path = package.join("manifest.json");
    let manifest: DictionaryManifest = serde_json::from_slice(
        &fs::read(&manifest_path).with_context(|| format!("read {}", manifest_path.display()))?,
    )?;
    Ok((package, manifest))
}

pub fn lookup(
    root: &Path,
    dictionary_id: &str,
    query: &str,
    limit: usize,
) -> Result<Vec<LookupEntry>> {
    let (package, manifest) = open_manifest(root, dictionary_id)?;
    let connection = Connection::open(package.join("Library.sqlite3"))?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    let exact = normalize_key(query);
    if exact.is_empty() {
        return Ok(Vec::new());
    }
    let limit = limit.clamp(1, 100);
    let mut statement = connection.prepare(
        "SELECT key, record_text FROM entries
         WHERE normalized = ?1 OR normalized LIKE ?2
         ORDER BY CASE WHEN normalized = ?1 THEN 0 ELSE 1 END,
                  length(normalized), key LIMIT ?3",
    )?;
    let rows = statement.query_map(params![exact, format!("{}%", exact), limit as i64], |row| {
        Ok(LookupEntry {
            key: row.get(0)?,
            text: row.get(1)?,
            dictionary_id: manifest.id.clone(),
            dictionary_title: manifest.title.clone(),
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
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
    let record: Option<(String, i64)> = connection
        .query_row(
            "SELECT path, size FROM resources WHERE key = ?1",
            params![key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    Ok(record.map(|(path, size)| ResourceResult {
        key: key.to_owned(),
        path: package
            .join("resources")
            .join(path)
            .to_string_lossy()
            .into_owned(),
        size: size.max(0) as u64,
    }))
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
        keys.extend_from_slice(b"dog\0");
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

    #[test]
    fn imports_and_queries_uncompressed_mdx() {
        let root = std::env::temp_dir().join(format!("studymate-dict-test-{}", now_seconds()));
        let source = root.join("fixture.mdx");
        fs::create_dir_all(&root).unwrap();
        fs::write(&source, fixture()).unwrap();
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
        let matches = lookup(&package_root, "fixture", "cat", 20).unwrap();
        assert_eq!(matches[0].text, "feline");
        assert_eq!(
            lookup(&package_root, "fixture", "do", 20).unwrap()[0].key,
            "dog"
        );
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
