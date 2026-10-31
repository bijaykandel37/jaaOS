//! `bastion-health` — self-monitoring CLI (Rust port, in progress).
//!
//! Behavioural spec: `packages/bastion-health/bin/bastion-health`. Port one subcommand at a
//! time, keeping two contracts intact:
//!   1. `status`/`check` must work even when Prometheus is down — read /proc, df, systemctl, ss
//!      directly and only ENRICH from the local Prometheus/Alertmanager when reachable.
//!   2. DENIABILITY: nothing here may reveal or count dual-password environments. There is no
//!      `environments` subcommand, by design — mirror `bastion-env status`, which reveals
//!      nothing. See docs/06-phase5-monitoring.md §Deniability.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "bastion-health",
    about = "BastionOS self-monitoring (reveals nothing about dual-password environments)"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// One-screen health summary (works even if the monitoring stack is down)
    Status,
    /// List scrape targets, including bastion-host file_sd discovery
    Targets,
    /// Exit non-zero if a threshold is crossed (for cron/CI)
    Check,
    /// Show currently firing alerts
    Alerts,
    /// Set mode (lite|full) and enable the matching units (needs root)
    Enable {
        #[arg(long, default_value = "lite")]
        mode: String,
    },
}

fn not_yet(what: &str) -> Result<()> {
    bail!("`{what}` is not yet ported to Rust; reference implementation: packages/bastion-health/bin/bastion-health");
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Status => not_yet("status"),
        Cmd::Targets => not_yet("targets"),
        Cmd::Check => not_yet("check"),
        Cmd::Alerts => not_yet("alerts"),
        Cmd::Enable { mode } => {
            if mode != "lite" && mode != "full" {
                bail!("mode must be 'lite' or 'full'");
            }
            not_yet("enable")
        }
    }
}
