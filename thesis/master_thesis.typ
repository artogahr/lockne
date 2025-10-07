// ===============================================
// DOCUMENT SETUP (Conforms to CZU FEM Guidelines)
// ===============================================
#set document(
  author: "Artoghrul Gahramanli, BSc.",
  title: "Lockne: Dynamic Per-Application VPN Tunneling with eBPF and Rust",
)
#set page(
  paper: "a4",
  numbering: "1",
  margin: (top: 30mm, bottom: 25mm, left: 35mm, right: 20mm),
)
#set text(
  font: "New Computer Modern",
  size: 12pt,
  lang: "en",
)
#set par(
  justify: true,
  leading: 0.65em,
  first-line-indent: 1.25cm,
)
#show heading: it => {
  // the block is so that headers aren't left on a previous page.
  // If there's no space for some text after the header,
  // it will get moved to the next page
  block(breakable: false, {
    if it.level > 1 { v(0.5em) } else { v(1.5em) }
    strong(it.body)
    v(0.5em)
  })
}

#let bibliography-style = "iso-690-numeric"

//===========================================
// PAGE 1: TITLE PAGE
// Replicates the official template exactly.
// ===============================================
#pagebreak(to: "odd", weak: true)
#set page(numbering: none) // No page number on title page
#align(center)[
  #text(14pt)[Czech University of Life Sciences Prague]
  #v(1em)
  #text(14pt)[Faculty of Economics and Management]
  #v(1em)
  #text(14pt)[Department of Information Technologies] // Fill this in

  #v(3cm)
  #image("czu-logo.png", width: 8cm) // You will need to download the CZU logo and save it as "cuz-logo.png"

  #v(3cm)
  #text(18pt, weight: "bold")[Master's Thesis]

  #v(2cm)
  #block(width: 80%)[
    #text(
      16pt,
    )[Lockne: Dynamic Per-Application VPN Tunneling with eBPF and Rust]
  ]

  #v(2cm)
  #text(14pt)[Artoghrul Gahrammanli, BSc.]

  #v(1fr)
  #text(12pt)[© 2026 CZU Prague] // Put your expected year of submission
]
#pagebreak()


// ===============================================
// PAGE 2-3: OFFICIAL THESIS ASSIGNMENT
// IMPORTANT: You get this from the university system IS.CZU.cz
// You must export it as a PDF and insert it here.
// ===============================================
#set page(numbering: none)
#align(center)[
  !!!
  1. Make sure your thesis assignment is approved by the Dean, Head of Department and Supervisor.
  2. Export the thesis assignment to PDF from IS.CZU.cz.
  3. Replace these pages with the PDF pages of the assignment.
  !!!
]
// To insert the PDF pages, you would comment out the text above and use:
// #image("assignment_page_1.pdf", width: 100%)
// #pagebreak()
// #image("assignment_page_2.pdf", width: 100%)
#pagebreak()


// ===============================================
// PAGE 4: DECLARATION
// ===============================================
#set page(numbering: none)
#v(10em)
#align(left)[
  #text(16pt, weight: "bold")[Declaration]
  #v(2em)
  I declare that I have worked on my master's thesis titled "Lockne: Dynamic Per-Application VPN Tunneling with eBPF and Rust" by myself and I have used only the sources mentioned at the end of the thesis. As the author of the master's thesis, I declare that the thesis does not break any copyrights.
  #v(4em)
  In Prague on date of submission
  #v(3em)
  #line(length: 7cm)
]
#pagebreak()


// ===============================================
// PAGE 5: ACKNOWLEDGEMENT
// ===============================================
#set page(numbering: none)
#v(10em)
#align(left)[
  #text(16pt, weight: "bold")[Acknowledgement]
  #v(2em)
  I would like to thank my supervisor, Ing. Martin Havránek, Ph.D., for his guidance and support during my work on this thesis.
]
#pagebreak()


