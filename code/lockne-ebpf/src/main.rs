#![no_std]
#![no_main]

use aya_ebpf::{
    bindings::TC_ACT_PIPE,
    macros::{classifier, map},
    maps::HashMap,
    programs::TcContext,
    helpers::bpf_get_socket_cookie,
};
use aya_log_ebpf::info;
use core::mem;
use lockne_common::Pid;

// Map to store socket cookie -> PID mappings
// This will be populated by a cgroup/sock_addr program (to be implemented)
// and read by this TC classifier program
#[map]
static SOCKET_PID_MAP: HashMap<u64, Pid> = HashMap::with_max_entries(10240, 0);

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
            info!(&ctx, "{} {}.{}.{}.{} {}.{}.{}.{} cookie={} pid={}", 
                ctx.len(), 
                source_a, source_b, source_c, source_d,
                dest_a, dest_b, dest_c, dest_d,
                socket_cookie,
                *pid_value
            );
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

#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

#[unsafe(link_section = "license")]
#[unsafe(no_mangle)]
static LICENSE: [u8; 13] = *b"Dual MIT/GPL\0";
