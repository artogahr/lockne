// LITERATURE REVIEW EXPANSION GUIDE
// Target: 20 pages total (currently ~8 pages)
// Timeline: Complete by end of Week 4 (Month 1)
//
// CURRENT STATUS: Basic structure exists
// WHAT YOU NEED TO ADD: ~12 more pages in sections marked with TODO
//
// WRITING TIPS FOR ADHD:
// - Write 1-2 pages per day maximum
// - Start with the section you find most interesting
// - Use the Pomodoro technique (25 min focused writing)
// - Don't edit while writing - just get content down first
//
// RESEARCH STRATEGY:
// - Each TODO section includes specific papers/books to read
// - Spend 30-45 minutes reading, then 60-90 minutes writing
// - Focus on finding 3-5 key papers per section
// - Use Google Scholar for academic papers
// - Check university library for book access

= Literature Review

Before designing and building Lockne, it is essential to understand the technologies that make it possible and the context in which it will operate. This review surveys the technical landscape, focusing on the three pillars of the project: the eBPF framework for kernel programmability, the WireGuard protocol for secure and performant tunneling, and the Rust language for building a reliable control plane. Critically, it also analyzes existing approaches to application-specific traffic control, identifying their limitations. The goal is to establish a clear justification for Lockne's architecture by demonstrating how it addresses a distinct gap left by current solutions.

// SECTION STATUS: Complete (3 pages) ✓
// This section is good as-is, no expansion needed

== The Kernel's New Superpower: An Overview of eBPF

The core mechanism behind Lockne is the extended Berkeley Packet Filter (eBPF). To understand its importance, one must see it not just as a tool, but as a fundamental shift in how the Linux kernel can be extended. As described by Brendan Gregg, eBPF allows sandboxed programs to run directly within the kernel in response to specific events, without requiring changes to the kernel source code or loading kernel modules @greggBpfPerformanceTools2019. This provides a safe, performant way to implement custom logic at the lowest levels of the operating system. He's also described eBPF as "like putting JavaScript into the Linux kernel" @EBPFDocumentary.

=== Life without eBPF

To understand eBPF's importance here, it helps to look at how an application similar to Lockne would be implemented without it. To "catch" packets before they leave the network interface, we need some sort of mechanism either inside or outside the kernel (who is ultimately responsible for the packet routing). Since the Linux kernel is open-source, one way to do this could be to add additional code inside the Linux kernel's network handling parts, recompile the kernel, and boot with it. This approach is obviously not ideal, and infeasible to expect from the end-user. A second similar (but much more realistic) approach could be to write a loadable kernel module (LKM), which is a pre-compiled binary that can provide additional capabilities to a running kernel. Most operating systems have some sort of dynamic module system implemented, but they often are hard to develop for, hard to ensure compatibility, and easy to break (which may potentially take down the whole operating system with it). One of the design goals for Lockne is transparency, therefore it should never crash the host system. And lastly, you can write a user space application, which would be easier to develop for and be much safer, but this entails eating the performance penalty of having to copy packets to-and-from the kernel space.

None of these solutions are ideal for our use case, but thankfully modern eBPF implementation in the Linux kernel allows us to implement Lockne without any of the mentioned problems.

=== From Packet Filtering to In-Kernel Virtual Machine

The original Berkeley Packet Filter (BPF), often called classic BPF (cBPF), was designed in the 1990s with a single purpose: to filter network packets efficiently in userspace tools like `tcpdump`. It was a simple, register-based virtual machine that could decide whether to accept or drop a packet. Imagine putting simple "if statements" in the processing path of every network packet, which decided if the packet passes through, or is dropped.

eBPF (extended BPF), introduced in 2014, is a complete redesign. It expands the original concept into a general-purpose, 64-bit virtual machine inside the kernel. Despite the names being similar, it can work with much more than just network packets. As Liz Rice explains in _Learning eBPF_, it's more than just a filter; it's a tool for building a wide range of networking, security, and observability applications @riceLearningEBPFProgramming2023. Using eBPF binaries dynamically loaded in the kernel using the `bpf()` system call, we can attach to and manipulate data from almost any event that happens within the Linux kernel. In practice, this will let us to attach to the network data path, in which we can read every packet, see if we're interested in it, and route it to some other place if necessary.

