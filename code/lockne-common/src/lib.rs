#![no_std]

// The Process ID type we'll store in our maps
pub type Pid = u32;

/// Policy action for a specific PID
/// Stores the interface index to redirect traffic to (0 = no redirect)
#[repr(C)]
#[derive(Copy, Clone, Default)]
pub struct PolicyEntry {
    /// Interface index to redirect to (0 = don't redirect, just track)
    pub ifindex: u32,
    /// Flags for future use
    pub flags: u32,
}

// Ensure proper memory layout for eBPF map compatibility
#[cfg(feature = "user")]
unsafe impl aya::Pod for PolicyEntry {}
