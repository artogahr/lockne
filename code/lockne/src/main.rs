//! Lockne - Dynamic Per-Application VPN Tunneling with eBPF
//!
//! This is the main entry point for the Lockne daemon.
//! See the library documentation for more details on the architecture.

use lockne::{Config, LockneLoader};
use tokio::signal;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Parse command-line configuration
    let config = Config::from_args();

    // Initialize logging (skip if using TUI)
    if !config.tui {
        env_logger::init();
    }

    // Load the eBPF programs
    let mut loader = LockneLoader::new()?;

    // If TUI mode, setup with stats tracking
    if config.tui {
        run_with_tui(loader, &config).await?;
    } else {
        run_cli_mode(loader, &config).await?;
    }

    Ok(())
}

/// Run in CLI mode (simple logging)
async fn run_cli_mode(mut loader: LockneLoader, config: &Config) -> anyhow::Result<()> {
    // Setup eBPF logging
    lockne::logger::setup_ebpf_logger(loader.ebpf_mut(), config.limit)?;

    // Attach programs
    loader.attach_tc_program(&config.iface)?;
    loader.attach_cgroup_program(&config.cgroup_path)?;

    // Print status
    if config.limit.is_some() {
        println!("Logging packets with limit, will exit automatically...");
    } else {
        println!("Waiting for Ctrl-C...");
    }

    // Wait for Ctrl-C
    signal::ctrl_c().await?;
    println!("Exiting...");

    Ok(())
}

/// Run in TUI mode (fancy interface)
async fn run_with_tui(mut loader: LockneLoader, config: &Config) -> anyhow::Result<()> {
    use lockne::ui::{SharedStats, Stats};
    use std::sync::{Arc, Mutex};

    // Create shared stats
    let stats: SharedStats = Arc::new(Mutex::new(Stats::default()));

    // Setup eBPF logging with stats tracking
    lockne::logger::setup_ebpf_logger_with_stats(loader.ebpf_mut(), config.limit, stats.clone())?;

    // Attach programs
    loader.attach_tc_program(&config.iface)?;
    loader.attach_cgroup_program(&config.cgroup_path)?;

    // Run the TUI
    lockne::ui::run_tui(stats).await?;

    Ok(())
}
