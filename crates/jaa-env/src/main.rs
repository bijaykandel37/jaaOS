//! `jaa-env` — dual-password home environment manager (Rust port, in progress).
//!
//! Behavioural spec: `packages/jaa-env/bin/jaa-env`. Port verbs over one at a time,
//! preserving behaviour exactly — in particular `status` must reveal NOTHING about non-active
//! environments (no count, no list), per docs/03-phase2-dual-env.md §7.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};

const STATE_ACTIVE: &str = "/run/jaa-env/active";

#[derive(Parser)]
#[command(name = "jaa-env", about = "Manage dual-password home environments")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Create the primary (decoy) environment
    Init,
    /// Add another environment (reveals nothing about how many already exist)
    Add,
    /// Show the ACTIVE environment only — never the others
    Status,
    /// Unmount and lock the active environment
    Lock,
    /// Back up the active environment only
    Backup,
}

/// Reveals only whether an environment is active. Identical output whether or not a hidden
/// environment exists — do not add counts or a list here.
fn status() -> Result<()> {
    let active = std::path::Path::new(STATE_ACTIVE).exists();
    println!(
        "environment: {}",
        if active { "active" } else { "none active" }
    );
    Ok(())
}

fn not_yet(verb: &str) -> Result<()> {
    bail!("`{verb}` is not yet ported to Rust; reference implementation: packages/jaa-env/bin/jaa-env");
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Status => status(),
        Cmd::Init => not_yet("init"),
        Cmd::Add => not_yet("add"),
        Cmd::Lock => not_yet("lock"),
        Cmd::Backup => not_yet("backup"),
    }
}
