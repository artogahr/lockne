= Literature Review

Before designing and building Lockne, it is essential to understand the technologies that make it possible and the context in which it will operate. This review surveys the technical landscape, focusing on the three pillars of the project: the eBPF framework for kernel programmability, the WireGuard protocol for secure and performant tunneling, and the Rust language for building a reliable control plane. Critically, it also analyzes existing approaches to application-specific traffic control, identifying their limitations. The goal is to establish a clear justification for Lockne's architecture by demonstrating how it addresses a distinct gap left by current solutions.

== The Kernel's New Superpower: An Overview of eBPF

The core mechanism behind Lockne is the extended Berkeley Packet Filter (eBPF). To understand its importance, one must see it not just as a tool, but as a fundamental shift in how the Linux kernel can be extended. As described by Brendan Gregg, eBPF allows sandboxed programs to run directly within the kernel in response to specific events, without requiring changes to the kernel source code or loading kernel modules @greggBpfPerformanceTools2019. This provides a safe, performant way to implement custom logic at the lowest levels of the operating system. He's also described eBPF as "like putting JavaScript into the Linux kernel" @EBPFDocumentary.

=== Life without eBPF

To understand eBPF's importance here, it helps to look at how an application similar to Lockne would be implemented without it. To "catch" packets before they leave the network interface, we need some sort of mechanism either inside or outside the kernel (who is ultimately responsible for the packet routing). Since the Linux kernel is open-source, one way to do this could be to add additional code inside the Linux kernel's network handling parts, recompile the kernel, and boot with it. This approach is obviously not ideal, and infeasible to expect from the end-user. A second similar (but much more realistic) approach could be to write a loadable kernel module (LKM), which is a pre-compiled binary that can provide additional capabilities to a running kernel. Most operating systems have some sort of dynamic module system implemented, but they often are hard to develop for, hard to ensure compatibility, and easy to break (which may potentially take down the whole operating system with it). One of the design goals for Lockne is transparency, therefore it should never crash the host system. And lastly, you can write a user space application, which would be easier to develop for and be much safer, but this entails eating the performance penalty of having to copy packets to-and-from the kernel space. 

None of these solutions are ideal for our use case, but thankfully modern eBPF implementation in the Linux kernel allows us to implement Lockne without any of the mentioned problems. 

=== From Packet Filtering to In-Kernel Virtual Machine

The original Berkeley Packet Filter (BPF), often called classic BPF (cBPF), was designed in the 1990s with a single purpose: to filter network packets efficiently in userspace tools like `tcpdump`. It was a simple, register-based virtual machine that could decide whether to accept or drop a packet. Imagine putting simple "if statements" in the processing path of every network packet, which decided if the packet passes through, or is dropped. 

eBPF (extended BPF), introduced in 2014, is a complete redesign. It expands the original concept into a general-purpose, 64-bit virtual machine inside the kernel. Despite the names being similar, it can work with much more than just network packets. As Liz Rice explains in _Learning eBPF_, it's more than just a filter; it's a tool for building a wide range of networking, security, and observability applications @riceLearningEBPFProgramming2023. Using eBPF binaries dynamically loaded in the kernel using the `bpf()` system call, we can attach to and manipulate data from almost any event that happens within the Linux kernel. In practice, this will let us to attach to the network data path, in which we can read every packet, see if we're interested in it, and route it to some other place if necessary. 

Before any eBPF program is loaded, it must pass through a strict in-kernel verifier. This verifier statically analyzes the program's code, checking for out-of-bounds memory access, infinite loops, and illegal instructions. This verification step is what makes eBPF safe to run in the kernel, a critical feature that distinguishes it from traditional kernel modules which can easily crash the entire system.

Furthermore, being implemented directly in the kernel, eBPF programs don't have the usual performance constraints of having to route the packets through the user space. We will see examples of this in the "Analyzing Existing Solutions" section. For extreme use cases, modern eBPF programs also support eXpress Data Path (XDP), which lets us run the eBPF filtering _directly in the network interface card driver_, bypassing most of the OS networking stack. //TODO are we going to use XDP?

//TODO: tag the section properly 

#pagebreak()
=== Core Components for Lockne: Programs, Maps, and Hooks

To build a system like Lockne, we must use three key eBPF concepts:

- *Hooks:* These are well-defined points in the kernel's code path where an eBPF program can be attached. For network-related tasks, the most important hooks are on the Traffic Control (TC) subsystem and on control groups (cgroups). By attaching a program to a TC hook on a network interface, we can inspect and manipulate every packet that passes through it. This is the primary mechanism Lockne will use to redirect traffic.

- *Programs:* An eBPF program is the actual code that runs at a hook. For Lockne, the TC program will look at a packet, determine which process created it, and decide whether to send it to a WireGuard tunnel or let it pass through the default route.

- *Maps:* Maps are the communication bridge. They are efficient key-value data structures that can be accessed from both eBPF programs running in the kernel and from userspace applications. For Lockne, maps are the "brain" of the operation. The Rust daemon will write routing policies (e.g., "PID 1234 -> WireGuard interface A") into a map. The eBPF program in the kernel will then read from this map to make its routing decisions in real-time. This allows for dynamic policy updates without reloading the kernel program.

== Secure and Performant Tunneling: The WireGuard Protocol