Before any eBPF program is loaded, it must pass through a strict in-kernel verifier. This verifier statically analyzes the program's code, checking for out-of-bounds memory access, infinite loops, and illegal instructions. This verification step is what makes eBPF safe to run in the kernel, a critical feature that distinguishes it from traditional kernel modules which can easily crash the entire system.

Furthermore, being implemented directly in the kernel, eBPF programs don't have the usual performance constraints of having to route the packets through the user space. We will see examples of this in the "Analyzing Existing Solutions" section. For extreme use cases, modern eBPF programs also support eXpress Data Path (XDP), which lets us run the eBPF filtering _directly in the network interface card driver_, bypassing most of the OS networking stack.

=== The eBPF Ecosystem and Toolchain Evolution

The development of eBPF has been accompanied by a rich ecosystem of tools and libraries that have significantly lowered the barrier to entry for kernel programming. The BPF Compiler Collection (BCC) was one of the first major frameworks, providing Python and Lua frontends for writing eBPF programs with automatic compilation and loading. However, BCC's approach of compiling eBPF code at runtime introduced dependencies and deployment complexities.

The introduction of BTF (BPF Type Format) and CO-RE (Compile Once - Run Everywhere) has revolutionized eBPF development. BTF provides rich type information about kernel structures, while CO-RE enables eBPF programs compiled on one kernel version to run on different kernel versions by automatically adjusting field offsets. This portability is crucial for Lockne, as it must operate across diverse Linux distributions and kernel versions without requiring recompilation.

Modern eBPF development has also embraced the libbpf ecosystem, which provides a stable, low-level C API for eBPF program loading and management. This foundation has enabled the development of higher-level language bindings, including Rust bindings like `libbpf-rs` and the more comprehensive `aya` library that Lockne leverages.

=== Core Components for Lockne: Programs, Maps, and Hooks

To build a system like Lockne, we must use three key eBPF concepts:

- *Hooks:* These are well-defined points in the kernel's code path where an eBPF program can be attached. For network-related tasks, the most important hooks are on the Traffic Control (TC) subsystem and on control groups (cgroups). By attaching a program to a TC hook on a network interface, we can inspect and manipulate every packet that passes through it. This is the primary mechanism Lockne will use to redirect traffic.

- *Programs:* An eBPF program is the actual code that runs at a hook. For Lockne, the TC program will look at a packet, determine which process created it, and decide whether to send it to a WireGuard tunnel or let it pass through the default route.

- *Maps:* Maps are the communication bridge. They are efficient key-value data structures that can be accessed from both eBPF programs running in the kernel and from userspace applications. For Lockne, maps are the "brain" of the operation. The Rust daemon will write routing policies (e.g., "PID 1234 -> WireGuard interface A") into a map. The eBPF program in the kernel will then read from this map to make its routing decisions in real-time. This allows for dynamic policy updates without reloading the kernel program.

// SECTION STATUS: Complete (2 pages) ✓
// This section is good as-is, no expansion needed

== Secure and Performant Tunneling: The WireGuard Protocol

Lockne does not just redirect traffic; it routes it into a secure tunnel. The choice of VPN protocol is therefore critical. This section reviews WireGuard, arguing that its design philosophy of simplicity, high performance, and tight kernel integration makes it the ideal foundation for Lockne's tunneling component.

WireGuard's design is centered on an aggressive pursuit of simplicity. The entire protocol is implemented in approximately 4,000 lines of C code, excluding cryptographic primitives @donenfeldWireGuardNextGeneration2017. This minimalist codebase, estimated to be two orders of magnitude smaller than that of OpenVPN or IPsec solutions, dramatically reduces the potential attack surface and simplifies security auditing @salterWireGuardVPNReview2018. This focus on a minimal, auditable design has been validated by multiple professional security audits. The simplicity extends to its operation, which uses a constrained and well-defined state machine. For the end-user, this results in a seamless "it just works" experience where tunnels are established transparently using a simple exchange of public keys. This philosophy is a core inspiration for Lockne's own design goals.

