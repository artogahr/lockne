//! Lockne - Dynamic Per-Application VPN Tunneling with eBPF
//!
//! This is the main entry point for the Lockne daemon.
//! See the library documentation for more details on the architecture.

use lockne::{config::Command, Config, LockneLoader};
use log::info;
use tokio::signal;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Parse command-line configuration
    let config = Config::from_args();

    // Initialize logging (skip if using TUI)
    if !config.tui() {
        env_logger::init();
    }

    // Load the eBPF programs
    let loader = LockneLoader::new()?;

    // Handle different commands
    match &config.command {
        Command::Run { program, .. } => {
            run_program_mode(loader, &config, program).await?;
        }
        Command::Monitor { limit, .. } => {
            run_monitor_mode(loader, &config, *limit).await?;
        }
    }

    Ok(())
}

/// Run a specific program and track its traffic
async fn run_program_mode(
    mut loader: LockneLoader,
    config: &Config,
    program: &[String],
) -> anyhow::Result<()> {
    // Setup eBPF logging
    lockne::logger::setup_ebpf_logger(loader.ebpf_mut(), None)?;

    // Attach programs
    loader.attach_tc_program(config.iface())?;
    loader.attach_cgroup_program(config.cgroup_path())?;

    // Launch the target program
    let child = lockne::runner::launch_program(program)?;
    let pid = child.id();

    println!("Tracking traffic for PID {} (press Ctrl-C to stop)", pid);
    
    // Wait for the program to exit or Ctrl-C
    lockne::runner::wait_for_process(child).await?;

    println!("Exiting...");
    Ok(())
}

/// Monitor all system traffic (old behavior)
async fn run_monitor_mode(
    mut loader: LockneLoader,
    config: &Config,
    limit: Option<u32>,
) -> anyhow::Result<()> {
    if config.tui() {
        run_monitor_with_tui(loader, config, limit).await
    } else {
        run_monitor_cli(loader, config, limit).await
    }
}

/// Monitor mode with CLI logging
async fn run_monitor_cli(
    mut loader: LockneLoader,
    config: &Config,
    limit: Option<u32>,
) -> anyhow::Result<()> {
    // Setup eBPF logging
    lockne::logger::setup_ebpf_logger(loader.ebpf_mut(), limit)?;

    // Attach programs
    loader.attach_tc_program(config.iface())?;
    loader.attach_cgroup_program(config.cgroup_path())?;

    // Print status
    if limit.is_some() {
        println!("Logging packets with limit, will exit automatically...");
    } else {
        println!("Waiting for Ctrl-C...");
    }

    // Wait for Ctrl-C
    signal::ctrl_c().await?;
    println!("Exiting...");

    Ok(())
}

/// Monitor mode with TUI
async fn run_monitor_with_tui(
    mut loader: LockneLoader,
    config: &Config,
    limit: Option<u32>,
) -> anyhow::Result<()> {
    use lockne::ui::{SharedStats, Stats};
    use std::sync::{Arc, Mutex};

    // Create shared stats
    let stats: SharedStats = Arc::new(Mutex::new(Stats::default()));

    // Setup eBPF logging with stats tracking
    lockne::logger::setup_ebpf_logger_with_stats(loader.ebpf_mut(), limit, stats.clone())?;

    // Attach programs
    loader.attach_tc_program(config.iface())?;
    loader.attach_cgroup_program(config.cgroup_path())?;

    // Run the TUI
    lockne::ui::run_tui(stats).await?;

    Ok(())
}
