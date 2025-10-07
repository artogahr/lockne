//! eBPF logging infrastructure
//!
//! This module handles setting up the logging pipeline from eBPF programs
//! to userspace console output.

use aya::Ebpf;
use log::warn;
use tokio::io::unix::AsyncFd;
use crate::ui::SharedStats;

/// Setup eBPF logging and spawn a task to handle log messages
///
/// # Arguments
/// * `ebpf` - The loaded eBPF object
/// * `limit` - Optional limit on number of log messages before exiting
///
/// # Returns
/// Ok(()) if logger was successfully initialized
pub fn setup_ebpf_logger(ebpf: &mut Ebpf, limit: Option<u32>) -> anyhow::Result<()> {
    match aya_log::EbpfLogger::init(ebpf) {
        Err(e) => {
            // This can happen if you remove all log statements from your eBPF program
            warn!("Failed to initialize eBPF logger: {}", e);
            Ok(())
        }
        Ok(logger) => {
            // Wrap the logger in an async file descriptor
            let mut logger = AsyncFd::with_interest(logger, tokio::io::Interest::READABLE)?;
            
            // Spawn a task to handle log messages
            tokio::task::spawn(async move {
                let mut count = 0u32;
                loop {
                    let mut guard = logger.readable_mut().await.unwrap();
                    guard.get_inner_mut().flush();
                    guard.clear_ready();

                    // If we have a limit, count messages and exit when reached
                    if let Some(limit) = limit {
                        count += 1;
                        if count >= limit {
                            println!("Reached packet limit of {}, exiting...", limit);
                            std::process::exit(0);
                        }
                    }
                }
            });
            
            Ok(())
        }
    }
}

/// Setup eBPF logger with stats tracking for TUI mode
pub fn setup_ebpf_logger_with_stats(
    ebpf: &mut Ebpf,
    limit: Option<u32>,
    stats: SharedStats,
) -> anyhow::Result<()> {
    match aya_log::EbpfLogger::init(ebpf) {
        Err(e) => {
            warn!("Failed to initialize eBPF logger: {}", e);
            Ok(())
        }
        Ok(logger) => {
            let mut logger = AsyncFd::with_interest(logger, tokio::io::Interest::READABLE)?;
            
            tokio::task::spawn(async move {
                let mut count = 0u32;
                loop {
                    let mut guard = logger.readable_mut().await.unwrap();
                    
                    guard.get_inner_mut().flush();
                    guard.clear_ready();

                    // Update stats (just increment for now - we'd need to parse logs properly)
                    {
                        let mut s = stats.lock().unwrap();
                        s.packets_seen += 1;
                    }

                    if let Some(limit) = limit {
                        count += 1;
                        if count >= limit {
                            std::process::exit(0);
                        }
                    }
                }
            });
            
            Ok(())
        }
    }
}