This simplicity directly enables WireGuard's second key advantage: performance. Unlike popular userspace protocols like OpenVPN, which must repeatedly copy packets between the kernel and a userspace process for encryption and decryption, WireGuard operates directly within the Linux kernel. By eliminating this context-switching overhead for every packet, it achieves significantly higher throughput and lower latency. While other in-kernel protocols like IPsec exist, WireGuard often maintains a performance edge by leveraging more modern, efficient cryptographic algorithms. This kernel-native architecture is the crucial feature for Lockne; it allows packets redirected by an eBPF program to be handed directly to the WireGuard interface within the kernel, creating the most efficient path possible from application to secure tunnel.

=== Cryptographic Design and Security Properties

WireGuard's cryptographic design represents a significant departure from traditional VPN protocols. Unlike IPsec or OpenVPN, which support numerous cipher suites and authentication methods, WireGuard deliberately restricts itself to a single, carefully chosen set of modern cryptographic primitives: Curve25519 for key exchange, ChaCha20 for symmetric encryption, Poly1305 for authentication, BLAKE2s for hashing, and SipHash24 for hashtable keys @donenfeldWireGuardNextGeneration2017.

This cryptographic rigidity eliminates entire classes of vulnerabilities associated with cipher suite negotiation and downgrade attacks. The chosen primitives represent current best practices in cryptographic research, providing both high security and excellent performance on modern hardware. For Lockne, this design choice ensures that all tunneled traffic benefits from state-of-the-art cryptographic protection without complex configuration or performance tuning.

// SECTION STATUS: Complete (2 pages) ✓
// This section is good as-is, no expansion needed

== A Foundation of Safety and Performance: The Role of Rust

While eBPF provides the mechanism for kernel-level redirection, a robust and reliable userspace control plane is required to manage policies, monitor processes, and configure network interfaces. The choice of programming language for this component is a critical architectural decision. Lockne is implemented in Rust, a modern systems programming language that provides a unique combination of performance and safety, making it exceptionally well-suited for this task.

=== Memory Safety without a Garbage Collector

Rust's most significant advantage for systems programming lies in its approach to memory safety. Through its ownership system and borrow checker, Rust prevents entire classes of bugs that plague C and C++ programs, including use-after-free errors, double-free errors, buffer overflows, and data races @klabnikRustProgrammingLanguage2023. These guarantees are enforced at compile time through static analysis, eliminating the runtime overhead of garbage collection while providing memory safety comparable to managed languages.

For a long-running daemon like Lockne's control plane, memory safety is particularly crucial. Traditional C/C++ network daemons are notorious for memory leaks, segmentation faults, and security vulnerabilities arising from memory management errors. A single memory corruption bug could compromise the entire system's security or cause service interruption. Rust's ownership system makes such bugs impossible by construction, providing strong reliability guarantees essential for system-level software.

=== Performance and Zero-Cost Abstractions

Rust's performance characteristics make it ideally suited for systems programming tasks. As a compiled language with sophisticated optimizations, Rust generates machine code comparable to C and C++ in performance. The language's "zero-cost abstractions" principle ensures that high-level programming constructs do not introduce runtime overhead, allowing developers to write expressive, maintainable code without sacrificing performance.

This performance characteristic is essential for Lockne's control plane, which must not become a bottleneck in the packet forwarding path. While the actual packet processing occurs in the kernel through eBPF programs, the control plane must efficiently handle policy updates, process monitoring, and system state management.

=== Modern Concurrency and Async Programming

Rust's approach to concurrency represents a significant advancement over traditional systems programming languages. The ownership system's prevention of data races enables fearless concurrency, where developers can leverage multiple threads and asynchronous programming without typical concerns about race conditions and memory safety.

The async/await syntax in Rust provides ergonomic asynchronous programming capabilities crucial for network services. Lockne's control plane must handle multiple concurrent operations: monitoring process creation and termination, responding to configuration changes, managing eBPF program lifecycle, and communicating with remote endpoints. Rust's async ecosystem, particularly the Tokio runtime, provides efficient scheduling and I/O handling for these concurrent tasks.

=== eBPF Integration: Aya vs. libbpf-rs

Two primary Rust libraries provide eBPF development capabilities: Aya and libbpf-rs. Understanding their differences is crucial for making the right architectural choice for Lockne.

*libbpf-rs* is a set of Rust bindings for the C libbpf library, providing access to the standard eBPF ecosystem. It offers mature, well-tested functionality and compatibility with existing eBPF tools and workflows. The library provides direct access to libbpf's capabilities while adding Rust's memory safety guarantees. However, it requires linking against the C libbpf library and maintaining compatibility with its interface changes.

