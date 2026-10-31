//! Shared helpers for the jaa-* tools.
//!
//! The Rust port is in progress (docs/decisions/0002). The bash under `packages/` remains the
//! behavioural spec until each tool is ported, so keep behaviour identical when replacing it.

use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::process::Command;

pub mod scope;

/// Run a command and return its trimmed stdout, erroring on a non-zero exit.
pub fn capture(cmd: &str, args: &[&str]) -> Result<String> {
    let out = Command::new(cmd)
        .args(args)
        .output()
        .with_context(|| format!("failed to spawn {cmd}"))?;
    if !out.status.success() {
        bail!("{cmd} exited with {}", out.status);
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Parse a simple `KEY=value` config file (e.g. /etc/jaa-env/config).
/// Missing file -> empty map (so an unconfigured system is inert, not an error).
pub fn read_kv_config(path: &str) -> Result<HashMap<String, String>> {
    let mut map = HashMap::new();
    let text = std::fs::read_to_string(path).unwrap_or_default();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            map.insert(k.trim().to_string(), v.trim().to_string());
        }
    }
    Ok(map)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kv_skips_comments_and_blanks() {
        // round-trips through a temp file
        let p = std::env::temp_dir().join("jaa-core-kv-test");
        std::fs::write(&p, "# c\n\nMANAGED_USER=alice\nPROVIDER = luks2\n").unwrap();
        let m = read_kv_config(p.to_str().unwrap()).unwrap();
        assert_eq!(m.get("MANAGED_USER").map(String::as_str), Some("alice"));
        assert_eq!(m.get("PROVIDER").map(String::as_str), Some("luks2"));
        let _ = std::fs::remove_file(&p);
    }
}
