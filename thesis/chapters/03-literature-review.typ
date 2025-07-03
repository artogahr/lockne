= Literature Review

Before designing and building Lockne, it is essential to understand the technologies that make it possible. This review surveys the technical landscape, focusing on the three pillars of the project: the eBPF framework for kernel programmability, the WireGuard protocol for secure tunneling, and the Rust language for building a reliable control plane. The goal is to show how these powerful, modern tools can be combined in a novel way to solve the long-standing problem of per-application traffic control.

== The Kernel's New Superpower: An Overview of eBPF

The core mechanism behind Lockne is the extended Berkeley Packet Filter (eBPF). To understand its importance, one must see it not just as a tool, but as a fundamental shift in how the Linux kernel can be extended. As described by Brendan Gregg, eBPF allows sandboxed programs to run directly within the kernel in response to specific events, without requiring changes to the kernel source code or loading kernel modules (Gregg, 2019). This provides a safe, performant way to implement custom logic at the lowest levels of the operating system.

=== From Packet Filtering to In-Kernel Virtual Machine

The original Berkeley Packet Filter (BPF), often called classic BPF (cBPF), was designed in the 1990s with a single purpose: to filter network packets efficiently in userspace tools like `tcpdump`. It was a simple, register-based virtual machine that could decide whether to accept or drop a packet.

eBPF, introduced in 2014, is a complete redesign. It expands the original concept into a general-purpose, 64-bit virtual machine inside the kernel. As Liz Rice explains in _Learning eBPF_, it's more than just a filter; it's a tool for building a wide range of networking, security, and observability applications (Rice, 2023). Before any eBPF program is loaded, it must pass through a strict in-kernel verifier. This verifier statically analyzes the program's code, checking for out-of-bounds memory access, infinite loops, and illegal instructions. This verification step is what makes eBPF safe to run in the kernel, a critical feature that distinguishes it from traditional kernel modules which can easily crash the entire system.

=== Core Components for Lockne: Programs, Maps, and Hooks

To build a system like Lockne, we must use three key eBPF concepts:

- *Hooks:* These are well-defined points in the kernel's code path where an eBPF program can be attached. For network-related tasks, the most important hooks are on the Traffic Control (TC) subsystem and on control groups (cgroups). By attaching a program to a TC hook on a network interface, we can inspect and manipulate every packet that passes through it. This is the primary mechanism Lockne will use to redirect traffic.

- *Programs:* An eBPF program is the actual code that runs at a hook. For Lockne, the TC program will look at a packet, determine which process created it, and decide whether to send it to a WireGuard tunnel or let it pass through the default route.

- *Maps:* Maps are the communication bridge. They are efficient key-value data structures that can be accessed from both eBPF programs running in the kernel and from userspace applications. For Lockne, maps are the "brain" of the operation. The Rust daemon will write routing policies (e.g., "PID 1234 -> WireGuard interface A") into a map. The eBPF program in the kernel will then read from this map to make its routing decisions in real-time. This allows for dynamic policy updates without reloading the kernel program.