*Aya* takes a different approach, implementing a pure-Rust eBPF library that doesn't depend on libbpf. This design provides several advantages: simplified deployment without external dependencies, better integration with Rust's type system, and the ability to leverage Rust's safety guarantees throughout the entire codebase. Aya also provides unique features like compile-time verification of eBPF map access patterns and seamless sharing of data structures between userspace and kernel code.

For Lockne, Aya's pure-Rust approach offers significant advantages. The ability to define shared data structures that work in both userspace and eBPF contexts simplifies development and reduces bugs. Additionally, Aya's focus on ergonomic APIs and safety makes it well-suited for developing the kind of complex, policy-driven system that Lockne represents.

// TODO: Add a new section here before "State of the Art"
// === Process-to-Socket Mapping: The Core Challenge (TARGET: 2-3 pages)
// This is THE technical challenge that makes your thesis unique. Write about:
// 1. How Linux kernel tracks socket ownership (task_struct, socket inode numbers)
// 2. Why you can't just "ask" which process owns a packet at TC egress hook
// 3. Different approaches:
//    - SO_MARK socket option and how it works
//    - Socket cookies and their limitations
//    - Cgroup-based tracking (BPF_CGROUP_INET_SOCK_CREATE hook)
//    - Process hierarchy challenges (parent/child processes)
// 4. Performance implications of each approach
// Read: Linux kernel networking code, especially net/socket.c and net/core/sock.c
// Also read existing eBPF networking papers that deal with process identification

// === Performance Considerations and Benchmarking (TARGET: 2 pages)
// Write about:
// 1. What metrics matter: latency (packet processing time), throughput, CPU overhead
// 2. Benchmarking methodologies for networking tools (iperf3, netperf, custom tools)
// 3. Expected bottlenecks in your architecture (map lookups, context switches)
// 4. How to fairly compare kernel-space vs userspace solutions
// Read: Network performance papers, eBPF performance studies

// === Security Model and Threat Analysis (TARGET: 1-2 pages)
// Discuss:
// 1. What threats does Lockne protect against vs introduce?
// 2. eBPF verifier security guarantees
// 3. Privilege requirements and attack surface
// 4. Traffic analysis resistance properties
// Read: eBPF security papers, VPN security analyses

// TODO: Add a new section here before "State of the Art"
// WEEK 2 TASK (Monday-Tuesday): Process-to-Socket Mapping: The Core Challenge
// TARGET: 2-3 pages | PRIORITY: HIGH (this is your main technical contribution)
//
// RESEARCH NEEDED:
// 1. Read Linux kernel source:
//    - net/socket.c (how sockets are created and tracked)
//    - include/linux/net.h (socket structures)
//    - net/core/sock.c (socket ownership tracking)
// 2. Read eBPF networking papers that mention process identification
// 3. Study existing tools: netstat source code, ss command implementation
//
// WHAT TO WRITE ABOUT:
// 1. The fundamental problem:
//    - At TC egress hook, you have an sk_buff (packet) but need to know which process created it
//    - Linux kernel doesn't make this information easily available
//    - Explain why this is harder than it sounds
//
// 2. Existing approaches and their limitations:
//    - SO_MARK socket option: requires application cooperation
//    - Socket cookies: limited lifetime, not reliable for long connections
//    - cgroup-based tracking: requires process hierarchy understanding
//    - Netlink socket monitoring: reactive, not proactive
//
// 3. Your planned solution:
//    - Combination of cgroup hooks and TC hooks
//    - Process creation monitoring with BPF_CGROUP_INET_SOCK_CREATE
//    - Socket-to-process mapping maintenance in eBPF maps
//
// 4. Performance implications:
//    - Map lookup latency for every packet
//    - Memory overhead of maintaining socket mappings
//    - Cleanup challenges for short-lived connections
//
// PAPERS TO FIND AND READ:
// - Search Google Scholar for "eBPF socket tracking"
// - Look for papers on "application-aware traffic engineering"
// - Find any papers that mention SO_MARK or socket cookies
//
// WRITING TIP: Start with the problem statement, then explain why obvious solutions don't work

