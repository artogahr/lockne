#set document(
  title: "Lockne: Dynamic Per-Application VPN Tunneling with eBPF and Rust",
  author: "Artoghrul Gahramanli, BSc.",
)

#let accent = rgb("#2563eb")       // blue for headings
#let accent-soft = rgb("#e5edff")  // light blue background
#let bg-box = rgb("#0f172a")       // dark for code / kernel

#set page(
  paper: "presentation-16-9",
  margin: (x: 1.5cm, y: 0.8cm),
  numbering: none,
)

#set text(
  font: "DejaVu Sans",
  size: 16pt,
  lang: "en",
)

#let diag-box(label, fill: white, width: 110pt) = rect(
  fill: fill,
  stroke: 0.6pt + rgb("#94a3b8"),
  radius: 4pt,
  inset: 8pt,
  width: width,
  align(center, text(size: 12pt, label)),
)

#align(left + horizon)[
  #v(0.8cm)
  #text(30pt, weight: "bold", fill: accent)[
    Lockne: Dynamic Per-Application VPN Tunneling with eBPF and Rust
  ]
  #v(1.0em)
  #text(20pt)[Master's Thesis Defense]
  #v(0.8em)
  #text(18pt)[Artoghrul Gahramanli, BSc.]
  #v(0.3em)
  #text(14pt)[Faculty of Economics and Management, CZU Prague]
  #v(0.8em)
  #text(14pt)[Supervisor: Ing. Martin Havránek, Ph.D.]
]

#pagebreak()
#align(left + horizon)[
  = Motivation & Problem

  #v(0.8em)

  In today's connected world, VPNs are widely used for privacy and secure remote access – but most work in an all-or-nothing mode.

  - *Performance*: Routing all traffic through a VPN adds latency and can hurt games, video calls, and streaming.
  - *Flexibility*: Some services block VPN traffic; local network resources become inaccessible.
  - *Granularity*: Linux routes by interfaces, not by application identity – packets do not carry a PID.

  The core problem: How can we route traffic per application on Linux, without containers or heavy userspace proxies?
]

#pagebreak()
#align(left + horizon)[
  = Existing Solutions & Architectural Gap

  #v(0.8em)

  Existing approaches to per-application control have important drawbacks:

  - *Userspace proxies (e.g., proxychains)*:
    High per-packet overhead from context switches and data copies.
  - *Containerization / network namespaces*:
    Strong isolation but complex, heavyweight, and inconvenient for daily use.
  - *System-wide VPNs*:
    No per-application granularity; everything is tunneled.

  Gap: There is no lightweight, kernel-native mechanism for dynamic per-application VPN routing on Linux.
]

#pagebreak()
#align(left + horizon)[
  = Research Questions & Objectives

  #v(0.8em)

  *Research questions:*

  - RQ1 – *Feasibility*: Can eBPF be used to implement reliable, per-application routing on Linux?
  - RQ2 – *Performance*: What is the performance overhead compared to userspace tools and to no interception?
  - RQ3 – *Practicality*: Can such a system be made user-friendly enough for real use?

  *Objectives:*

  - Design an architecture combining eBPF (kernel data plane) and Rust (userspace control plane).
  - Implement a prototype that maps packets to processes and applies per-PID policies.
  - Evaluate latency, throughput, and CPU overhead.
  - Analyze key technical challenges (socket cookies, verifier constraints, process hierarchy).
]

#pagebreak()

= Lockne Architecture – High Level

#block(width: 100%)[
  #grid(
    columns: (1fr, 1fr, 1fr, 1fr),
    gutter: 14pt,

    // Column 1: Applications
    align(center)[
      #text(size: 13pt, weight: "bold")[User Apps]
      #v(0.3em)
      #diag-box("Browser", fill: rgb("#e3f2fd"))
      #v(0.15em)
      #diag-box("Game", fill: rgb("#e3f2fd"))
      #v(0.15em)
      #diag-box("Dev Tools", fill: rgb("#e3f2fd"))
    ],

    // Column 2: Lockne daemon
    align(center)[
      #text(size: 13pt, weight: "bold")[Lockne Daemon]
      #v(0.3em)
      #diag-box("Rust Control Plane", fill: rgb("#c8e6c9"))
      #v(0.15em)
      #text(size: 10pt)[Policies: PID → iface]
    ],

    // Column 3: Kernel / eBPF
    align(center)[
      #text(size: 13pt, weight: "bold")[Kernel / eBPF]
      #v(0.3em)
      #diag-box("cgroup connect4", fill: rgb("#fff9c4"))
      #v(0.15em)
      #diag-box("TC egress", fill: rgb("#fff9c4"))
      #v(0.15em)
      #text(size: 10pt)[Maps: SOCKET_PID_MAP, POLICY_MAP]
    ],

    // Column 4: Network interfaces
    align(center)[
      #text(size: 13pt, weight: "bold")[Interfaces]
      #v(0.3em)
      #diag-box("eth0 (direct)", fill: rgb("#eceff1"))
      #v(0.15em)
      #diag-box("wg0 (WireGuard)", fill: rgb("#eceff1"))
    ],
  )
]

