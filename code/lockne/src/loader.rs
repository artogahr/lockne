//! eBPF program loading and management
//!
//! This module handles loading the compiled eBPF programs and attaching
//! them to the appropriate kernel hooks.

use aya::maps::HashMap;
use aya::programs::{CgroupAttachMode, CgroupSockAddr, SchedClassifier, TcAttachType, tc};
use aya::Ebpf;
use log::{debug, info};
use std::fs::File;
use std::ffi::CString;
use lockne_common::{Pid, PolicyEntry};

use crate::Result;

/// Get the interface index for an interface name
pub fn get_ifindex(iface: &str) -> Result<u32> {
    let c_iface = CString::new(iface)?;
    let ifindex = unsafe { libc::if_nametoindex(c_iface.as_ptr()) };
    if ifindex == 0 {
        anyhow::bail!("Interface '{}' not found", iface);
    }
    Ok(ifindex)
}

/// Main loader for Lockne eBPF programs
pub struct LockneLoader {
    ebpf: Ebpf,
}

impl LockneLoader {
    /// Load the eBPF object from embedded bytes
    pub fn new() -> Result<Self> {
        // Bump the memlock rlimit for older kernels
        // See: https://lwn.net/Articles/837122/
        Self::increase_memlock_limit();

        let ebpf = aya::Ebpf::load(aya::include_bytes_aligned!(concat!(
            env!("OUT_DIR"),
            "/lockne"
        )))?;

        Ok(Self { ebpf })
    }

    /// Get mutable reference to the eBPF object (for logger setup)
    pub fn ebpf_mut(&mut self) -> &mut Ebpf {
        &mut self.ebpf
    }

    /// Attach the TC (Traffic Control) egress classifier to a network interface
    ///
    /// # Arguments
    /// * `iface` - Network interface name (e.g., "eno1", "wlan0")
    pub fn attach_tc_program(&mut self, iface: &str) -> Result<()> {
        info!("Attaching TC egress program to interface {}", iface);

        // Add clsact qdisc if not already present
        // Error if already exists is harmless
        let _ = tc::qdisc_add_clsact(iface);

        // Load and attach the classifier
        let program: &mut SchedClassifier = self
            .ebpf
            .program_mut("lockne")
            .ok_or_else(|| anyhow::anyhow!("TC program 'lockne' not found"))?
            .try_into()?;

        program.load()?;
        program.attach(iface, TcAttachType::Egress)?;

        info!("Successfully attached TC program to {}", iface);
        Ok(())
    }

    /// Attach the cgroup socket tracking program
    ///
    /// This program tracks socket creation events to build the PID mapping.
    ///
    /// # Arguments
    /// * `cgroup_path` - Path to cgroup to attach to (usually /sys/fs/cgroup)
    pub fn attach_cgroup_program(&mut self, cgroup_path: &str) -> Result<()> {
        info!("Attaching cgroup socket tracking to {}", cgroup_path);

        let program: &mut CgroupSockAddr = self
            .ebpf
            .program_mut("lockne_connect4")
            .ok_or_else(|| anyhow::anyhow!("Cgroup program 'lockne_connect4' not found"))?
            .try_into()?;

        program.load()?;

        let cgroup_file = File::open(cgroup_path)?;
        program.attach(cgroup_file, CgroupAttachMode::Single)?;

        info!("Successfully attached cgroup program");
        Ok(())
    }

    /// Set a redirect policy for a specific PID
    ///
    /// Traffic from this PID will be redirected to the specified interface.
    ///
    /// # Arguments
    /// * `pid` - The process ID to redirect traffic for
    /// * `ifindex` - The interface index to redirect to
    pub fn set_redirect_policy(&mut self, pid: Pid, ifindex: u32) -> Result<()> {
        let mut policy_map: HashMap<_, Pid, PolicyEntry> = 
            self.ebpf.map_mut("POLICY_MAP")
                .ok_or_else(|| anyhow::anyhow!("POLICY_MAP not found"))?
                .try_into()?;

        let entry = PolicyEntry {
            ifindex,
            flags: 0,
        };

        policy_map.insert(pid, entry, 0)?;
        info!("Set redirect policy: PID {} -> ifindex {}", pid, ifindex);
        Ok(())
    }

    /// Remove a redirect policy for a PID
    pub fn remove_redirect_policy(&mut self, pid: Pid) -> Result<()> {
        let mut policy_map: HashMap<_, Pid, PolicyEntry> = 
            self.ebpf.map_mut("POLICY_MAP")
                .ok_or_else(|| anyhow::anyhow!("POLICY_MAP not found"))?
                .try_into()?;

        policy_map.remove(&pid)?;
        info!("Removed redirect policy for PID {}", pid);
        Ok(())
    }

    /// Increase memlock limit for eBPF maps
    ///
    /// Older kernels require this to allow eBPF maps to use more memory
    fn increase_memlock_limit() {
        let rlim = libc::rlimit {
            rlim_cur: libc::RLIM_INFINITY,
            rlim_max: libc::RLIM_INFINITY,
        };

        let ret = unsafe { libc::setrlimit(libc::RLIMIT_MEMLOCK, &rlim) };
        if ret != 0 {
            debug!("Failed to remove memlock limit, ret: {}", ret);
        }
    }
}