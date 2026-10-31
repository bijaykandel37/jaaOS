//! `bastion-scan` — authorized-testing-only VAPT orchestrator (Rust port, in progress).
//!
//! Behavioural spec: `packages/bastion-scan/bin/bastion-scan`. Port one subcommand at a time,
//! keeping the guardrails EXACTLY: refuse without an engagement file + `AUTHORIZATION_REF` +
//! scope; enforce the engagement window; every target must be in scope and not excluded (one
//! out-of-scope target aborts the whole run); exclusions and the hard-denied ranges win over
//! scope; audit every run; run tools only inside the rootless, cap-dropped container. Default
//! profiles stay non-destructive (no exploits / DoS / evasion / mass-targeting). See
//! docs/07-phase6-vapt.md.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "bastion-scan",
    about = "Authorized-testing-only VAPT orchestrator (scope-enforced, audited)"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Manage the engagement file (authorization + scope)
    Engagement {
        #[command(subcommand)]
        action: Engagement,
    },
    /// Test targets against scope WITHOUT scanning (the gate)
    Scope {
        #[command(subcommand)]
        action: Scope,
    },
    /// Run a profile against in-scope targets (containerized, audited)
    Run {
        profile: String,
        #[arg(required = true)]
        targets: Vec<String>,
    },
    /// List results + audit summary for the engagement
    Report,
}

#[derive(Subcommand)]
enum Engagement {
    /// Scaffold an engagement file
    Init { name: String },
    /// Print the active engagement file
    Show,
    /// Validate authorization + scope + window
    Validate,
}

#[derive(Subcommand)]
enum Scope {
    /// Check one or more targets against the engagement scope
    Check {
        #[arg(required = true)]
        targets: Vec<String>,
    },
}

fn not_yet(what: &str) -> Result<()> {
    bail!("`{what}` is not yet ported to Rust; reference implementation: packages/bastion-scan/bin/bastion-scan");
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Engagement { action } => match action {
            Engagement::Init { .. } => not_yet("engagement init"),
            Engagement::Show => not_yet("engagement show"),
            Engagement::Validate => not_yet("engagement validate"),
        },
        Cmd::Scope { action } => match action {
            Scope::Check { .. } => not_yet("scope check"),
        },
        Cmd::Run { .. } => not_yet("run"),
        Cmd::Report => not_yet("report"),
    }
}
