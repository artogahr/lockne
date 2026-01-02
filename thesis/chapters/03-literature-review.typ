= Literature Review

Before designing and building Lockne, it is essential to understand the technologies that make it possible and the context in which it will operate. This review surveys the technical landscape, focusing on the three pillars of the project: the eBPF framework for kernel programmability, the WireGuard protocol for secure and performant tunneling, and the Rust language for building a reliable control plane. Critically, it also analyzes existing approaches to application-specific traffic control, identifying their limitations. The goal is to establish a clear justification for Lockne's architecture by demonstrating how it addresses a distinct gap left by current solutions.

== The Kernel's New Superpower: An Overview of eBPF

The core mechanism that makes Lockne possible is the extended Berkeley Packet Filter (eBPF). To understand its importance, one must see it not merely as a tool, but as one of the most significant architectural shifts in the Linux kernel in the last decade. It represents a move away from a monolithic kernel with a fixed set of features toward a more programmable and extensible operating system. As described by Brendan Gregg, eBPF allows sandboxed programs to run directly within the kernel in response to specific events, without requiring changes to the kernel source code or loading potentially unstable kernel modules @greggBpfPerformanceTools2019. This provides a safe, performant, and dynamic way to implement custom logic at the lowest levels of the operating system. He has also evocatively described eBPF as being "like JavaScript for the Linux kernel," a comparison that highlights its event-driven nature and its role in making a traditionally static component programmable @EBPFDocumentary.

=== Life without eBPF: The Old Ways of Kernel Extension

To appreciate the paradigm shift that eBPF represents, it is useful to consider how a system like Lockne would have been implemented before its existence. Intercepting and manipulating network packets requires executing logic within the kernel's address space. Historically, there were only a few, highly challenging ways to achieve this:

- *Modifying the Kernel Source:* The most direct method would be to add the desired logic directly into the Linux kernel's networking code, recompile the entire kernel, and reboot the system with this custom version. This approach offers the highest performance but is entirely impractical for deployable software. It is complex, error-prone, and would require every end-user to become a kernel developer.

- *Loadable Kernel Modules (LKMs):* A far more realistic, though still perilous, approach is to write an LKM. LKMs are compiled objects of code that can be dynamically inserted into the running kernel, granting them the ability to extend its functionality. Most device drivers in Linux are implemented as LKMs. However, this power comes with immense risk. An LKM operates with the full privileges of the kernel; a single bug, such as a null pointer dereference, can and often does result in an immediate kernel panic, crashing the entire operating system. Developing, testing, and maintaining LKMs across different kernel versions is a notoriously difficult task, making them unsuitable for Lockne's design goals of safety and stability.

- *Userspace Proxies:* The safest, but slowest, method is to avoid in-kernel execution entirely. A userspace application can request that the kernel forward certain packets to it for processing. This, however, incurs a significant performance penalty due to the overhead of context switching, where data must be repeatedly copied across the kernel-userspace boundary for every single packet. As will be detailed in the "State of the Art" analysis, this overhead is precisely what Lockne aims to eliminate.

eBPF was created to provide a new option, one that offers the performance of in-kernel execution with safety guarantees that approach those of userspace applications.

=== From Packet Filtering to an In-Kernel Virtual Machine

The original Berkeley Packet Filter (BPF), now often called classic BPF (cBPF), was designed in the 1990s @mccanne1993bsd with a single purpose: to filter network packets efficiently for userspace tools like `tcpdump`. It was a simple, register-based virtual machine that could make a quick decision on whether to accept or drop a packet.

eBPF, introduced in 2014, is a complete redesign and generalization of this concept. It expands the original architecture into a general-purpose, 64-bit RISC-like virtual machine that runs inside the kernel. At its heart is an instruction set architecture (ISA) with eleven 64-bit registers, a program counter, and a 512-byte stack. eBPF programs are compiled from a restricted form of C into this instruction set.

The most critical component of the eBPF architecture is the in-kernel *verifier*. Before any eBPF program is loaded, it must pass an exhaustive static analysis by this verifier @gershuni2019simple. The verifier checks for a multitude of safety properties:
- It ensures the program is a directed acyclic graph (DAG), guaranteeing that it will terminate and not contain infinite loops that could lock up the kernel.
- It performs sophisticated data flow analysis to ensure that no pointers are used before being checked for `NULL`.
- It validates all memory access, preventing out-of-bounds reads or writes to both the eBPF stack and any data from the kernel.

Only if a program is proven by the verifier to be safe to run is it permitted to be loaded. It is then often passed to a Just-In-Time (JIT) compiler that translates the eBPF bytecode into native machine code for maximum performance. This verification step is the fundamental feature that distinguishes eBPF from LKMs and makes it safe to run untrusted code in a privileged context.

=== The Three Pillars of eBPF: Usecase Domains

While its origins are in networking, eBPF's general-purpose design has led to its adoption across three major domains, showcasing its versatility. Lockne is primarily a networking application, but understanding the other use cases provides a crucial context for the technology's importance.

==== High-Performance Networking
This remains eBPF's primary domain. It is used to implement load balancers, Distributed Denial of Service (DDoS) mitigation, and complex virtual networking for container orchestration.
- *XDP (eXpress Data Path)* programs provide the highest possible performance, running directly in the network driver. They are ideal for use cases like DDoS mitigation, where millions of malicious packets per second can be dropped before they consume significant system resources.
- *TC (Traffic Control)* programs, as used by Lockne, run later in the networking stack. While slightly slower than XDP, they have access to more packet metadata, making them ideal for more complex routing and policy decisions. Projects like the Cilium CNI for Kubernetes are built almost entirely on eBPF's networking capabilities.

==== Granular System Observability
Because eBPF programs can be attached to a vast array of kernel hooks, they are an incredibly powerful tool for deep system introspection with minimal overhead.
- *kprobes* and *tracepoints* allow developers to attach eBPF programs to kernel function calls or static markers, respectively. This enables the creation of powerful performance analysis tools. For example, a tool like `opensnoop` from the BCC toolkit uses eBPF to trace every file `open()` system call on the system in real-time, showing which process is opening which file.
- *perf_events* allow eBPF programs to be triggered on hardware or software performance counters, enabling sophisticated CPU profiling and performance analysis.