// TODO: Add another section here
// WEEK 2 TASK (Wednesday-Thursday): Performance Considerations and Benchmarking
// TARGET: 2 pages | PRIORITY: MEDIUM
//
// RESEARCH NEEDED:
// 1. Find eBPF performance papers (search "eBPF performance evaluation")
// 2. Read about network benchmarking methodologies (iperf3, netperf documentation)
// 3. Look up papers comparing kernel-space vs userspace network processing
//
// WHAT TO WRITE ABOUT:
// 1. Metrics that matter for per-application routing:
//    - Packet processing latency (nanoseconds added per packet)
//    - Throughput degradation under load
//    - CPU overhead (% CPU for routing decisions)
//    - Memory overhead (eBPF map sizes)
//
// 2. Benchmarking methodology:
//    - How to measure packet latency in eBPF programs
//    - Controlled test environments
//    - Statistical significance considerations
//
// 3. Expected performance characteristics:
//    - eBPF map lookup performance (hash vs array maps)
//    - Context switch overhead in userspace solutions
//    - WireGuard processing overhead
//
// 4. Comparison framework:
//    - How to fairly compare against proxychains (userspace)
//    - Baseline measurements (no routing)
//    - Different workload types (bulk transfer vs interactive)

// TODO: Add another section here
// WEEK 3 TASK (Wednesday-Thursday): Security Model and Threat Analysis
// TARGET: 1-2 pages | PRIORITY: MEDIUM
//
// RESEARCH NEEDED:
// 1. Read eBPF security papers (verifier guarantees, attack surface)
// 2. Look up VPN security analysis papers
// 3. Find papers on traffic analysis attacks
//
// WHAT TO WRITE ABOUT:
// 1. Security guarantees provided:
//    - eBPF verifier prevents kernel crashes
//    - WireGuard cryptographic properties
//    - Traffic encryption and tunnel security
//
// 2. Security risks introduced:
//    - Privilege escalation through eBPF programs
//    - Information leakage through process tracking
//    - Attack surface of the control plane
//
// 3. Threat model:
//    - What attacks does Lockne defend against?
//    - What new attack vectors might it introduce?
//    - Privilege requirements (root access implications)
//
// 4. Comparison with alternatives:
//    - Security vs usability tradeoffs
//    - Trust model compared to system-wide VPNs

== State of the Art: Analyzing Existing Solutions

The problem of per-application traffic control is not new. Several solutions exist, each with a different approach and a different set of trade-offs. This analysis of the state of the art is crucial for positioning Lockne and justifying its novel architecture.

// TODO: Expand this section significantly (TARGET: 6-8 pages total)
// Add these subsections:

// === Academic Research in Application-Aware Networking (TARGET: 2 pages)
// Cover:
// 1. Software-Defined Networking (SDN) papers on programmable packet processing
// 2. Application-aware QoS research
// 3. Network Function Virtualization (NFV) approaches
// 4. Service mesh research (Istio, Linkerd architectural papers)
// Read: SIGCOMM, NSDI, SOSP papers on programmable networking

// === Enterprise and Commercial Solutions (TARGET: 2 pages)
// Analyze:
// 1. Zero-trust network access (ZTNA) solutions: Zscaler, Okta, etc.
// 2. Split-tunneling in enterprise VPNs (Cisco AnyConnect, Palo Alto GlobalProtect)
// 3. Application delivery controllers (F5, Citrix)
// 4. Why these don't solve the desktop user problem
// Read: Vendor whitepapers, Gartner reports on ZTNA market

// === Linux Networking Subsystem Analysis (TARGET: 2 pages)
// Deep dive into:
// 1. Netfilter/iptables limitations for per-app routing
// 2. Policy routing and multiple routing tables (ip rule, ip route)
// 3. Traffic Control (TC) subsystem architecture and limitations
// 4. Cgroups v1 vs v2 networking capabilities
// Read: Linux networking documentation, "Understanding Linux Network Internals" book

// CURRENT STATUS: Needs major expansion (currently 1 page, need 6-8 pages total)
// This is a critical section for your thesis - shows you understand existing work

// TODO: Add these subsections before the existing content:

