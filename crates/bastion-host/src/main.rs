//! `bastion-host` — hosting & load-balancing CLI (Rust port, in progress).
//!
//! Behavioural spec: `packages/bastion-host/bin/bastion-host`. Port one subcommand at a time,
//! keeping the pipeline identical: generate config -> validate -> reload (zero-downtime) ->
//! open the firewall port -> register a Prometheus file_sd target. Validation failure must abort
//! before any reload or port change.

use anyhow::{bail, Result};
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "bastion-host",
    about = "Create web sites and load balancers safely"
)]
struct Cli {
    #[command(subcommand)]
    group: Group,
}

#[derive(Subcommand)]
enum Group {
    /// Manage web sites (nginx / caddy)
    Site {
        #[command(subcommand)]
        action: SiteAction,
    },
    /// Manage load balancers (haproxy / traefik)
    Lb {
        #[command(subcommand)]
        action: LbAction,
    },
    /// Manage VRRP high availability (keepalived)
    Ha {
        #[command(subcommand)]
        action: HaAction,
    },
}

#[derive(Subcommand)]
enum SiteAction {
    /// Create a site
    Create {
        domain: String,
        #[arg(long)]
        php: Option<String>,
        #[arg(long)]
        tls: bool,
        #[arg(long)]
        root: Option<String>,
        #[arg(long)]
        proxy: Option<String>,
        #[arg(long, default_value = "nginx")]
        engine: String,
    },
    /// List sites
    List,
    /// Remove a site
    Rm { domain: String },
}

#[derive(Subcommand)]
enum LbAction {
    /// Create a load balancer
    Create {
        name: String,
        #[arg(long = "backend", value_name = "HOST:PORT")]
        backends: Vec<String>,
        #[arg(long, default_value = "roundrobin")]
        algo: String,
        #[arg(long)]
        health: Option<String>,
        #[arg(long, default_value_t = 80)]
        port: u16,
        #[arg(long, default_value = "haproxy")]
        engine: String,
    },
    /// List load balancers
    List,
    /// Remove a load balancer
    Rm { name: String },
}

#[derive(Subcommand)]
enum HaAction {
    /// Create a VRRP instance
    Create {
        name: String,
        #[arg(long)]
        vip: String,
        #[arg(long)]
        interface: String,
        #[arg(long, default_value_t = 100)]
        priority: u16,
        #[arg(long, default_value = "BACKUP")]
        state: String,
    },
}

fn not_yet(what: &str) -> Result<()> {
    bail!("`{what}` is not yet ported to Rust; reference implementation: packages/bastion-host/bin/bastion-host");
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.group {
        Group::Site { action } => match action {
            SiteAction::Create { .. } => not_yet("site create"),
            SiteAction::List => not_yet("site list"),
            SiteAction::Rm { .. } => not_yet("site rm"),
        },
        Group::Lb { action } => match action {
            LbAction::Create { .. } => not_yet("lb create"),
            LbAction::List => not_yet("lb list"),
            LbAction::Rm { .. } => not_yet("lb rm"),
        },
        Group::Ha { action } => match action {
            HaAction::Create { .. } => not_yet("ha create"),
        },
    }
}
