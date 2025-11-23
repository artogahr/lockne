#![no_std]
#![no_main]
#![allow(unsafe_op_in_unsafe_fn)]

use aya_ebpf::{
    bindings::TC_ACT_PIPE,
    macros::{classifier, cgroup_sock_addr, map},
    maps::HashMap,
    programs::{TcContext, SockAddrContext},
    helpers::{bpf_get_socket_cookie, bpf_get_current_pid_tgid, bpf_redirect},
};
use aya_log_ebpf::info;
use core::mem;
use lockne_common::{Pid, PolicyEntry};

// Map to store socket cookie -> PID mappings
// Populated by cgroup/sock_addr program when connections are made
#[map]
static SOCKET_PID_MAP: HashMap<u64, Pid> = HashMap::with_max_entries(10240, 0);

// Policy map: PID -> redirect target interface index
// If a PID is in this map with ifindex > 0, redirect its traffic
#[map]
static POLICY_MAP: HashMap<Pid, PolicyEntry> = HashMap::with_max_entries(1024, 0);

#[repr(C)]
#[derive(Copy, Clone)]
pub struct EthHdr {
    pub h_dest: [u8; 6],
    pub h_source: [u8; 6],
    pub h_proto: u16,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct Ipv4Hdr {
    pub version_ihl: u8,
    pub tos: u8,
    pub tot_len: u16,
    pub id: u16,
    pub frag_off: u16,
    pub ttl: u8,
    pub protocol: u8,
    pub check: u16,
    pub saddr: u32,
    pub daddr: u32,
}


#[classifier]
pub fn lockne(ctx: TcContext) -> i32 {
    match try_lockne(ctx) {
        Ok(ret) => ret,
        Err(ret) => ret,
    }
}

fn try_lockne(ctx: TcContext) -> Result<i32, i32> {
    let eth_hdr: EthHdr = ctx.load(0).map_err(|_| 1)?;
    if u16::from_be(eth_hdr.h_proto) != 0x0800 {
        // Not an IPv4 packet, pass it through
        return Ok(TC_ACT_PIPE);
    }

    let ipv4_hdr: Ipv4Hdr = ctx.load(mem::size_of::<EthHdr>()).map_err(|_| 1)?;
    let source = u32::from_be(ipv4_hdr.saddr);
    let dest = u32::from_be(ipv4_hdr.daddr);

    // Convert IP addresses to dotted decimal notation components
    let source_a = (source >> 24) & 0xFF;
    let source_b = (source >> 16) & 0xFF;
    let source_c = (source >> 8) & 0xFF;
    let source_d = source & 0xFF;
    
    let dest_a = (dest >> 24) & 0xFF;
    let dest_b = (dest >> 16) & 0xFF;
    let dest_c = (dest >> 8) & 0xFF;
    let dest_d = dest & 0xFF;

    // Try to get the socket cookie for this packet
    let socket_cookie = unsafe { bpf_get_socket_cookie(ctx.skb.skb as *mut _) };

    // Look up the PID associated with this socket cookie
    let pid = unsafe { SOCKET_PID_MAP.get(&socket_cookie) };

    match pid {
        Some(pid_value) => {
            // Check if this PID has a redirect policy
            let policy = unsafe { POLICY_MAP.get(pid_value) };
            
            match policy {
                Some(entry) if entry.ifindex > 0 => {
                    // Redirect this packet to the specified interface
                    info!(&ctx, "REDIRECT {}.{}.{}.{} -> {}.{}.{}.{} pid={} ifindex={}", 
                        source_a, source_b, source_c, source_d,
                        dest_a, dest_b, dest_c, dest_d,
                        *pid_value,
                        entry.ifindex
                    );
                    return Ok(unsafe { bpf_redirect(entry.ifindex, 0) } as i32);
                }
                _ => {
                    // No redirect policy, just log
                    info!(&ctx, "{} {}.{}.{}.{} {}.{}.{}.{} cookie={} pid={}", 
                        ctx.len(), 
                        source_a, source_b, source_c, source_d,
                        dest_a, dest_b, dest_c, dest_d,
                        socket_cookie,
                        *pid_value
                    );
                }
            }
        }
        None => {
            // No PID mapping found for this socket cookie
            info!(&ctx, "{} {}.{}.{}.{} {}.{}.{}.{} cookie={} pid=unknown", 
                ctx.len(), 
                source_a, source_b, source_c, source_d,
                dest_a, dest_b, dest_c, dest_d,
                socket_cookie
            );
        }
    }

    Ok(TC_ACT_PIPE)
}

// This program is attached to a cgroup and is called whenever a process
// in that cgroup performs a socket operation (like connect or sendmsg).
// We use this to capture the mapping between a socket and the process that owns it.
#[cgroup_sock_addr(connect4)]
pub fn lockne_connect4(ctx: SockAddrContext) -> i32 {
    match unsafe { try_lockne_connect4(ctx) } {
        Ok(ret) => ret,
        Err(_) => 1,
    }
}

unsafe fn try_lockne_connect4(ctx: SockAddrContext) -> Result<i32, i64> {
    // Get the socket cookie - a unique, stable identifier for this socket
    let sock_cookie = bpf_get_socket_cookie(ctx.sock_addr as *mut _);
    
    // Get the PID of the process making this connection
    // bpf_get_current_pid_tgid returns both PID and TGID in a u64
    // The upper 32 bits are the TGID (thread group ID, which is the actual process ID)
    // The lower 32 bits are the PID (thread ID)
    let pid_tgid = bpf_get_current_pid_tgid();
    let pid = (pid_tgid >> 32) as u32;
    
    // Store the mapping in our hash map
    SOCKET_PID_MAP.insert(&sock_cookie, &pid, 0)
        .map_err(|e| e as i64)?;
    
    info!(&ctx, "Tracked socket cookie={} for pid={}", sock_cookie, pid);
    
    // Return 1 to allow the connection to proceed
    Ok(1)
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
