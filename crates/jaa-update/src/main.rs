//! `jaa-update` — snapshot-bracketed update/rollback (Rust port, in progress).
//!
//! Behavioural spec: `packages/jaa-update/bin/jaa-update`. Keep the contract: every
//! `apply` is bracketed by a snapper pre/post snapshot of the root subvolume, and a kernel-
//! touching upgrade warns that the signed, immutable UKI must be rebuilt+re-signed (a subvolume
//! rollback does not restore the booted kernel). See docs/08-phase7-release.md.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "jaa-update",
    about = "Snapshot-bracketed system update/rollback"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Current subvol, last apt action, snapshot count
    Status,
    /// Refresh indexes and list upgradable packages
    Check,
    /// pre-snapshot -> full-upgrade -> post-snapshot
    Apply,
    /// Roll the root subvol back to a snapshot (reboot to apply)
    Rollback { number: Option<u64> },
    /// List snapper snapshots
    List,
}

fn not_yet(what: &str) -> Result<()> {
    bail!("`{what}` is not yet ported to Rust; reference implementation: packages/jaa-update/bin/jaa-update");
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Status => not_yet("status"),
        Cmd::Check => not_yet("check"),
        Cmd::Apply => not_yet("apply"),
        Cmd::Rollback { .. } => not_yet("rollback"),
        Cmd::List => not_yet("list"),
    }
}