// WEEK 3 TASK (Monday-Tuesday): Academic Research in Application-Aware Networking
// TARGET: 2 pages | PRIORITY: HIGH (academic credibility)
//
// RESEARCH NEEDED:
// 1. Search Google Scholar for:
//    - "Software-Defined Networking" + "application awareness"
//    - "programmable packet processing"
//    - "application-aware QoS"
//    - "service mesh" + "traffic routing"
// 2. Look for papers in top conferences: SIGCOMM, NSDI, SOSP, OSDI
// 3. Focus on papers from 2018-2023 (recent work)
//
// WHAT TO WRITE ABOUT:
// 1. Software-Defined Networking (SDN) research:
//    - OpenFlow-based application routing
//    - Programmable switches and application identification
//    - Why SDN solutions don't work for single-host scenarios
//
// 2. Network Function Virtualization (NFV):
//    - Virtual network functions for traffic processing
//    - Service chaining approaches
//    - Performance vs flexibility tradeoffs
//
// 3. Service mesh research:
//    - Istio, Linkerd architectural papers
//    - Sidecar proxy approaches
//    - Container-centric vs process-centric routing
//
// 4. Application-aware QoS:
//    - Deep packet inspection for app identification
//    - Machine learning approaches to traffic classification
//    - Why classification isn't the same as routing control
//
// KEY PAPERS TO FIND:
// - Look for any paper mentioning "per-application" + "traffic control"
// - Find SDN papers that discuss fine-grained traffic engineering
// - Search for eBPF papers in networking contexts

// TODO: Add another subsection
// WEEK 4 TASK (Monday): Enterprise and Commercial Solutions
// TARGET: 2 pages | PRIORITY: MEDIUM (market context)
//
// RESEARCH NEEDED:
// 1. Download and test commercial VPN clients:
//    - Cisco AnyConnect (has split-tunneling)
//    - NordVPN, ExpressVPN (check their split-tunnel features)
// 2. Read about Zero Trust Network Access (ZTNA):
//    - Zscaler Private Access whitepapers
//    - Okta Advanced Server Access
//    - Palo Alto Prisma Access
// 3. Look up Gartner reports on ZTNA market (university library access?)
//
// WHAT TO WRITE ABOUT:
// 1. Enterprise VPN split-tunneling:
//    - How Cisco AnyConnect handles per-app routing
//    - Configuration complexity and management overhead
//    - Why it doesn't work well for desktop users
//
// 2. Zero Trust Network Access (ZTNA) solutions:
//    - Application-centric security models
//    - Agent-based vs agentless approaches
//    - Why they focus on enterprise, not consumer use cases
//
// 3. Application delivery controllers:
//    - F5 BIG-IP, Citrix ADC approaches
//    - Load balancing vs traffic routing differences
//    - Infrastructure vs host-based solutions
//
// 4. Market gap analysis:
//    - Why commercial solutions don't solve your problem
//    - Cost, complexity, target market differences
//    - Desktop user needs vs enterprise requirements

// TODO: Add another subsection
// WEEK 4 TASK (Tuesday): Linux Networking Subsystem Analysis
// TARGET: 2 pages | PRIORITY: HIGH (technical depth)
//
// RESEARCH NEEDED:
// 1. Read "Understanding Linux Network Internals" book (chapters on routing, netfilter)
// 2. Study Linux kernel documentation:
//    - Documentation/networking/policy-routing.txt
//    - Documentation/networking/tc-actions-env-rules.txt
// 3. Experiment with existing Linux tools:
//    - iptables owner matching: iptables -m owner --uid-owner
//    - Policy routing: ip rule add, ip route add table
//    - TC (Traffic Control): tc qdisc, tc filter
//
// WHAT TO WRITE ABOUT:
// 1. Netfilter/iptables limitations:
//    - iptables owner module: can match UID/GID, but not specific processes
//    - Performance implications of complex iptables rules
//    - Why netfilter hooks aren't optimal for packet redirection
//
// 2. Policy routing and multiple routing tables:
//    - How Linux supports multiple routing tables
//    - ip rule for policy-based routing
//    - Limitations: requires manual configuration, not dynamic
//
// 3. Traffic Control (TC) subsystem:
//    - How TC classifiers and actions work
//    - Why existing TC tools don't provide process-level granularity
//    - Performance characteristics of TC vs other approaches
//
// 4. Control Groups (cgroups) networking:
//    - cgroups v1 vs v2 networking capabilities
//    - Network classid and priority controls
//    - Why cgroups alone aren't sufficient for VPN routing
//
// PRACTICAL EXERCISES:
// - Try: iptables -t mangle -A OUTPUT -m owner --uid-owner $(id -u) -j MARK --set-mark 1
// - Try: ip rule add fwmark 1 table 100; ip route add default via [vpn-gateway] table 100
// - Document what works and what doesn't

