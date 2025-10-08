//! Configuration structures for Lockne

use clap::{Parser, Subcommand};

/// Command-line configuration for Lockne
#[derive(Debug, Parser)]
#[clap(name = "lockne", about = "Per-application VPN tunneling with eBPF")]
pub struct Config {
    #[clap(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Run a command with traffic tracking
    /// Example: lockne run firefox
    Run {
        /// Network interface to attach to
        #[clap(short, long, default_value = "eno1")]
        iface: String,

        /// Enable TUI mode
        #[clap(long)]
        tui: bool,

        /// Command and arguments to run
        #[clap(trailing_var_arg = true, required = true)]
        program: Vec<String>,
    },

    /// Monitor all traffic (old behavior)
    Monitor {
        /// Network interface to attach to
        #[clap(short, long, default_value = "eno1")]
        iface: String,

        /// Limit number of packets to log before exiting
        #[clap(short, long)]
        limit: Option<u32>,

        /// Enable TUI mode
        #[clap(long)]
        tui: bool,
    },
}

impl Config {
    /// Parse configuration from command-line arguments
    pub fn from_args() -> Self {
        Config::parse()
    }

    /// Get the interface name from the command
    pub fn iface(&self) -> &str {
        match &self.command {
            Command::Run { iface, .. } => iface,
            Command::Monitor { iface, .. } => iface,
        }
    }

    /// Check if TUI mode is enabled
    pub fn tui(&self) -> bool {
        match &self.command {
            Command::Run { tui, .. } => *tui,
            Command::Monitor { tui, .. } => *tui,
        }
    }

    /// Get cgroup path (always root for now)
    pub fn cgroup_path(&self) -> &str {
        "/sys/fs/cgroup"
    }
}