==== Proactive Security Enforcement
The ability to see and react to system events makes eBPF a natural fit for security tooling.
- *LSM (Linux Security Module)* hooks allow eBPF programs to be used to implement mandatory access control policies. Traditionally, security modules like AppArmor or SELinux were large, monolithic, and had to be compiled with the kernel. eBPF allows for more granular, dynamically loadable security policies that can, for instance, prevent a specific application from accessing certain files or making network connections. Projects like Falco use eBPF to capture system call data for security monitoring and intrusion detection.

=== The eBPF Ecosystem and Toolchain Evolution

The growth of eBPF has been accompanied by a rapid evolution in the tools and libraries used to write, compile, and load eBPF programs. The choice of toolchain has significant implications for a project's complexity, dependencies, and portability. While early frameworks like BCC required on-host compilation with heavy dependencies, the modern workflow revolves around the principle of "Compile Once - Run Everywhere" (CO-RE), enabled by BTF (BPF Type Format). For developers building eBPF applications in Rust, two primary ecosystems have emerged that embrace this modern philosophy, though they do so in fundamentally different ways.

==== The `libbpf` Ecosystem: A Bridge to C

The standard, canonical way to load and manage eBPF programs from C/C++ applications is the `libbpf` library, which is co-developed with the Linux kernel itself. The `libbpf-rs` crate provides safe, idiomatic Rust bindings to this underlying C library.

This approach is mature and battle-tested. It allows a Rust userspace application to leverage the full power of the CO-RE loader developed by the kernel community. However, a typical `libbpf-rs` project maintains a strong link to the C toolchain: the eBPF programs themselves are typically written in C and compiled with Clang, while only the userspace loader is written in Rust.

During the initial design phase of Lockne, this path was considered. However, it was ultimately rejected as it would require managing two different languages and build systems, and would necessitate fragile coordination to ensure that data structures shared between C and Rust had identical memory layouts. Furthermore, it would introduce a dependency on the C `libbpf` library being present on the target system.

==== The `Aya` Ecosystem: A Pure-Rust Implementation

For these reasons, the final decision was to build Lockne using `Aya`. `Aya` takes a radically different and more ambitious approach. It is a complete eBPF toolchain and library implemented *entirely in Rust*. It does not depend on `libbpf` or any other C libraries. This pure-Rust philosophy is not merely an aesthetic choice; it provides several powerful, concrete advantages that make it the ideal choice for this project:

1. *A Unified Language and Build System:* Both the in-kernel eBPF program and the userspace loader are written in Rust. This provides a seamless development experience within a single, powerful language and its unified build system, Cargo.

2. *Enhanced Safety and Ergonomics:* By controlling the entire toolchain, Aya can provide guarantees that are impossible in a mixed-language setup. Its most significant feature is the ability to define data structures (such as those for shared maps) in a common Rust crate. Through procedural macros, Aya ensures at compile time that the memory layout is identical between the kernel and userspace components. This eliminates an entire class of common and frustrating bugs related to data serialization and memory alignment.

3. *Simplified Deployment:* An Aya-based application like Lockne can be built into a self-contained binary. There is no need to ensure that a specific version of the `libbpf` C library is installed on the target machine, which dramatically simplifies packaging and deployment.

4. *First-Class BTF Integration:* The `Aya` toolchain has deeply integrated support for BTF. This is leveraged during the build process, where build scripts can invoke `bpftool` to automatically generate Rust type bindings for kernel structures. This provides type-safe, portable access to kernel data, a significant improvement over manually defining structs from C header files.

This choice was not without its own challenges. As a younger project, `Aya`'s documentation, while improving, can be less comprehensive than the decades of material available for `libbpf`. At times, solving complex problems required a deeper dive into the library's source code. Despite this, the overwhelming benefits of a pure-Rust toolchain—improved compile-time safety, a simpler build process, and truly idiomatic data sharing—made `Aya` the clear and superior choice. It aligns perfectly with Lockne's core principles of building a secure, reliable, and maintainable system by leveraging the full power of the Rust language across the entire application stack.

=== The eBPF Programming Model: Hooks, Programs, and Maps

The architecture of an eBPF-based system is fundamentally different from that of a traditional application. It is not a single, monolithic program but a distributed system of small, event-driven components that run within the kernel. This model is built on three foundational concepts: Hooks, Programs, and Maps. A thorough understanding of how these elements interoperate is crucial for designing any non-trivial eBPF utility and for justifying the specific architectural choices made in Lockne.

==== Hooks: Kernel Points of Interception

An eBPF program cannot run on its own; it must be attached to a "hook," a specific, predefined point in the kernel's execution path. When the kernel's code arrives at a hook, it temporarily gives control to the attached eBPF program, allowing it to execute its logic in response to a specific system event. The choice of hook determines the context and capabilities available to the program. While the eBPF ecosystem offers a vast array of hooks for observability and security (such as tracepoints, kprobes, and LSM hooks), networking-centric applications like Lockne primarily leverage hooks within the networking stack.

For Lockne's architecture, two specific hooks are essential:

1. *The Traffic Control (TC) Hook:* Located in the kernel's packet scheduling subsystem, the TC hook is one of the final stages a packet passes through before being transmitted by the network interface driver. Attaching a program to the `egress` (outgoing) path of a network interface provides a powerful vantage point for inspecting, manipulating, or redirecting every packet leaving the system. This makes it the ideal location for implementing Lockne's core packet routing logic.

2. *The Control Group (cgroup) Socket Hook:* Cgroups are a core Linux mechanism for resource management and process grouping. The kernel provides hooks that allow eBPF programs to trigger on various activities performed by processes within a cgroup. The `sock_addr` hook, for instance, is invoked whenever a process performs a socket-related system call like `connect()` or `sendmsg()`. This hook provides a reliable and efficient mechanism for observing the creation of network connections on a per-process basis, which is fundamental to Lockne's ability to map traffic to specific applications.

==== Programs: Specialized, Event-Driven Logic

An eBPF program is the compiled code that executes when a hook is triggered. The kernel defines numerous program types, each tailored to the specific context of its associated hooks. A program's type dictates its input arguments, its expected return values, and the set of eBPF helper functions it is permitted to call. While many program types exist, Lockne's design requires the coordinated use of two distinct types.

