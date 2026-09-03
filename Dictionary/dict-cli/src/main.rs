use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use studymate_dict_core::{
    delete_dictionary, find_audio_data, import_dictionary_with_progress, resource, resource_data,
    DictionaryReaderCache, ImportOptions,
};

fn request_id(value: &Value) -> Value {
    value.get("id").cloned().unwrap_or(Value::Null)
}

fn string_field(value: &Value, name: &str) -> Result<String> {
    value
        .get(name)
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| anyhow!("missing string field '{name}'"))
}

fn path_field(value: &Value, name: &str) -> Result<PathBuf> {
    Ok(PathBuf::from(string_field(value, name)?))
}

fn dictionary_ids_field(value: &Value) -> Option<Vec<String>> {
    value.get("dictionaryIDs").and_then(Value::as_array).map(|items| {
        items
            .iter()
            .filter_map(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(ToOwned::to_owned)
            .collect()
    })
}

fn handle(
    value: &Value,
    stdout: &mut impl Write,
    query_cache: &mut DictionaryReaderCache,
) -> Result<Value> {
    let op = string_field(value, "op")?;
    match op.as_str() {
        "list" => {
            let root = path_field(value, "root")?;
            Ok(serde_json::to_value(query_cache.list(&root)?)?)
        }
        "delete" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            let deleted = delete_dictionary(&root, &id)?;
            query_cache.invalidate();
            Ok(serde_json::to_value(deleted)?)
        }
        "lookup" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            let query = string_field(value, "query")?;
            let limit = value.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
            Ok(serde_json::to_value(
                query_cache.lookup(&root, &id, &query, limit)?,
            )?)
        }
        "lookupAll" => {
            let root = path_field(value, "root")?;
            let query = string_field(value, "query")?;
            let limit = value.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
            let result = match dictionary_ids_field(value) {
                Some(dictionary_ids) => query_cache.lookup_all_with_ids(
                    &root,
                    &query,
                    limit,
                    &dictionary_ids,
                )?,
                None => query_cache.lookup_all(&root, &query, limit)?,
            };
            Ok(serde_json::to_value(result)?)
        }
        "lookupKeys" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            let query = string_field(value, "query")?;
            let limit = value.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
            Ok(serde_json::to_value(
                query_cache.lookup_keys(&root, &id, &query, limit)?,
            )?)
        }
        "lookupAllKeys" => {
            let root = path_field(value, "root")?;
            let query = string_field(value, "query")?;
            let limit = value.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
            let result = match dictionary_ids_field(value) {
                Some(dictionary_ids) => query_cache.lookup_all_keys_with_ids(
                    &root,
                    &query,
                    limit,
                    &dictionary_ids,
                )?,
                None => query_cache.lookup_all_keys(&root, &query, limit)?,
            };
            Ok(serde_json::to_value(result)?)
        }
        "resource" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            let key = string_field(value, "key")?;
            Ok(serde_json::to_value(resource(&root, &id, &key)?)?)
        }
        "resourceData" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            let key = string_field(value, "key")?;
            Ok(serde_json::to_value(resource_data(&root, &id, &key)?)?)
        }
        "findAudio" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            let word = string_field(value, "word")?;
            Ok(serde_json::to_value(find_audio_data(&root, &id, &word)?)?)
        }
        "import" => {
            let root = path_field(value, "root")?;
            let mdx = path_field(value, "mdxPath")?;
            let mdd = value
                .get("mddPaths")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(PathBuf::from)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let id = value
                .get("dictionaryID")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            let registration_code = value
                .get("registrationCode")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            let user_id = value
                .get("userID")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            let req_id = request_id(value);
            let mut report_progress = |phase: &str, fraction: f64| {
                let _ = writeln!(
                    stdout,
                    "{}",
                    json!({"event":"progress","id":req_id,"phase":phase,"fraction":fraction})
                );
                let _ = stdout.flush();
            };
            let result = import_dictionary_with_progress(
                &ImportOptions {
                    root,
                    mdx,
                    mdd,
                    id,
                    registration_code,
                    user_id,
                },
                Some(&mut report_progress),
            )?;
            query_cache.invalidate();
            Ok(serde_json::to_value(result)?)
        }
        _ => Err(anyhow!("unsupported dictionary operation '{op}'")),
    }
}

fn write_response(stdout: &mut impl Write, id: Value, result: Result<Value>) -> Result<()> {
    let response = match result {
        Ok(result) => json!({"id": id, "ok": true, "result": result}),
        Err(error) => json!({
            "id": id,
            "ok": false,
                "error": {"code": "dictionary_error", "message": format!("{error:#}")}
        }),
    };
    writeln!(stdout, "{response}")?;
    stdout.flush()?;
    Ok(())
}

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() != Some("serve") {
        eprintln!("usage: studymate-dict serve");
        std::process::exit(2);
    }
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());
    let mut query_cache = DictionaryReaderCache::default();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            Err(error) => {
                write_response(
                    &mut stdout,
                    Value::Null,
                    Err(anyhow!("invalid JSON request: {error}")),
                )?;
                continue;
            }
        };
        let id = request_id(&request);
        let result = handle(&request, &mut stdout, &mut query_cache);
        write_response(&mut stdout, id, result)?;
    }
    Ok(())
}
