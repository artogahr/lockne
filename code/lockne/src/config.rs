//! Configuration structures for Lockne

use clap::Parser;

/// Command-line configuration for Lockne
#[derive(Debug, Parser)]
#[clap(name = "lockne", about = "Per-application VPN tunneling with eBPF")]
pub struct Config {
    /// Network interface to attach to (e.g., eno1, wlan0)
    #[clap(short, long, default_value = "eno1")]
    pub iface: String,

    /// Limit number of packets to log before exiting (0 = unlimited)
    /// Useful for testing and debugging
    #[clap(short, long)]
    pub limit: Option<u32>,

    /// Path to the root cgroup (usually /sys/fs/cgroup for cgroup v2)
    #[clap(long, default_value = "/sys/fs/cgroup")]
    pub cgroup_path: String,

    /// Enable TUI (terminal user interface) mode
    #[clap(long)]
    pub tui: bool,
}

impl Config {
    /// Parse configuration from command-line arguments
    pub fn from_args() -> Self {
        Config::parse()
    }
}