- *The Classifier (`tc`) Program:* This is the program type designed to attach to Traffic Control hooks. Its function is to "classify" packets and return a verdict that determines their fate. It receives the packet's data and metadata within a `TcContext` structure. Its return value is an integer code representing an action, such as `TC_ACT_OK` to permit the packet to pass unmodified, or `TC_ACT_SHOT` to drop it. The most critical capability for Lockne is its access to the `bpf_redirect()` helper function, which allows the program to forward the packet to a different network interface—the core mechanism for tunneling traffic. A key practical requirement for `tc` programs is the presence of a `clsact` queuing discipline (qdisc) on the target network interface. This special qdisc serves as a container for classifier programs, providing the necessary attachment points on the ingress and egress paths.

- *The Socket Operation (`cgroup/sock_addr`) Program:* This program type attaches to the cgroup socket hooks. Unlike `tc` programs, its primary purpose is not packet manipulation but rather process-level event handling. It runs within a context that provides access to information about the socket being operated on, as well as the identity of the process performing the operation, including its Process ID (PID). This makes it the ideal tool for implementing the "process-to-socket mapping" logic. Its role in Lockne is not to filter traffic directly, but to act as an information gatherer, creating the necessary metadata that the `tc` program will later use to make its routing decisions.

- *Alternative Program Types Considered:* Other networking-related program types were considered and rejected for Lockne's core logic. The *eXpress Data Path (XDP)* program type, for example, offers the highest possible performance by running directly within the network driver, even before the kernel allocates the main `sk_buff` structure. However, XDP's early execution point means it lacks access to much of the socket-level context (like the socket cookie) needed for process identification, making it unsuitable for Lockne's specific goals. Similarly, *Socket Filter* programs can filter traffic for a single socket but are ill-suited for implementing system-wide routing policies. The combination of `tc` and `cgroup/sock_addr` provides the best balance of performance and contextual awareness for per-application traffic routing.

==== Maps: The In-Kernel State Store

The various eBPF programs attached to different hooks operate independently and cannot communicate directly. The bridge that connects them and allows them to share state is the eBPF Map. Maps are highly efficient key-value data structures that reside within the kernel. They are a fundamental component of any complex eBPF application, enabling stateful logic and communication between the kernel and userspace.

Maps serve three critical roles in the Lockne architecture:
1. *Inter-Program Communication:* The `cgroup/sock_addr` program *writes* process and socket information into a map. The `tc` program later *reads* this information from the same map to make an informed routing decision. This turns a stateless packet hook into a stateful, process-aware filtering point.
2. *Kernel-Userspace Communication:* The Rust control plane running in userspace can create, update, and read from eBPF maps. This is the primary mechanism for configuring Lockne's policies. The userspace daemon writes rules (e.g., "route PID 12345 through WireGuard") into a policy map, which the eBPF programs can then enforce in real-time.
3. *State Management:* Maps hold the state of the system, such as the active mappings between sockets and processes. This allows the system to function correctly across the entire lifetime of a network connection.

This modular architecture—using specialized programs at different hooks and coordinating them through shared maps—is a powerful and efficient paradigm. It allows the computationally intensive work of process identification to be performed only once at the beginning of a connection, enabling the per-packet routing logic on the critical data path to be extremely fast and lightweight.

== Secure and Performant Tunneling: The WireGuard Protocol

Lockne's architecture redirects application traffic; it does not, by itself, encrypt it. The second critical part of the data plane is the secure tunnel into which this traffic is directed. The choice of VPN protocol is therefore very important, directly impacting the performance, security, and usability of the entire system. Lockne is designed specifically to integrate with WireGuard, arguing that its modern design philosophy, minimalist attack surface, and tight kernel integration make it the ideal foundation for the project's tunneling component. While it would be nice to have the ability to perform this functionality for all VPN types (or even all possible network interfaces), limiting the scope to Wireguard also helps simplify the implementation.

This analysis delves into the specific architectural decisions of WireGuard that justify this choice, contrasting them with the trade-offs made by older, more established protocols.

=== An Aggressive Pursuit of Simplicity

At its core, WireGuard's design is guided by a strong focus on simplicity. This is most clear in its codebase. The entire kernel-resident implementation consists of around 4,000 lines of C code, a figure that seems minimal when compared to the hundreds of thousands of lines that make up alternatives like OpenVPN or the IPsec suite @donenfeldWireGuardNextGeneration2017.

This is not just an aesthetic choice; it is a fundamental security principle. A smaller codebase dramatically reduces the potential attack surface and makes a full security audit not just possible, but practical @salterWireGuardVPNReview2018. The complexity of a system is a direct enemy of its security. With fewer lines of code, there are fewer places for subtle bugs to hide. This simplicity extends to its state management. WireGuard gets rid of the complex, multi-stage handshake protocols common in other VPNs. There is no concept of a user "connecting" or "disconnecting." If a peer has the correct public key, it can send encrypted data; if not, the interface stays silent, not even responding to unknown packets. This "stealthy by default" behavior makes WireGuard servers difficult to scan for online, further reducing their exposure. For the end-user, this means tunnels are established transparently and reliably, which aligns perfectly with Lockne's goal of being easy to use.

=== Kernel-Native Performance

WireGuard's second key advantage is its raw performance. This is a direct result of its design as a native Linux kernel module. Popular VPNs like OpenVPN operate mostly in userspace. For every single network packet to be encrypted, it must take an expensive journey:
1. The packet is created by an application and given to the kernel.
2. The kernel's networking stack sends it to a virtual `tun` interface.
3. The packet is copied from the kernel to the OpenVPN userspace program.
4. The OpenVPN program encrypts the packet.
5. The now-encrypted packet is copied back to the kernel.
6. The kernel sends this new packet out the physical network interface.

This back-and-forth, known as context switching, happens for every packet and creates a major performance bottleneck. WireGuard avoids this entirely. Because it lives inside the kernel, packets sent to the WireGuard interface are encrypted and sent on their way without ever leaving the kernel's high-performance environment. This is the key synergy for Lockne: packets redirected by our eBPF program can be handed directly to the WireGuard interface, creating the most efficient path possible from an application to a secure tunnel. This in-kernel design allows WireGuard to achieve much higher throughput and lower latency, making it great for high-bandwidth activities that would be too slow over a traditional VPN.

