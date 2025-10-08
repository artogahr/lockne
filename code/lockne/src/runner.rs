//! Process launching and tracking
//!
//! This module handles launching a subprocess and monitoring its lifecycle.

use std::process::{Child, Command};
use tokio::signal;
use log::info;

/// Launch a program and return its PID
pub fn launch_program(program: &[String]) -> anyhow::Result<Child> {
    if program.is_empty() {
        anyhow::bail!("No program specified");
    }

    let (cmd, args) = program.split_first().unwrap();
    
    info!("Launching program: {} {:?}", cmd, args);
    
    let child = Command::new(cmd)
        .args(args)
        .spawn()?;
    
    info!("Started process with PID: {}", child.id());
    
    Ok(child)
}

/// Wait for a child process or Ctrl-C, whichever comes first
pub async fn wait_for_process(mut child: Child) -> anyhow::Result<()> {
    let pid = child.id();
    
    tokio::select! {
        // Child process exited
        status = tokio::task::spawn_blocking(move || child.wait()) => {
            match status? {
                Ok(exit_status) => {
                    info!("Process {} exited with status: {}", pid, exit_status);
                    Ok(())
                }
                Err(e) => {
                    anyhow::bail!("Failed to wait for process: {}", e);
                }
            }
        }
        
        // User pressed Ctrl-C
        _ = signal::ctrl_c() => {
            info!("Ctrl-C received, terminating process {}", pid);
            // The child will be killed when it's dropped
            Ok(())
        }
    }
}