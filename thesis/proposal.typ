// ===============================================
// Document Setup
// ===============================================
#set document(
  author: "Artoghrul Gahrammanli, BSc.",
  title: "Lockne: Dynamic Per-Application VPN Tunneling with eBPF and Rust"
)
#set page(
  paper: "a4",
  margin: (top: 30mm, bottom: 25mm, left: 35mm, right: 20mm),
)
#set text(
  font: "New Computer Modern", // A good, free alternative to Times New Roman
  size: 12pt,
  lang: "en"
)
#set par(
  justify: true,
  leading: 0.65em, // Corresponds to ~1.5 line spacing
  first-line-indent: 1cm
)
#set heading(numbering: "1.")

// ===============================================
// Title Page 
// ===============================================
#align(center)[
  #v(1fr) // Add flexible space at the top

  #text(20pt, weight: "bold")[Czech University of Life Sciences Prague]
  #v(0.5cm)
  #text(16pt)[Faculty of Economics and Management]
  
  #v(3cm) // Reduced spacing
  
  #text(24pt, weight: "bold")[Master's Thesis Proposal]
  
  #v(1.5cm) // Reduced spacing
  
  #text(22pt, weight: "bold")[Lockne: Dynamic Per-Application VPN Tunneling with eBPF and Rust]
  
  #v(1fr) // Add flexible space in the middle

  #block[
    #grid(
      columns: (1fr, 1fr),
      row-gutter: 1.5em,
      align: (left, right),
      [
        *Author:* \
        Artoghrul Gahrammanli, BSc.
      ],
      [
        *Supervisor:* \
        Ing. Martin Havránek, Ph.D.
      ]
    )
  ]
  
  #v(1fr) // Add flexible space before the date
  
  #text(14pt)[Prague, 2025]
]

#pagebreak()

// ===============================================
// Main Content
// ===============================================

= Introduction and Problem Statement

In today's connected world, user privacy and data security have become critical concerns. Virtual Private Networks (VPNs) are a primary tool for this, helping to anonymize user traffic and access private resources. While VPNs are incredibly useful, they come with trade-offs, one of the most significant of which is the impact on network performance and flexibility. By default, most VPN software routes all network traffic through its interface when enabled. This "all-or-nothing" approach is often not ideal. A user may wish to secure the traffic of a specific web browser for privacy, while allowing high-bandwidth applications like video streaming or gaming to use a direct, lower-latency internet connection. Similarly, software developers often need to isolate the network traffic of an application under test without affecting their entire development environment.

This thesis directly tackles this problem by designing and implementing "Lockne", a new system for per-application traffic routing. It proposes a solution that avoids the performance penalties of existing userspace tools and the complexity of containerization. Lockne leverages the extended Berkeley Packet Filter (eBPF) framework for efficient, kernel-level packet filtering, combined with a modern control plane written in the Rust programming language. The goal is to create a performant, user-friendly, and dynamic mechanism for fine-grained network control on modern Linux systems.

= State of the Art and Their Limitations

A review of current technologies reveals several approaches to traffic isolation, each with distinct drawbacks that Lockne aims to overcome.

== Userspace Proxies and Hooks
Tools like Proxifier or proxychains operate by intercepting system calls or injecting libraries into running applications. While effective, this userspace approach introduces notable latency and CPU overhead as packets must traverse the kernel-userspace boundary multiple times. They can also be brittle, often failing with statically compiled or protected applications.

== Conventional VPN Split Tunneling
Many commercial VPN clients offer "split tunneling," allowing users to include or exclude specific applications from the VPN tunnel. However, this functionality is typically limited to a single VPN connection and is implemented within the proprietary client, offering limited flexibility and extensibility. Furthermore, the underlying mechanism is often still a userspace filter, inheriting its performance limitations.

== Network Namespaces
The Linux kernel provides network namespaces as a powerful mechanism for complete network stack isolation. This is the technology underpinning container systems like Docker. While namespaces offer robust isolation, their administration is complex and not integrated into typical desktop user workflows. They are designed for isolating servers and services, not for dynamically routing individual graphical applications on a user's machine.