// ===============================================
// PAGE 6: ABSTRACT (ENGLISH)
// ===============================================
#set page(numbering: none)
#v(5em)
#align(left)[
  #text(16pt, weight: "bold")[Abstract]
  #v(2em)
  // TODO: Write a 15-line summary here after you have some results.
  This thesis presents "Lockne", a novel system for dynamic, per-application network traffic routing on Linux systems. Existing solutions for traffic control suffer from performance overhead by operating in userspace or lack user-friendliness by relying on complex containerization. Lockne addresses this gap by leveraging the kernel's eBPF framework to perform efficient packet redirection at a low level, coupled with a robust control plane written in Rust. The system allows users to define policies that map specific applications to designated WireGuard VPN tunnels, while other applications maintain a direct internet connection. This work details the architecture of Lockne, from the eBPF programs attached to network hooks to the userspace daemon that manages policies and interfaces. The thesis culminates in a performance evaluation, benchmarking Lockne's latency and CPU utilization against traditional proxy-based tools, demonstrating the significant advantages of a modern, in-kernel approach to fine-grained network control.
  #v(3em)
  #text(weight: "bold")[Keywords:] eBPF, Rust, VPN, WireGuard, kernel programming, network security, traffic routing, process isolation, systems programming, networking.
]
#pagebreak()


// ===============================================
// PAGE 7: ABSTRACT (CZECH)
// You will need help from a translation tool or native speaker.
// ===============================================
#set page(numbering: none)
#v(5em)
#align(left)[
  #text(16pt, weight: "bold")[Abstrakt]
  #v(2em)
  // TODO: Translate the English abstract here. Use DeepL or Google Translate for a first pass.
  Tato práce představuje "Lockne", nový systém pro dynamické směrování síťového provozu na základě jednotlivých aplikací v operačních systémech Linux. Stávající řešení pro řízení provozu trpí výkonnostní režií způsobenou provozem v uživatelském prostoru nebo postrádají uživatelskou přívětivost kvůli spoléhání na složitou kontejnerizaci. Lockne tento nedostatek řeší využitím frameworku eBPF v jádře k efektivnímu přesměrování paketů на nízké úrovni, ve spojení s robustní řídicí rovinou napsanou v jazyce Rust. Systém umožňuje uživatelům definovat pravidla, která mapují konkrétní aplikace na určené VPN tunely WireGuard, zatímco ostatní aplikace si zachovávají přímé připojení k internetu. Práce podrobně popisuje architekturu Lockne, od programů eBPF připojených k síťovým hookům až po démona v uživatelském prostoru, který spravuje pravidla a rozhraní. Práce vrcholí hodnocením výkonu, které srovnává latenci a využití CPU systému Lockne s tradičními nástroji založenými na proxy, a demonstruje tak významné výhody moderního přístupu k jemně zrnitému řízení sítě v jádře.
  #v(3em)
  #text(weight: "bold")[Klíčová slova:] eBPF, Rust, VPN, WireGuard, programování jádra, síťová bezpečnost, směrování provozu, izolace procesů, systémové programování, sítě.
]
#pagebreak()



// ===============================================
// TABLE OF CONTENTS
// Typst will generate this automatically!
// ===============================================
#set page(numbering: "I") // Roman numerals for front matter
#outline(
  title: [Table of content],
  depth: 3,
  indent: auto,
)
#pagebreak()




// ===============================================
// MAIN THESIS BODY
// ===============================================
#counter(page).update(1) // Reset page numbering to 1 for the first chapter

// This is where your previous proposal content goes.
#include "chapters/01-introduction.typ"
#include "chapters/02-objectives.typ"

// THIS IS YOUR FOCUS FOR THE NEXT WEEK
#pagebreak()
#include "chapters/03-literature-review.typ"

// These are placeholders for your future work
#pagebreak()
#include "chapters/04-practical-part.typ"
#include "chapters/05-results.typ"
#include "chapters/06-conclusion.typ"
#include "chapters/07-references.typ"
