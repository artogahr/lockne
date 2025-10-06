//! Lockne - Dynamic Per-Application VPN Tunneling with eBPF
//!
//! This is the main entry point for the Lockne daemon.
//! See the library documentation for more details on the architecture.

use lockne::{Config, LockneLoader};
use tokio::signal;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Initialize logging
    env_logger::init();

    // Parse command-line configuration
    let config = Config::from_args();

    // Load the eBPF programs
    let mut loader = LockneLoader::new()?;

    // Setup eBPF logging
    lockne::logger::setup_ebpf_logger(loader.ebpf_mut(), config.limit)?;

    // Attach the TC egress classifier to the network interface
    loader.attach_tc_program(&config.iface)?;

    // Attach the cgroup socket tracker
    loader.attach_cgroup_program(&config.cgroup_path)?;

    // Print status message
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