= Proposed Solution: The Lockne Architecture

Lockne will be a system composed of two primary components working in tandem to achieve its goals.

== Kernel Component (eBPF)
The core of Lockne will be a set of eBPF programs attached to strategic hooks within the Linux networking stack. Specifically, eBPF programs attached to Traffic Control (TC) ingress/egress hooks and `cgroup/sock_addr` hooks will be used to identify and redirect network packets based on their originating process identifier (PID). These programs will consult kernel-space maps (eBPF maps) to determine which traffic should be rerouted to a dedicated WireGuard VPN interface and which should proceed through the default network path. By operating entirely within the kernel, this approach is expected to minimize latency and CPU overhead.

== Userspace Component (Rust)
A userspace daemon, implemented in Rust for its performance and memory safety guarantees, will serve as the control plane for Lockne. This component will be responsible for:
- Managing routing policies defined by the user (e.g., "route all traffic from `firefox.exe` to VPN A").
- Monitoring running processes to dynamically apply policies to new applications and their children.
- Configuring and managing multiple WireGuard interfaces, allowing for simultaneous connections to different VPN endpoints.
- Providing a command-line interface (CLI) or a simple graphical user interface (GUI) for user interaction.

= Thesis Objectives and Methodology

The primary goal of this thesis is to design, implement, and evaluate a prototype system for dynamic, per-application network traffic routing. This goal is broken down into the following specific objectives:

1.  *Design an architecture* for a per-application tunneling system that leverages eBPF for kernel-level packet redirection and Rust for userspace control.
2.  *Implement a functional prototype* of Lockne, capable of identifying application traffic and routing it through a specified WireGuard interface, while leaving other traffic unaffected.
3.  *Evaluate the performance* of the prototype in terms of latency overhead and CPU utilization, particularly in comparison to established userspace proxy solutions.
4.  *Analyze the key technical challenges* involved, such as reliable process-to-socket mapping and maintaining policy across process hierarchies.

The methodology for achieving these objectives will follow a structured research and development process:
- *Literature Review:* A comprehensive study of eBPF, the Linux networking stack, the WireGuard protocol, and existing traffic control solutions.
- *Iterative Prototyping:* Development of the Lockne prototype using the `aya` eBPF library for Rust. The development will start with a minimal proof-of-concept and incrementally add features.
- *Empirical Evaluation:* A series of controlled experiments will be conducted to measure network throughput, packet latency, and CPU usage under various workloads (e.g., bulk data transfer, interactive web browsing). The results will be benchmarked against a baseline (no proxy) and a leading userspace tool (e.g., Proxifier).

= Expected Outcomes and Contribution

The successful completion of this thesis will yield several outcomes:
- A functional, open-source prototype of Lockne. The source code will be publicly available at the project repository: #link("https://github.com/artogahr/lockne").
- A comprehensive performance analysis that quantifies the benefits of a kernel-level eBPF approach over userspace methods.
- The master's thesis document itself, detailing the system's design, implementation, and evaluation.

The primary contribution of this work will be a novel, high-performance solution to the long-standing problem of application-specific network routing, demonstrating the power of modern kernel technologies like eBPF for solving complex networking challenges on end-user systems.

#pagebreak()
= Initial References

#set par(first-line-indent: 0em, hanging-indent: 1cm)

DONENFELD, Jason A., 2017. _WireGuard: Next Generation Kernel Network Tunnel_. Proceedings of the 2017 Internet Society's Network and Distributed System Security Symposium (NDSS).

GREGG, Brendan, 2019. _BPF Performance Tools_. Addison-Wesley Professional. ISBN 978-0136554820.

KERRISK, Michael, 2010. _The Linux Programming Interface: A Linux and UNIX System Programming Handbook_. No Starch Press. ISBN 978-1593272203.
