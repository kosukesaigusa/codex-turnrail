use anyhow::Context;
use anyhow::Result;
use serde::Deserialize;
use serde::Serialize;
use std::fs::OpenOptions;
use std::io::ErrorKind;
use std::io::Write;
use std::path::Path;
use uuid::Uuid;

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LastUsed {
    schema_version: u64,
    account_id: Uuid,
    started_at_unix_seconds: i64,
}

pub(crate) fn record(root: &Path, account_id: Uuid, started_at: i64) -> Result<()> {
    anyhow::ensure!(
        (0..=253_402_300_799).contains(&started_at),
        "invalid account last-used timestamp"
    );
    let directory = root.join("accounts").join(account_id.to_string());
    // A separate lock survives atomic replacement of the metadata file. Do not
    // recreate the directory if the companion has removed this account.
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(directory.join("last-used.lock"))
        .context("cannot open account last-used lock")?;
    lock.lock()
        .context("cannot lock account last-used record")?;
    let path = directory.join("last-used.json");
    match std::fs::read(&path) {
        Ok(bytes) => {
            let previous: LastUsed =
                serde_json::from_slice(&bytes).context("invalid account last-used record")?;
            anyhow::ensure!(
                previous.schema_version == 1
                    && previous.account_id == account_id
                    && (0..=253_402_300_799).contains(&previous.started_at_unix_seconds),
                "invalid account last-used record fields"
            );
            if previous.started_at_unix_seconds >= started_at {
                return Ok(());
            }
        }
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("cannot read account last-used record"),
    }
    let record = LastUsed {
        schema_version: 1,
        account_id,
        started_at_unix_seconds: started_at,
    };
    let mut temporary = tempfile::NamedTempFile::new_in(&directory)?;
    temporary.write_all(&serde_json::to_vec(&record)?)?;
    temporary.as_file().sync_all()?;
    temporary.persist(path)?;
    Ok(())
}

#[cfg(test)]
#[path = "account_last_used_tests.rs"]
mod tests;