Lockne does not just redirect traffic; it routes it into a secure tunnel. The choice of VPN protocol is therefore critical. This section reviews WireGuard, arguing that its design philosophy of simplicity, high performance, and tight kernel integration makes it the ideal foundation for Lockne's tunneling component.

WireGuard's design is centered on an aggressive pursuit of simplicity. The entire protocol is implemented in approximately 4,000 lines of C code, excluding cryptographic primitives (@donenfeldWireGuardNextGeneration2017). This minimalist codebase, estimated to be two orders of magnitude smaller than that of OpenVPN or IPsec solutions, dramatically reduces the potential attack surface and simplifies security auditing (@salterWireGuardVPNReview2018). This focus on a minimal, auditable design has been validated by multiple professional security audits. The simplicity extends to its operation, which uses a constrained and well-defined state machine. For the end-user, this results in a seamless "it just works" experience where tunnels are established transparently using a simple exchange of public keys. This philosophy is a core inspiration for Lockne's own design goals.

This simplicity directly enables WireGuard's second key advantage: performance. Unlike popular userspace protocols like OpenVPN, which must repeatedly copy packets between the kernel and a userspace process for encryption and decryption, WireGuard operates directly within the Linux kernel. By eliminating this context-switching overhead for every packet, it achieves significantly higher throughput and lower latency. While other in-kernel protocols like IPsec exist, WireGuard often maintains a performance edge by leveraging more modern, efficient cryptographic algorithms. This kernel-native architecture is the crucial feature for Lockne; it allows packets redirected by an eBPF program to be handed directly to the WireGuard interface within the kernel, creating the most efficient path possible from application to secure tunnel.

== A Foundation of Safety and Performance: The Role of Rust

While eBPF provides the mechanism for kernel-level redirection, a robust and reliable userspace control plane is required to manage policies, monitor processes, and configure network interfaces. The choice of programming language for this component is a critical architectural decision. Lockne is implemented in Rust, a modern systems programming language that provides a unique combination of performance and safety, making it exceptionally well-suited for this task.

// TODO (Your Task): Write 2-3 paragraphs here explaining WHY Rust is the right choice.
// 1. **Memory Safety without a Garbage Collector:** This is the most important point. Explain Rust's ownership and borrow checker. How does it prevent entire classes of bugs (like segfaults, data races) that are common in C/C++? Why is this crucial for a long-running daemon that interacts with the kernel?
// 2. **Performance:** Mention that Rust is a compiled language that offers performance comparable to C and C++, which is essential for an efficient control plane that must not become a bottleneck itself.
// 3. **Modern Concurrency:** Briefly explain how Rust's features (like `async/await` and ownership rules) make it easier to write correct concurrent code. This is relevant for a daemon that might need to handle user input, process events, and manage network state simultaneously.
// 4. **Rich Ecosystem:** Mention the role of `crates.io` and specifically the `aya` library, which provides safe, ergonomic bindings for writing eBPF applications in Rust, directly enabling the development of Lockne.

#pagebreak()
// === NEW SECTION 2 ===
== State of the Art: Analyzing Existing Solutions

The problem of per-application traffic control is not new. Several solutions exist, each with a different approach and a different set of trade-offs. This analysis of the state of the art is crucial for positioning Lockne and justifying its novel architecture.

=== Userspace Proxies: The `LD_PRELOAD` and DLL Injection Method
The most common approach for desktop applications is seen in tools like Proxifier or proxychains. This section will detail their mechanism and inherent limitations.

// TODO (Your Task): Write 2-3 paragraphs here.
// 1. Research how Proxifier/proxychains work. (Hint: They use techniques like `LD_PRELOAD` on Linux or DLL injection on Windows to hijack network-related function calls like `connect()`, `send()`, and `recv()` inside a specific application).
// 2. Explain the major drawbacks:
//    - Performance Overhead: Data has to cross the kernel-userspace boundary multiple times.
//    - Brittleness: Can fail with statically linked applications or apps with anti-tamper mechanisms.
//    - Incomplete Coverage: May not capture all types of network traffic (e.g., raw sockets).

=== Network Namespaces: The Heavyweight Solution
At the other end of the spectrum is the kernel's native isolation primitive: network namespaces. While powerful, they are ill-suited for Lockne's use case.

// TODO (Your Task): Write 2 paragraphs here.
// 1. Briefly explain what a network namespace is (a completely separate network stack for a process). This is what Docker uses.
// 2. Explain why this is not a good solution for dynamically routing a single desktop app. (e.g., "Administration is complex, requiring root privileges and manual configuration. It does not integrate well with a user's main desktop session, as applications in a separate namespace cannot easily communicate with services in the root namespace.")

// === NEW SECTION 3 ===
== Synthesis: Identifying the Architectural Gap

The preceding analysis reveals a clear gap in the landscape of traffic control tools. Users are forced to choose between performant but inflexible system-wide VPNs, complex and heavyweight containerization, or user-friendly but slow and brittle userspace proxies.

// TODO (Your Task): Write 1-2 paragraphs here. This is your conclusion.
// 1. Summarize the problem: "There is no solution that provides the performance of in-kernel routing with the user-friendly, dynamic, per-application granularity of a userspace tool."
// 2. State your thesis clearly: "Lockne is designed to fill this specific gap. By combining the performance of eBPF for packet redirection with the proven security of WireGuard and a modern Rust control plane, it aims to offer the best of all worlds: kernel-level performance with application-level control."