=== Opinionated Cryptography

Many security problems in the past came from flawed or outdated cryptography. Older protocols like IPsec and TLS were often designed with "crypto-agility," meaning they support a long list of encryption algorithms that can be negotiated between peers. While flexible, this is a common source of weakness. It opens the door to downgrade attacks, where an attacker tricks two sides into using an older, weaker algorithm.

WireGuard rejects this model. Instead, it is "opinionated" and uses a single, fixed set of modern, high-speed cryptographic primitives: Curve25519 for key exchange, ChaCha20 for symmetric encryption @rfc7539, Poly1305 for authentication, and BLAKE2s for hashing @donenfeldWireGuardNextGeneration2017. There is no negotiation to attack. This rigidity eliminates entire classes of vulnerabilities. If a flaw were ever found in one of the primitives, the solution would be to create a new version of the WireGuard protocol itself. This philosophy provides a much stronger promise of security over the long term and ensures that all tunneled traffic benefits from state-of-the-art protection without complex setup.

=== Architectural Synergy: A Natural Fit for eBPF Redirection

Beyond its standalone features, WireGuard's design as a kernel network interface makes it uniquely suited for a modern eBPF-based system like Lockne. The critical link between the two technologies is a powerful eBPF helper function: `bpf_redirect()`.

The Linux kernel identifies every network interface (like `eth0` or `wlan0`) with a simple, unique number called an interface index, or `ifindex`. The `bpf_redirect()` function allows an eBPF program to take a packet it is processing and, instead of letting it continue on its original path, immediately forward it to the `ifindex` of another interface.

This mechanism is the core of Lockne's data plane. The process works as follows:
- The Lockne userspace daemon identifies the `ifindex` of the target WireGuard interface (e.g., `wg0`).
- It places this `ifindex` into an eBPF map, linking it to a specific application or process.
- When the eBPF program in the kernel intercepts a packet from that application, it looks in the map, retrieves the `ifindex`, and calls `bpf_redirect()`.
- The packet is instantly handed off to the WireGuard interface, all without leaving the kernel.

This direct, in-kernel handoff is what makes the combination of eBPF and WireGuard so efficient. It avoids all the overhead of userspace proxies and provides a clean, programmable way to selectively push traffic into the secure tunnel.

=== Comparison with Established VPN Protocols

To understand WireGuard's importance, it is helpful to contrast it with the protocols that came before it.

- *IPsec:* The Internet Protocol Security suite @rfc4301 is the "enterprise standard" for securing network traffic. While powerful, IPsec is known for being very complex. It is not a single protocol but a large framework of many components. This complexity makes it difficult to configure correctly, and mistakes can easily lead to security holes @fergusonPracticalCryptography2003. WireGuard's simplicity is a direct response to this legacy of complexity.

- *OpenVPN:* As a userspace tool built on the OpenSSL library, OpenVPN has been a reliable choice for years @zhengjun2007openvpn. Its main benefit is its ability to run over TCP, which can help bypass restrictive firewalls. However, as noted earlier, its userspace design comes with a significant performance cost. Its configuration is also far more complex than WireGuard's, presenting a larger attack surface.

In this context, WireGuard is a major step forward. It provides the in-kernel performance that was once only available with complex IPsec setups, but with a level of simplicity and security that surpasses even userspace tools.

=== Synthesis: The Ideal Tunnel for an eBPF Data Plane

The design of WireGuard aligns perfectly with the goals of Lockne. Its in-kernel nature provides the high-performance path needed to ensure that the redirection performed by eBPF does not create a bottleneck. Its simple, public-key-based identity system is straightforward for the Rust control plane to work with. Finally, its modern cryptography ensures that all traffic routed by Lockne is well-protected without complex user setup. It is, for all these reasons, the ideal tunneling backend for a modern, performance-focused network control system.

== A Foundation of Safety and Performance: The Role of Rust

While eBPF provides the mechanism for kernel-level packet redirection, it only forms one half of the system. A robust and reliable userspace control plane is required to manage policies, monitor processes, and configure network interfaces. This daemon is the "brain" of Lockne, and the choice of programming language for its implementation is a critical architectural decision with far-reaching implications for the project's stability, performance, and security. For this component, Lockne is implemented in Rust, a modern systems programming language that provides a unique and powerful combination of performance and safety, making it exceptionally well-suited for this task.

This section provides a detailed justification for this choice. It delves into the core features of Rust that make it a compelling choice for system-level software, explores the trade-offs involved, and contrasts it with other viable language alternatives. Finally, it details the specific reasoning behind selecting the `aya` framework for eBPF development over other options.

=== Core Pillars: Why Rust for Systems Programming?

Rust's design philosophy is guided by the principle of enabling developers to write highly performant, low-level code without sacrificing safety. It achieves this through a set of features that directly address the most common pitfalls of traditional systems languages like C and C++.

==== Memory Safety without a Garbage Collector

The most significant advantage Rust offers for software like Lockne is its compile-time enforcement of memory safety, a property formally verified by the RustBelt project @jung2017rustbelt. In languages like C or C++, a large percentage of critical security vulnerabilities and random crashes stem from memory management errors: use-after-free, double-free, buffer overflows, and null pointer dereferencing. A single memory corruption bug in a long-running network daemon could compromise the entire system's security or lead to unpredictable service interruptions.

Rust eradicates these entire classes of bugs through its ownership system, a novel approach enforced by the compiler's "borrow checker" @klabnikRustProgrammingLanguage2023. The rules are simple in principle:
1. Each value in Rust has a variable that’s called its _owner_.
2. There can only be one owner at a time.
3. When the owner goes out of scope, the value will be dropped.

This system allows for deterministic memory management without the need for a garbage collector (GC). For a system utility like Lockne, the absence of a GC is crucial. Garbage collectors can introduce non-deterministic "stop-the-world" pauses, where the application freezes for a short time while the GC cleans up memory. While often imperceptible in web services, such pauses are unacceptable in a low-level networking component where predictable, low-latency performance is paramount. Rust provides the memory safety of a managed language with the predictable performance of C.