=== Userspace Proxies: The LD_PRELOAD and DLL Injection Method

The most common approach for desktop applications is seen in tools like Proxifier, proxychains, and tsocks. These solutions work by intercepting network-related system calls within the target application's process space, redirecting them through a proxy connection instead of allowing direct network access.

On Unix-like systems, this interception is typically achieved through the `LD_PRELOAD` mechanism, which allows replacement of shared library functions at runtime. When an application calls network functions like `connect()`, `send()`, or `recv()`, the proxy tool's replacement functions are invoked instead of the system's standard implementations. These replacement functions establish connections through the desired proxy (often SOCKS or HTTP) rather than directly to the target endpoint.

However, this approach suffers from several fundamental limitations. The performance overhead is significant, as every network operation must traverse multiple abstraction layers. Data packets must cross the kernel-userspace boundary multiple times: first when the application makes the initial system call, then when the proxy tool establishes its own connection to the proxy server, and finally when the proxy server forwards the data to its ultimate destination.

The brittleness of this approach presents even more serious concerns. Modern applications increasingly use statically linked libraries, which cannot be intercepted through `LD_PRELOAD` mechanisms. Applications with anti-tampering mechanisms may detect and prevent library preloading attempts. Additionally, applications that bypass standard socket APIs by using raw sockets or custom networking libraries may not be affected by these userspace interception techniques.

// SECTION STATUS: Complete (1 page) ✓
// This section covers the basics well

=== Network Namespaces: The Heavyweight Solution

At the other end of the spectrum is the kernel's native isolation primitive: network namespaces. A network namespace provides a completely separate network stack for processes, including independent network interfaces, routing tables, and firewall rules. This is the fundamental technology underlying container platforms like Docker.

While network namespaces offer complete and reliable traffic control, they are fundamentally ill-suited for dynamic, per-application traffic control in desktop environments. The administrative complexity is substantial, requiring root privileges for namespace creation and management. Each namespace requires manual setup of network interfaces, routing rules, and connectivity policies.

Applications running in separate namespaces cannot easily communicate with services in the root namespace, breaking integration with desktop environments and shared services. The isolation provided by network namespaces is often excessive for simple application routing needs, creating hard boundaries that prevent the kind of selective, transparent routing that desktop users expect.

// SECTION STATUS: Complete (1 page) ✓
// This section covers the basics well

=== System-Wide VPN Solutions: Lack of Granularity

Traditional VPN clients route all system traffic through encrypted tunnels without application-level discrimination. While these solutions excel in providing comprehensive traffic protection, their all-or-nothing approach creates significant usability challenges.

All applications, including those that may require local network access or have incompatibility issues with tunneled connections, are forced through the VPN tunnel. This can break local file sharing, network printing, or applications that require direct connectivity. The performance impact is also substantial for users who only need protection for specific applications, as all traffic consumes VPN server resources and may be subject to geographic latency penalties.

// TODO: Add completely new sections after the existing analysis:

// === Container and Virtualization Approaches (TARGET: 1-2 pages)
// Analyze:
// 1. Docker/Podman networking for app isolation
// 2. systemd-nspawn containers
// 3. Firejail sandboxing approach
// 4. Why full virtualization (VMs) is overkill
// Read: Container networking papers, Docker/Kubernetes networking docs

// === Cross-Platform Considerations (TARGET: 1 page)
// Discuss:
// 1. Why this is fundamentally Linux-specific (eBPF)
// 2. Windows alternatives: WinDivert, Winsock LSP, WFP (Windows Filtering Platform)
// 3. macOS Network Extensions framework
// 4. Why cross-platform solutions compromise on performance/features
// Read: Platform-specific networking documentation

// === Emerging Technologies and Future Directions (TARGET: 1 page)
// Cover:
// 1. QUIC protocol implications for traffic routing
// 2. eBPF evolution: upcoming kernel features
// 3. Hardware acceleration trends (XDP, smart NICs)
// 4. Cloud-native networking evolution
// Read: Recent IETF RFCs, kernel development mailing lists