#pagebreak()

= Connection Tracking (cgroup program)

#block(width: 100%)[
  #align(center)[
    #text(size: 13pt, weight: "bold")[At connection time]
    #v(0.4em)
    #diag-box("User process (PID)", fill: rgb("#e3f2fd"), width: 170pt)
    #v(0.2em)
    #text(size: 12pt)[connect()]
    #v(0.15em)
    #text(size: 12pt)[↓]
    #v(0.15em)
    #diag-box("cgroup/sock_addr eBPF\n(lockne_connect4)", fill: rgb("#fff9c4"), width: 190pt)
    #v(0.15em)
    #text(size: 12pt)[↓ store cookie & PID]
    #v(0.15em)
    #diag-box("SOCKET_PID_MAP\ncookie → PID", fill: rgb("#c8e6c9"), width: 190pt)
  ]
]

#pagebreak()

= Packet Classification & Redirect (TC program)

#block(width: 100%)[
  #align(center)[
    #text(size: 13pt, weight: "bold")[At packet time]
    #v(0.4em)
    #diag-box("Outgoing packet (sk_buff)", fill: rgb("#fff9c4"), width: 190pt)
    #v(0.15em)
    #text(size: 12pt)[↓ TC egress hook]
    #v(0.15em)
    #diag-box("TC eBPF classifier:\nread cookie + lookup PID & policy", fill: rgb("#c8e6c9"), width: 220pt)
    #v(0.15em)
    #text(size: 12pt)[↓ apply redirect decision]
    #v(0.15em)
    #diag-box("bpf_redirect → eth0 or wg0", fill: rgb("#eceff1"), width: 210pt)
  ]
]

#pagebreak()

#align(left + horizon)[
  = Implementation & Tooling

  #v(0.8em)

  - *Language & toolchain*:
    Rust for both userspace daemon and eBPF programs (via Aya), with shared types in `lockne-common`.
  - *Key abstractions*:
    `Pid` and `PolicyEntry` shared between kernel and userspace with `#[repr(C)]` for layout compatibility.
  - *Maps*:
    `SOCKET_PID_MAP` (cookie → PID) and `POLICY_MAP` (PID → ifindex) as eBPF hash maps.
  - *Attachment*:
    TC egress program attached via `clsact` qdisc; cgroup program attached at `/sys/fs/cgroup` (v2 root).
  - *Interface*:
    CLI for launching and tracking specific programs, plus TUI for live monitoring of tracked traffic.
]

#pagebreak()

#align(left + horizon)[
  = Results: Performance & Correctness

  #v(0.8em)

  *Performance highlights (measured):*

  - Latency overhead: < 1 ms compared to baseline (no interception).
  - CPU utilization: < 1% additional CPU under test workloads.
  - Throughput: no measurable degradation vs baseline (using `iperf3`).

  #v(0.6em)
  #block(width: 100%)[
    #set text(size: 13pt)
    #table(
      columns: 4,
      align: (left, left, left, left),
      table.hline(),
      [*Aspect*], [*Lockne (eBPF)*], [*Userspace proxy*], [*Impact*],
      table.hline(),
      [Processing], [Kernel (TC hook)], [Userspace (LD_PRELOAD)], [Context switch per packet],
      [Data copies], [Zero-copy redirect], [Double copy], [Higher memory bandwidth use],
      [Per-packet latency], [~60 ns], [~10–50 µs], [~100–1000× slower],
      table.hline(),
    )
  ]
]

#pagebreak()

#align(left + horizon)[
  = Limitations & Future Work

  #v(0.8em)

  *Current limitations:*

  - Pre-existing connections: sockets created before Lockne starts are not tracked (no initial cookie mapping).
  - Process hierarchy: child processes of tracked applications are not automatically included in the parent's policy.
  - Map cleanup: entries are not removed on socket close; long-running deployments could exhaust map capacity.
  - WireGuard integration: redirect to existing `wg` interfaces works, but full tunnel lifecycle management is not implemented.

  *Future directions:*

  - eBPF-based socket-close tracking or iterators for safe map cleanup.
  - Fork/clone tracking to handle process trees.
  - Higher-level UI and configuration for production deployment.
  - Automated management of WireGuard tunnels from the Lockne daemon.
]

#pagebreak()

#align(left + horizon)[
  = Conclusion

  #v(0.8em)

  - *Feasibility (RQ1)*:
    eBPF with socket cookies and a two-program design reliably enables per-application routing on Linux.
  - *Performance (RQ2)*:
    The measured overhead in latency, CPU, and throughput is negligible for practical use.
  - *Practicality (RQ3)*:
    The CLI and TUI demonstrate that a user-friendly per-application VPN tool based on this architecture is realistic.

  Lockne shows that a production-ready, kernel-native per-application VPN for Linux is achievable with modern eBPF and Rust tooling.

  Thank you for your attention.
]