==== Performance and Zero-Cost Abstractions

As a compiled language with a sophisticated LLVM-based backend, Rust generates machine code that is on par with C and C++ in terms of raw performance. It adheres to the principle of "zero-cost abstractions," which means that high-level language constructs that make code more readable and maintainable do not introduce any runtime overhead.

For example, Rust's iterators are a high-level abstraction for processing sequences of data. A developer can chain together methods like `map`, `filter`, and `fold` to express complex logic declaratively. The compiler, however, optimizes these chains down into the same kind of highly efficient, monolithic loop that a C programmer would write by hand. This allows the Lockne control plane to be written in a high-level, expressive style without sacrificing the performance needed to efficiently handle policy updates, process monitoring, and system state management.

==== Fearless Concurrency

Modern systems are inherently concurrent, and the Lockne daemon is no exception. It must simultaneously handle multiple operations: monitor for new process creation, listen for commands from a user interface, manage the lifecycle of eBPF programs, and interact with network interfaces.

Rust's ownership model extends to concurrency, providing a powerful guarantee: if your code compiles, it is free of data races. A data race occurs when multiple threads access the same memory location concurrently, with at least one of them being a write, leading to unpredictable behavior. Rust's type system encodes whether a type can be safely transferred across threads (`Send` trait) or accessed from multiple threads simultaneously (`Sync` trait). The compiler enforces these rules, making it possible to write complex multi-threaded or asynchronous code with a high degree of confidence.

This "fearless concurrency" is leveraged in Lockne through the `async/await` syntax and the Tokio runtime, an industry-standard framework for writing asynchronous applications. This allows the control plane to manage thousands of concurrent I/O operations—like listening on sockets for process events—with minimal overhead and without the risk of race conditions that plague traditional concurrent systems code.

=== Trade-offs and Acknowledged Challenges

No technology choice is without its drawbacks, and choosing Rust is no exception. For the sake of a balanced analysis, it is important to acknowledge the challenges. The primary hurdle is Rust's notoriously steep learning curve. The borrow checker, while providing immense safety benefits, forces the programmer to think differently about program structure and data flow, which can be frustrating for those coming from other languages. Furthermore, Rust's powerful compiler and static analysis checks can lead to longer compilation times compared to languages like Go. However, for a project where correctness and long-term stability are paramount, these upfront costs are a worthwhile investment in the quality of the final software.

=== Comparison with Alternative Systems Languages

To fully justify the choice of Rust, it is useful to compare it against other languages that could have been used to build Lockne's control plane.

- *C and C++:* The traditional incumbents for systems programming. They offer unmatched performance and control. However, they achieve this by placing the entire burden of memory safety on the developer. Decades of evidence show that even in the most well-funded and reviewed projects, memory safety bugs persist, leading to critical security vulnerabilities. For a security-focused tool like Lockne, building the control plane in C or C++ would be an unnecessary risk, trading a small potential performance gain for a massive increase in potential attack surface.

- *Go:* A more modern alternative, Go is also a strong contender. It offers excellent support for concurrency (goroutines), fast compilation times, and a simple, clean syntax. The primary reason Go was not chosen for Lockne is its reliance on a garbage collector. As discussed, the non-deterministic pauses of a GC are undesirable for this use case. Furthermore, while Go's eBPF ecosystem is maturing, it is less developed than Rust's. The close integration and idiomatic feel of libraries like `aya` give Rust a distinct advantage for projects that sit at the intersection of userspace and the eBPF-enabled kernel.

=== eBPF Toolchain Integration

A key architectural decision was the choice of framework for integrating Rust with the eBPF subsystem. While the `libbpf-rs` crate provides a mature bridge to the traditional C-based `libbpf` ecosystem, the decision was made to use the `Aya` framework.

`Aya` is a pure-Rust eBPF library and toolchain that allows both the userspace control plane and the in-kernel eBPF programs to be written entirely in Rust. This unified approach provides significant advantages in terms of compile-time safety, especially for data structures shared between userspace and the kernel, and it simplifies the build and deployment process by removing dependencies on C libraries. A full justification for this choice, including a detailed comparison of the toolchain ecosystems, is provided in the preceding chapter on the eBPF programming model.

== Process-to-Socket Mapping: The Core Challenge

The central premise of Lockne is its ability to route network traffic on a per-application basis. To achieve this, the system must be able to answer a seemingly simple question for every single network packet: "Which process created this?" This task, known as process-to-socket mapping, is the single most important technical challenge that this thesis addresses.

While the question is simple, the answer is profoundly complex within the context of a high-performance networking data path. The Linux kernel, for reasons of efficiency and design, does not attach process identifiers to network packets. A packet is an anonymous unit of data from the perspective of the lower networking layers. Therefore, a robust and performant mechanism must be built to reconstruct this link. This section provides a detailed analysis of this challenge, exploring the internal workings of the Linux kernel, the limitations of traditional approaches, and the modern eBPF-based architecture that Lockne implements to solve the problem.

=== A Packet's Journey and the Loss of Context

To understand why this problem is difficult, it is essential to follow the journey of a packet from its creation in an application to its interception point in the kernel.

1. *Userspace Creation:* An application like a web browser opens a socket, which the kernel represents as a file descriptor. When the application writes data to this file descriptor, a system call is invoked, transferring the data and control across the userspace-kernel boundary.
2. *Socket Layer:* Inside the kernel, the VFS (Virtual File System) layer directs the operation to the socket subsystem. Here, the kernel identifies the `struct sock` associated with the file descriptor. This crucial structure holds all the state for a connection (IP addresses, ports, TCP state, etc.).
3. *Packet Allocation:* The kernel allocates a `sk_buff` (socket buffer), the core structure used to represent a network packet throughout its life in the kernel. The application data is copied into the `sk_buff`, and a pointer to the parent `struct sock` is stored within it.
4. *Network Stack Traversal:* The `sk_buff` is passed down through the protocol layers (TCP, then IP), where each layer adds its respective header.
5. *Egress and the TC Hook:* Finally, the fully formed packet is passed to the Traffic Control (TC) subsystem for scheduling on the physical network device. It is at the TC egress hook that Lockne's `classifier` program intercepts it.

