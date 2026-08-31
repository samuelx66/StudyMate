use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use studymate_dict_core::{
    delete_dictionary, import_dictionary_with_progress, list_dictionaries, lookup, lookup_all,
    resource, ImportOptions,
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

fn handle(value: &Value, stdout: &mut impl Write) -> Result<Value> {
    let op = string_field(value, "op")?;
    match op.as_str() {
        "list" => {
            let root = path_field(value, "root")?;
            Ok(serde_json::to_value(list_dictionaries(&root)?)?)
        }
        "delete" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            Ok(serde_json::to_value(delete_dictionary(&root, &id)?)?)
        }
        "lookup" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            let query = string_field(value, "query")?;
            let limit = value.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
            Ok(serde_json::to_value(lookup(&root, &id, &query, limit)?)?)
        }
        "lookupAll" => {
            let root = path_field(value, "root")?;
            let query = string_field(value, "query")?;
            let limit = value.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
            Ok(serde_json::to_value(lookup_all(&root, &query, limit)?)?)
        }
        "resource" => {
            let root = path_field(value, "root")?;
            let id = string_field(value, "dictionaryID")?;
            let key = string_field(value, "key")?;
            Ok(serde_json::to_value(resource(&root, &id, &key)?)?)
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
        let result = handle(&request, &mut stdout);
        write_response(&mut stdout, id, result)?;
    }
    Ok(())
}
