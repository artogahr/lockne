# Research: Tracking Existing Connections

## The Problem

Currently, Lockne only tracks connections created AFTER it starts. Pre-existing connections show as `pid=unknown`.

**Why?** Our cgroup program only fires on NEW `connect()` calls. Existing sockets were already connected before we attached our program.

## Potential Solutions (Research)

### Option 1: /proc Scanning ❌ (Doesn't work)

**Idea:** When lockne starts, scan `/proc/net/tcp` and `/proc/[pid]/fd/` to backfill the map.

**Problem:** 
- `/proc/net/tcp` shows socket inodes, not socket cookies
- No way to convert inode → socket cookie from userspace
- Socket cookies are kernel-internal identifiers

**Verdict:** Not possible without kernel patches.

### Option 2: NETLINK_SOCK_DIAG ❌ (Partial info only)

**Idea:** Use netlink to query existing sockets.

**What we can get:**
- List of all sockets (IP, port, state)
- Process ID that owns each socket
- Socket inode

**What we CAN'T get:**
- Socket cookie (not exposed via netlink)
- Direct mapping to sk_buff we see in TC hook

**Verdict:** Can see which PIDs have sockets, but can't link them to the packets we intercept.

### Option 3: eBPF Iterators ⚠️ (Kernel 5.8+, complex)

**Idea:** Use BPF iterator programs to walk kernel socket structures.

**How it works:**
```c
SEC("iter/tcp")
int dump_tcp(struct bpf_iter__tcp *ctx) {
    struct sock *sk = ctx->sk;
    // Can access socket cookie here!
    u64 cookie = bpf_get_socket_cookie(sk);
    // Can get task info
    struct task_struct *task = ...;
    // Store in map
}
```

**Pros:**
- Can actually get socket cookies
- Can run once at startup
- Real kernel data

**Cons:**
- Requires kernel 5.8+
- Complex to implement
- Need to handle socket locking correctly
- Aya support unclear

**Verdict:** Technically possible but complex. Worth researching more.

### Option 4: Accept the Limitation ✅ (Current approach)

**Idea:** Document it clearly and work around it.

**Workarounds:**
1. Start lockne before applications you want to track
2. Restart applications after starting lockne
3. Use systemd to start lockne early in boot

**Pros:**
- Simple, no complex code
- Already works perfectly for new connections
- Common pattern (many eBPF tools have this limitation)

**Cons:**
- Not as seamless
- Requires user awareness

**Verdict:** Most practical for a thesis project.

## Real-World Comparison

**How do other tools handle this?**

- **BCC tools** (opensnoop, tcpconnect): Also only track new events
- **Cilium**: Doesn't retroactively track existing connections
- **Falco**: Security tool, only tracks new events from its start time

**This is normal for eBPF tools!**

## Recommendation for Thesis

**For now:** Document the limitation clearly (already done).

**For future work:** Mention eBPF iterators as a possible enhancement.

**In thesis, write:**
> "A known limitation is that Lockne only tracks connections established after it starts. This is a common characteristic of eBPF-based monitoring tools, as they observe events in real-time rather than querying historical state. While eBPF iterator programs (introduced in kernel 5.8) could potentially address this by walking existing kernel socket structures at startup, implementing this would add significant complexity. For most use cases, starting Lockne before launching the applications to be monitored, or restarting them afterward, is a practical workaround."

## Next Steps (if you want to try iterators)

1. Check kernel version: `uname -r` (need 5.8+)
2. Research Aya iterator support
3. Study BPF iterator examples in kernel samples
4. Prototype a simple TCP socket iterator
5. Test if we can get cookies from existing sockets

**Estimated effort:** 1-2 weeks of research and experimentation

**Value for thesis:** Interesting technical deep-dive, but not essential for proving the core concept works.

## My Recommendation

**Don't implement this for the thesis.** The current limitation is well-understood and documented. Focus on:
1. ✅ Process tracking (done!)
2. 🔄 Packet redirection (next priority)
3. ⏳ Map cleanup (important for stability)
4. ⏳ IPv6 support (good to have)

Tracking existing connections is a "nice to have" feature, not a "must have" for proving your thesis concept.