// TODO: Add completely new sections after the existing analysis:

// WEEK 4 TASK (Wednesday): Container and Virtualization Approaches
// TARGET: 1-2 pages | PRIORITY: MEDIUM
//
// RESEARCH NEEDED:
// 1. Try Docker/Podman networking for app isolation:
//    - docker run --network=none --name isolated-app firefox
//    - Study how container networking works
// 2. Look up systemd-nspawn documentation and examples
// 3. Research Firejail sandboxing (security-focused approach)
//
// WHAT TO WRITE ABOUT:
// 1. Docker/Podman networking approaches:
//    - How containers solve traffic isolation
//    - Performance overhead of container networking
//    - User experience issues (X11, audio, file access)
//
// 2. Lightweight containerization:
//    - systemd-nspawn as alternative to full containers
//    - Firejail's approach to sandboxing with network control
//    - Why these are still too heavyweight for casual use
//
// 3. Virtual machines:
//    - Ultimate isolation but extreme resource overhead
//    - Use cases where VMs make sense vs overkill
//
// 4. Analysis of why containerization doesn't solve your problem:
//    - Resource overhead, complexity, user experience issues
//    - Desktop integration challenges

// WEEK 4 TASK (Thursday): Cross-Platform Considerations
// TARGET: 1 page | PRIORITY: LOW (but good for completeness)
//
// RESEARCH NEEDED:
// 1. Read about Windows networking APIs:
//    - WinDivert library documentation
//    - Winsock Layered Service Providers (LSP)
//    - Windows Filtering Platform (WFP)
// 2. Look up macOS Network Extensions framework
// 3. Find papers comparing cross-platform networking approaches
//
// WHAT TO WRITE ABOUT:
// 1. Why Lockne is fundamentally Linux-specific:
//    - eBPF is Linux-only technology
//    - Kernel-level packet filtering varies by OS
//
// 2. Windows alternatives and their limitations:
//    - WinDivert: userspace packet capture (performance penalty)
//    - LSP: deprecated, security issues
//    - WFP: complex, requires driver development
//
// 3. macOS Network Extensions:
//    - App-centric filtering capabilities
//    - Sandbox restrictions and user experience
//
// 4. Why cross-platform solutions compromise:
//    - Lowest common denominator approaches
//    - Performance vs portability tradeoffs

// WEEK 4 TASK (Friday): Emerging Technologies and Future Directions
// TARGET: 1 page | PRIORITY: LOW (shows you're thinking ahead)
//
// RESEARCH NEEDED:
// 1. Read about QUIC protocol and its implications
// 2. Follow Linux kernel mailing list for upcoming eBPF features
// 3. Look up hardware acceleration trends (XDP, smart NICs)
//
// WHAT TO WRITE ABOUT:
// 1. Protocol evolution impact:
//    - QUIC's connection migration affects process tracking
//    - HTTP/3 over QUIC implications for traffic classification
//
// 2. eBPF evolution:
//    - Upcoming kernel features that could benefit Lockne
//    - Better process tracking primitives in development
//
// 3. Hardware acceleration trends:
//    - XDP and smart NIC capabilities
//    - How hardware offload might change the landscape
//
// 4. Cloud-native networking evolution:
//    - How container networking trends might influence desktop solutions

== Synthesis: Identifying the Architectural Gap

The preceding analysis reveals a clear gap in the landscape of traffic control tools. Users are forced to choose between performant but inflexible system-wide VPNs, complex and heavyweight containerization, or user-friendly but slow and brittle userspace proxies.

There is no solution that provides the performance of in-kernel routing with the user-friendly, dynamic, per-application granularity of a userspace tool. Existing approaches either sacrifice performance for flexibility (userspace proxies), sacrifice flexibility for performance (system-wide VPNs), or introduce excessive complexity (network namespaces).

Lockne is designed to fill this specific gap. By combining the performance of eBPF for packet redirection with the proven security of WireGuard and a modern Rust control plane, it aims to offer the best of all worlds: kernel-level performance with application-level control. The architecture leverages each technology's strengths while mitigating their individual limitations, creating a solution that is simultaneously high-performance, secure, and user-friendly.