At the moment of interception, our eBPF program has the `sk_buff`. While the `sk_buff` contains a pointer back to the `struct sock`, the direct, trivial link to the originating `task_struct` (the kernel's representation of a process) is gone. While it is theoretically possible to traverse kernel memory from the `sock` backwards to find the process, this is a complex, unstable, and slow operation that the eBPF verifier rightfully prohibits in a fast-path networking program. The link is severed for performance reasons, and we must therefore establish a new one.

=== Traditional Approaches and Their Limitations

Before the advent of eBPF, several methods existed to attempt this mapping, each with significant drawbacks that make them unsuitable for Lockne.

==== Userspace Enumeration (`ss`, `lsof`)
The most common approach, used by command-line tools like `ss` and `lsof`, operates by correlating information from the `/proc` filesystem. The process involves two stages: first, reading a list of all active network sockets from files like `/proc/net/tcp`, which lists each socket's unique inode number. Second, the tool must iterate through every process directory (`/proc/[PID]/fd/`) and inspect every symbolic link to find which process holds a file descriptor that links to that socket inode.

While accurate, this method is catastrophically slow for real-time packet processing. It requires multiple file system reads and a full scan of the process table. Performing this work for every single outgoing packet would cripple system performance.

==== Socket Marking (`SO_MARK`) and Policy Routing
The kernel's routing subsystem has long supported a mechanism for policy-based routing. An application can use the `setsockopt` system call with the `SO_MARK` option to "tag" all packets originating from a specific socket with a numerical mark. This mark can then be used by the kernel's `iptables` firewall or its policy routing rules (`ip rule`) to direct these tagged packets into a different routing table, which could then route them through a VPN.

The fundamental weakness of this approach is that it is not transparent; it requires the *application to cooperate*. The application's source code must be modified to add the `setsockopt` call. This is impossible for closed-source applications and impractical to expect from all open-source ones, making it a non-starter for a general-purpose tool like Lockne.

=== The Modern eBPF Architecture: Stateful Tracking

Lockne solves this challenge by adopting the modern eBPF paradigm: instead of performing an expensive lookup for every packet, it proactively records the mapping at the moment a connection is created. This is achieved with a "team" of two eBPF programs that communicate via a shared map.

==== The `cgroup/sock_addr` Notary
The first program is a `cgroup/sock_addr` program attached to the root control group. This program acts as a "notary," as its hook is triggered whenever any process on the system performs a socket operation like `connect()`. At this moment, the program has access to all the necessary context:
- It can get the Process ID (PID) of the current process using the `bpf_get_current_pid_tgid()` helper.
- It can get a unique, stable identifier for the socket for the duration of its lifetime, known as the "socket cookie," using `bpf_get_socket_cookie()`.

The program's sole job is to insert this pairing—`{socket_cookie -> PID}`—into a shared eBPF hash map.

==== The `tc` Traffic Cop and the Socket Cookie
The second program is the `tc` classifier running at the egress hook. For every packet it processes, it performs the following fast and simple steps:
1. It extracts the same socket cookie from the packet's `sk_buff`. This cookie is carried with the packet.
2. It performs a single, highly efficient hash map lookup using the cookie as the key.
3. If a corresponding PID is found in the map, the program knows the packet's owner. It can then consult a second "policy" map to decide if this PID's traffic should be redirected.

This design is highly performant because the expensive work of associating a process with a connection is done only once, when the connection is initiated. The per-packet logic on the fast path is reduced to a single map lookup.

==== Acknowledged Challenges in State Management
This stateful approach is powerful, but it introduces its own set of challenges that a robust implementation must address:
- *Process Hierarchy:* If a monitored application (e.g., Firefox) spawns a child process (e.g., a media decoder), that child process will have a different PID. A complete solution must monitor for `fork()` events and automatically apply the parent's policy to its children.
- *Short-Lived Connections:* For applications that make thousands of very short-lived connections (e.g., a web server benchmark), the overhead of map creation and deletion can become significant. The maps must be designed to handle this "churn" efficiently.
- *State Cleanup:* The mapping in the eBPF map must be removed when a socket is closed. If it is not, the map will eventually fill up, and new connections cannot be tracked. This requires attaching another eBPF program (e.g., a `kprobe` on `tcp_close`) to reliably detect connection termination and perform the necessary cleanup.

== State of the Art: Analyzing Existing Solutions

The problem of per-application traffic control is not new. Several solutions exist, each with a different approach and a different set of trade-offs. This analysis of the state of the art is crucial for positioning Lockne and justifying its novel architecture.
=== Linux Networking Subsystem Analysis: The Native Toolset

Before justifying the use of a complex technology like eBPF, it is essential to rigorously evaluate the capabilities of the standard Linux networking subsystem @rosen2014linux. The kernel provides a powerful, albeit complex, set of native tools for routing and filtering traffic, primarily centered around Netfilter, policy routing, and the Traffic Control (TC) subsystem. This section analyzes these tools and demonstrates why, despite their power, they are fundamentally ill-suited for the dynamic, per-application routing that Lockne aims to provide.

==== Netfilter and `iptables`: The Packet Filtering Workhorse
Netfilter is the primary firewalling framework within the Linux kernel. For decades, the `iptables` userspace utility has been the standard interface for configuring its rules. At first glance, `iptables` seems like a plausible candidate for solving the per-application routing problem, particularly due to its "owner" match module.

A rule can be constructed using this module to match packets created by a specific user or group:
`iptables -t mangle -A OUTPUT -m owner --uid-owner arto -j MARK --set-mark 1`

This rule tells the kernel to apply a firewall mark of "1" to all outgoing packets from the user `arto`. This mark can then be used by the routing system to direct this traffic differently. However, this approach has two critical limitations:

1. *Lack of Granularity:* The owner module matches on User ID (UID) or Group ID (GID), not on Process ID (PID). This means it can isolate traffic for an entire user, but it cannot distinguish between two different applications, such as a web browser and a video game, running as the same user. This is the fundamental deal-breaker for per-application control. While there was a PID owner match, it was notoriously unreliable for long-lived connections and has been deprecated.

2. *Performance and Complexity:* `iptables` processes rules in a sequential list. For a system with many complex rules, the performance overhead of traversing this list for every single packet can become significant. Furthermore, `iptables` rules are not ideal for packet redirection; their primary purpose is to accept, drop, or NAT packets, not to efficiently hand them off to another kernel subsystem like a WireGuard interface.

==== Policy Routing: Multiple Routing Tables
Linux possesses a sophisticated routing subsystem that goes beyond a single default route. It supports multiple, independent routing tables and a ruleset to decide which table to use for any given packet. This is known as "policy routing," configured with the `ip rule` command.

This system works beautifully with the firewall marks set by `iptables`. Following the previous example, one could create a rule that directs all marked packets to a special routing table:

1. `ip rule add fwmark 1 table 100` (If packet has mark 1, use table 100)
2. `ip route add default via [vpn-gateway] table 100` (Table 100's default route is the VPN)

This combination is powerful for static, user-based or network-based routing policies. However, its limitations for Lockne are clear:
- *Static Configuration:* The rules are manually configured and are not designed to be updated dynamically hundreds of times per minute as applications start and stop. The overhead of calling the `ip` command to add and remove rules for every process would be substantial.
- *Dependency on Firewall Marks:* The entire system still relies on the firewall's ability to mark the packets, which, as we've seen with `iptables`, lacks the required process-level granularity.

==== The Traffic Control (TC) Subsystem
The TC subsystem itself, where Lockne's eBPF program attaches, has its own native filtering capabilities. Using the `tc filter` command, one can add classifiers that direct traffic to different scheduling classes or perform simple actions.

However, the native TC classifiers suffer from the same fundamental problem as the rest of the traditional toolset: a lack of process context. TC filters can match on IP headers, port numbers, firewall marks, and other packet-level data, but they have no built-in mechanism for identifying the originating process of a given packet. This is precisely the gap that eBPF was designed to fill. By allowing programmable logic at the TC layer, eBPF gives the subsystem the "eyes" it needs to see the process-level context that was previously unavailable.

==== Control Groups (cgroups) Networking
Control Groups, particularly in their modern `v2` incarnation @cgroupv2, provide mechanisms to manage network resources. For example, a network administrator can limit the bandwidth available to a specific cgroup. The `net_cls` controller can even be used to "tag" all traffic originating from a cgroup with a class ID, which can then be used by the TC subsystem.

This gets us one step closer. We can indeed put a single application into its own cgroup. However, using this mechanism for routing still requires stitching it together with the TC and policy routing systems. It is not a standalone solution. While it provides the process isolation we need, it doesn't provide the dynamic redirection mechanism. eBPF, by contrast, provides both in a single, unified framework. An eBPF program can be attached directly to the cgroup to get process context and perform the redirection itself, without needing to be chained together with two or three other kernel subsystems.

In summary, while the native Linux networking tools are powerful for static, rule-based network management, they all lack a key ingredient for Lockne's use case: a performant and dynamic way to link a packet on the data path back to its specific originating process. Every native approach is either too coarse (matching on UID instead of PID) or too static (requiring manual configuration of rules). This analysis demonstrates a clear architectural gap that a modern, programmable solution like eBPF is uniquely positioned to fill.

=== Enterprise VPN Split-Tunneling Solutions

Many commercial VPN clients, particularly those targeted at enterprise users, offer a feature called "split tunneling." This allows administrators to configure the VPN to only route certain traffic through the tunnel, while other traffic is allowed to use the direct internet connection. While this may seem similar to Lockne's goal, these solutions are fundamentally different in their scope and their mechanisms.

- *Scope:* Enterprise VPN split tunneling is designed for centrally managed environments. The administrator defines the routing policies, and these policies are pushed down to the client machines. The goal is to allow employees to access internal company resources securely while minimizing the impact on their general internet browsing. This is very different from Lockne's focus on individual users dynamically choosing which applications should use a VPN.

- *Mechanism:* The specific mechanisms vary by vendor, but most enterprise VPNs rely on a combination of:
  1. *Route Tables:* The VPN client modifies the system's routing table to direct traffic destined for the company's internal networks through the VPN interface.
  2. *Firewall Rules:* The client configures the local firewall (e.g., Windows Firewall or `iptables` on Linux) to enforce the routing policies. Often, this involves creating rules that match traffic based on the destination IP address or port number.
  3. *Application-Awareness (Limited):* Some clients offer limited application-awareness, allowing the administrator to specify that all traffic from a specific application executable should be routed through the VPN. However, this is typically implemented using simple process name matching, which is easily bypassed (e.g., by renaming the executable) and does not account for child processes spawned by the application.
The administrative overhead and lack of dynamic control make these solutions unsuitable for the Lockne's target use case. They are designed for static, centrally managed policies, not for individual users making dynamic, per-application choices.

=== Containerization and Network Namespaces: The "Heavy Hammer" Approach

Containerization technologies, such as Docker @merkel2014docker and Podman, and related sandboxing tools like Firejail, offer a very different approach to traffic isolation. They create isolated environments with their own network stacks, effectively sandboxing an application and all its network traffic.

- *Mechanism:* These technologies leverage Linux network namespaces, which provide complete isolation of the network environment, including network interfaces, routing tables, and firewall rules. A containerized application operates within its own network namespace, preventing it from directly accessing the host system's network interfaces. All traffic from the container must be explicitly routed through virtual interfaces.

While network namespaces provide strong isolation, they are a heavyweight solution for the problem of per-application routing.
1. *Resource Overhead:* Creating and managing network namespaces consumes significant system resources, particularly memory. Starting a full container just to isolate a single application's traffic is often overkill.
2. *Complexity:* Managing network namespaces requires complex configuration, including setting up virtual interfaces, configuring routing rules, and managing firewall policies. This is typically done through command-line tools or container orchestration platforms like Kubernetes, adding significant administrative overhead.
3. *Limited Integration:* Applications running inside network namespaces are isolated from the host system, making it difficult to share files, display graphical interfaces, or access other host-level services. While there are ways to bridge this gap, they add additional complexity to the system.

For the goals of Lockne, containerization is too heavyweight and too restrictive. The goal is not to completely isolate an application's network traffic but rather to selectively route it through a VPN while still allowing seamless interaction with the host system.

=== Userspace Proxies: The `LD_PRELOAD` Method

The most common approach for per-application traffic control on desktop Linux is seen in tools like `proxychains-ng` and `tsocks`. These solutions operate by intercepting network-related library calls within a target application's process space.

On Unix-like systems, this interception is typically achieved through the `LD_PRELOAD` environment variable. By preloading a custom shared library, these tools can replace standard network functions like `connect()`, `send()`, or `recv()` with their own implementations. When the target application attempts to make a network connection, the proxy tool's replacement function is invoked instead. This function then establishes a connection through the desired proxy (typically SOCKS or HTTP) rather than directly to the target endpoint.

However, this approach suffers from several fundamental limitations:
- *Performance Overhead:* The performance penalty is significant. Data packets must cross the kernel-userspace boundary multiple times: once for the application's original system call, again when the proxy tool makes its own connection, and so on. This context-switching for every network operation adds considerable latency.
- *Brittleness:* The `LD_PRELOAD` mechanism is fragile. It is ineffective against modern applications that are statically linked or that use custom networking libraries which bypass the standard C library functions. Furthermore, security-conscious applications may employ anti-tampering mechanisms that detect and prevent library preloading.

=== Full Virtualization: The Heaviest Solution

Another method for achieving complete network isolation is through full virtualization, using a Virtual Machine (VM). By running an application inside a separate guest operating system, its network traffic can be completely managed and routed by the hypervisor.

While providing the strongest possible isolation, this approach introduces excessive overhead for the goal of simple traffic redirection. It requires significant CPU and memory resources to run an entire separate operating system. Furthermore, configuring the virtual networking between the host and guest to achieve the desired routing is complex. The performance penalty of traversing a hypervisor's network stack and the difficulty of integrating a VM-bound application with the host desktop environment make this solution impractical for Lockne's use case.

=== Comparative Analysis of Existing Solutions

The various approaches to per-application traffic control each present a different set of trade-offs between performance, transparency, and administrative complexity. The following table provides a comparative analysis based on several key criteria: Granularity, Performance, Resource Overhead, and Transparency for the application.

#figure(
  table(
    columns: (auto, 1fr, 1fr, 1fr, 1fr),
    stroke: 1pt,
    align: center + horizon,
    [*Feature*],
    [*Userspace Proxies*],
    [*Split-Tunneling VPNs*],
    [*Network Namespaces*],
    [*Lockne*],

    [Granularity],
    [Per-Process],
    [Per-App / IP Range],
    [Per-Container],
    [Per-Process],

    [Performance], [Low], [Medium], [High], [High],
    [Resource Overhead], [Very Low], [Low], [High], [Very Low],
    [Transparency], [Low], [Medium], [High], [High],
    [Admin Complexity], [Low], [High - Admin], [High - User], [Low],
  ),
  caption: [A comparative analysis of traffic control solutions. "Transparency" refers to whether the application needs to be modified or aware of the mechanism.],
)

This analysis highlights the specific gap that Lockne is designed to fill. Traditional userspace proxies sacrifice performance and transparency for granularity. Enterprise solutions and containerization, while performant, introduce significant resource and administrative overhead and lack the dynamic, user-centric control needed for desktop use cases. Lockne's architecture aims to provide the high granularity of userspace proxies with the high performance and transparency of in-kernel solutions, all while maintaining low resource usage and low complexity for the end-user.

=== Network Namespaces: The Heavyweight Solution

At the other end of the spectrum is the kernel's native isolation primitive: network namespaces. A network namespace provides a completely separate network stack for processes, including independent network interfaces, routing tables, and firewall rules. This is the fundamental technology underlying container platforms like Docker.

While network namespaces offer complete and reliable traffic control, they are fundamentally ill-suited for dynamic, per-application traffic control in desktop environments. The administrative complexity is substantial, requiring root privileges for namespace creation and management. Each namespace requires manual setup of network interfaces, routing rules, and connectivity policies.

Applications running in separate namespaces cannot easily communicate with services in the root namespace, breaking integration with desktop environments and shared services. The isolation provided by network namespaces is often excessive for simple application routing needs, creating hard boundaries that prevent the kind of selective, transparent routing that desktop users expect.

=== System-Wide VPN Solutions: Lack of Granularity

Traditional VPN clients route all system traffic through encrypted tunnels without application-level discrimination. While these solutions excel in providing comprehensive traffic protection, their all-or-nothing approach creates significant usability challenges.

All applications, including those that may require local network access or have incompatibility issues with tunneled connections, are forced through the VPN tunnel. This can break local file sharing, network printing, or applications that require direct connectivity. The performance impact is also substantial for users who only need protection for specific applications, as all traffic consumes VPN server resources and may be subject to geographic latency penalties.


The all-or-nothing approach of system-wide VPNs has several drawbacks:
- *Performance:* All network traffic is routed through the VPN server, even traffic destined for local network resources. This introduces unnecessary latency and consumes VPN server bandwidth.
- *Compatibility:* Some applications may not function correctly through a VPN tunnel. This can be due to protocol incompatibilities, MTU (Maximum Transmission Unit) issues, or other VPN-related problems.
- *Usability:* Users may want to selectively route traffic through a VPN only for specific tasks, such as browsing sensitive websites, while still using their direct internet connection for other activities.

System-wide VPNs can be a blunt instrument, forcing all traffic through the tunnel even when it is not necessary or desirable. This lack of granularity makes them unsuitable for users who need fine-grained control over their network traffic.

== Synthesis: Identifying the Architectural Gap

The preceding analysis reveals a clear gap in the landscape of traffic control tools. Users are forced to choose between performant but inflexible system-wide VPNs, complex and heavyweight containerization, or user-friendly but slow and brittle userspace proxies.

There is no solution that provides the performance of in-kernel routing with the user-friendly, dynamic, per-application granularity of a userspace tool. Existing approaches either sacrifice performance for flexibility (userspace proxies), sacrifice flexibility for performance (system-wide VPNs), or introduce excessive complexity (network namespaces).

Lockne is designed to fill this specific gap. By combining the performance of eBPF for packet redirection with the proven security of WireGuard and a modern Rust control plane, it aims to offer the best of all worlds: kernel-level performance with application-level control. The architecture leverages each technology's strengths while mitigating their individual limitations, creating a solution that is simultaneously high-performance, secure, and user-friendly.
