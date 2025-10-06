//! Lockne: Dynamic Per-Application VPN Tunneling with eBPF
//!
//! This library provides the core functionality for loading and managing
//! eBPF programs that track network packets to their originating processes.

pub mod loader;
pub mod logger;
pub mod config;

pub use config::Config;
pub use loader::LockneLoader;

/// Common error type for Lockne operations
pub type Result<T> = anyhow::Result<T>;