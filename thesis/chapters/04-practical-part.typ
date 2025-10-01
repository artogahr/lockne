= Practical Part

== Initial Setup

The implementation started with setting up a basic eBPF project using the Aya framework. The project structure follows the standard Aya template with three main crates:

- `lockne-ebpf`: Contains the eBPF programs that run in the kernel
- `lockne`: The userspace loader and control plane  
- `lockne-common`: Shared types between kernel and userspace

The first step was to get a basic TC (Traffic Control) egress classifier working. This program attaches to a network interface and runs for every outgoing packet. At this stage, it simply logged basic packet information - the packet length and IP addresses.

== Building the Process Tracking System

The core challenge of this project is linking network packets to the processes that created them. As discussed in the literature review, the kernel doesn't attach process information to packets by default. We need to build this mapping ourselves.

=== Socket Cookies as Stable Identifiers

The key to solving this problem is the socket cookie. Each socket in the Linux kernel gets assigned a unique 64-bit number called a cookie. This number stays the same for the entire lifetime of the socket, making it perfect for our use case.

The approach works like this:
1. When a process creates a socket and connects, we capture both the socket cookie and the PID
2. We store this mapping in an eBPF hash map
3. Later, when packets go through the TC egress hook, we extract the socket cookie from the packet
4. We look up the cookie in our map to find which PID sent this packet

=== The Two-Program Architecture

To implement this, we need two separate eBPF programs working together:

==== The Cgroup Socket Tracker

The first program is a `cgroup/sock_addr` program. This type of program gets called whenever a process performs socket operations like `connect()`. The key advantage is that it runs in a context where we have access to both the socket and the process information.

When a process makes an IPv4 connection, our program:
1. Gets the socket cookie using `bpf_get_socket_cookie()`
2. Gets the process ID using `bpf_get_current_pid_tgid()` 
3. Stores the mapping in a shared hash map

The `bpf_get_current_pid_tgid()` helper returns a 64-bit value where the upper 32 bits contain the TGID (which is actually the process ID), and the lower 32 bits contain the thread ID. We extract just the PID portion.

==== The TC Packet Classifier  

The second program is the TC classifier we started with. For each outgoing packet, it:
1. Extracts the socket cookie from the packet's `sk_buff` structure
2. Looks up this cookie in the hash map
3. If found, it logs the packet with its associated PID
4. If not found, it logs "pid=unknown"

The "unknown" cases are expected - they happen for packets from connections that were established before our program started, or for kernel-generated traffic that doesn't come from a userspace process.

=== Shared State via eBPF Maps

The bridge between these two programs is an eBPF hash map:

```rust
#[map]
static SOCKET_PID_MAP: HashMap<u64, Pid> = 
    HashMap::with_max_entries(10240, 0);
```

This map can hold up to 10,240 socket-to-PID mappings. Both programs can access this same map - one writes to it, the other reads from it. This is how eBPF programs share state.

== Testing and Validation

To test the implementation, the program was run while making HTTP requests with `curl`. The logs clearly show the system working:

```
[INFO  lockne] Tracked socket cookie=20481 for pid=143192
[INFO  lockne] 74 10.0.0.70 23.192.228.80 cookie=20481 pid=143192
[INFO  lockne] 66 10.0.0.70 23.192.228.80 cookie=20481 pid=143192
```

First, the cgroup program captures the socket creation and logs the PID. Then, as packets flow through the TC egress hook, they're correctly associated with that same PID.

This proves that the core mechanism works - we can now identify which process is sending each packet.

== Challenges and Lessons Learned

Building this system involved several technical challenges that required careful debugging and understanding of eBPF internals.

=== Socket Cookie Retrieval in Different Contexts

One early issue was understanding how to correctly retrieve socket cookies in different eBPF program contexts. The `bpf_get_socket_cookie()` helper function works differently depending on where it's called. In the cgroup context, we pass `ctx.sock_addr` as the argument, while in the TC context, we use `ctx.skb.skb`. Getting this right required reading through eBPF helper function documentation and looking at example code.

=== Testing eBPF Programs

Testing eBPF programs is harder than regular userspace code. You can't just run unit tests. The programs need to be loaded into the kernel, and you need to generate actual network traffic to see if they work. Early on, I tried using `ping` for testing, but ping uses ICMP which doesn't go through the `connect()` system call, so the cgroup program wasn't triggered. Using `curl` for HTTP requests worked better because it creates actual TCP connections.

=== Handling Background Processes  

During testing, I had to be careful about cleanup. If the program crashes or gets killed improperly, the eBPF programs stay attached to the cgroup and network interface, and the TC qdisc remains configured. This can cause issues when trying to run the program again. I learned to always clean up with `sudo pkill lockne` and `sudo tc qdisc del dev eno1 clsact` before restarting.

== Current Limitations and Future Work

While the current implementation successfully demonstrates process-to-packet mapping, there are several areas that need further development:

=== IPv6 Support

Right now, only IPv4 connections are tracked. The cgroup program only attaches to `connect4` hooks. To support IPv6, we'd need to add a similar program for `connect6` and update the TC classifier to handle IPv6 packets as well. This is straightforward but wasn't prioritized for the initial proof of concept.

=== Map Cleanup

Currently, entries are added to the socket-to-PID map when connections are established, but they're never removed. This means the map will eventually fill up and stop accepting new entries. A complete implementation needs to track socket close events (probably with a kprobe on `tcp_close` or similar) and remove the corresponding entries.

=== Process Hierarchy Tracking  

If a tracked process spawns child processes, those children get their own PIDs and won't be automatically tracked. For example, if we're tracking Firefox and it spawns a helper process for video decoding, that helper's traffic won't be associated with the parent. Solving this requires tracking fork/clone events and inheriting the parent's policy.

=== Actual Packet Redirection

The most important missing piece is that we're not actually redirecting packets yet - we're just logging which process they came from. The next major step is to use the `bpf_redirect()` helper to actually send packets to a WireGuard interface based on the process that created them. This requires:

1. A policy map to decide which PIDs should be redirected
2. Logic to look up the WireGuard interface index  
3. Actually calling `bpf_redirect()` instead of returning `TC_ACT_PIPE`
4. A userspace control interface to configure policies

Despite these limitations, the current implementation proves the fundamental concept works. We can reliably map packets to processes using socket cookies and eBPF, which is the hardest part of building Lockne.
