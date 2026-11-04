<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 1: Feasibility memo

# Decision memo: a Rigi-style "friendly GIMP" (2026-11-04)

## 1. Bottom line

Yes, but in one form only. Build a macOS-native AppKit+Rigi app that uses GIMP's GUI-free engine without patching it (Option B), limit it to a focused professional subset, and only commit after a spike passes. I would not do a classic patch-level fork of GIMP's GTK UI, because that is the pattern that killed Glimpse, GIMPshop and GIMP-Painter.

Agents make writing a big front-end cheap: Patchy reached about 274k UI lines in about 5 months, with one author and AI help. They do not remove the rebasing, the testing on real hardware, the packaging, or the community work that actually killed Glimpse. And GIMP's no-genAI rule means nothing you build can ever go upstream.

Reach is limited. Rigi is Mac-only. In GIMP 3.2's first 11 days there were over 1M Windows downloads against about 150k macOS. The biggest unmet need is on Linux, and on the Mac, Affinity is now free. If you want reach, also ship a Rigi-look theme and config pack for stock GIMP (Option D).

## 2. Why Glimpse failed, and what agents change

- **It only ever shipped a rebrand.** Its 0.2 diff against GIMP 2.10.18 was +461/−1,549 lines of C, mostly deletions and name swaps. The "UI" changes were default config files. The planned new UI, Glimpse NX, never got past mockups. *Agents change this one the most.*
- **One coder buried in non-code work.** The post-mortem says the shortage was people for moderation, triage, packaging, signing, testing and dealing with upstream, not money. Activity stopped about 10 weeks after Moss stepped back (http://web.archive.org/web/20210523153529/https://glimpse-editor.org/posts/a-project-on-hiatus/). *Agents help with CI and packaging scripts. They don't fix the single-maintainer risk, hold a signing certificate, or run a community.* You would be the only maintainer, alongside your other apps.
- **Rebase cost.** Glimpse stayed on 2.10.12 because rebasing would crowd out "more meaningful changes." GIMPshop, GIMP-Painter and CinePaint froze the same way. In the last 12 months upstream changed about 27.5k lines in GUI code (372 app/ commits that touched only GUI code), and GTK4 preparation is editing the event APIs the tools depend on. *Agents make each conflict cheaper to resolve. You still have to re-test interaction on real hardware after every rebase.*
- **Changing strategy.** Glimpse had four plans in two years: a custom toolkit in D, pre-release GTK4, Rust bindings. *Agents make starting a rewrite cheaper, so this gets more tempting, not less.*
- **Dependence on upstream, and bad relations.** The macOS build had to wait for upstream. That is fixed now: since 3.2.6 the .dmg is built in upstream's main CI. The 2019 launch soured relations. GIMP now requires a "no AI-generated content" checkbox on every merge request, mandatory since 2026-10-03 (https://gitlab.gnome.org/GNOME/gimp/-/blob/master/.gitlab/merge_request_templates/default.md). *Agents make this worse.*
- **Design judgment.** Agents don't change this. Rigi's guidelines and your taste are the real asset.

## 3. Options

Effort is in agent-assisted person-months (PM).

**A. Patch-level fork, staying on GTK** (menus, tools, defaults, renamed terms, a CSS theme that imitates Rigi)
- **Reused:** everything.
- **New:** theme CSS (GIMP's Default theme is 1,325 lines), reorganized `menus/*.ui` menu files, new defaults. Real behavior changes (a tool options bar, Save/Export, layer multi-select) need C patches in app/widgets.
- **Effort (my estimate):** about 1 PM for data files only; 3–6 PM for behavior patches, plus rebases after that.
- **Maintenance:** data files are cheap. C patches in widgets, which upstream changes 212 times a year, are the Glimpse trap. Renaming terms in the source changes every translation (Glimpse churned about 1.7M lines of translation files). An English override catalog might avoid that, but that is untested.
- **Reach:** all three OSes, but you own Windows, Mac and Flatpak packaging and signing.
- **Risks:** CSS cannot add try-on popovers, tear-off palettes or new layouts. It looks like Rigi without being Rigi. This option is the most likely to repeat Glimpse.

**B. AppKit+Rigi front-end over GIMP's GUI-free core**
- **Reused:** about 394k lines confirmed free of GTK (core, pdb, paint, gegl, xcf, plug-in host, config, text, base libraries), linked the way the headless gimp-console build does it. The intended entry point is the 27-hook `GimpGui` vtable plus a `GimpDisplay` subclass. `GimpDrawableFilter` already has preview, split, commit and abort, which maps almost exactly onto Rigi's try-on contract of one undo step per session.
- **New:**
  - a GObject bridge, 5–10k lines;
  - Rigi extensions, 6–10k lines (slider field, tool grid, docking, dialog frame, gray/dark themes, accessibility);
  - the app front end, 50–80k lines of Swift. The reports disagree here: the architecture report says 30–60k for a focused subset and 80–150k for parity.
  - The tools must be rewritten or run through a stand-in for GIMP's display shell; they have 770 GDK references and use 36 shell functions.
  - Native dialogs generated automatically from parameter specs, for plug-in procedures and GEGL operations.
- **Effort (inferred):** 4–8 PM to a beta of the focused subset; 12–24 PM for parity.
- **Maintenance:** if you use upstream's libraries unpatched at stable tags, churn shows up as broken internal APIs, not merge conflicts. Core gets 265 commits a year and has no stable API, but agents handle this kind of fix well. Each new upstream feature (link and vector layers, CMYK in 3.4, the new XCF format) still needs native UI.
- **Reach:** macOS only.
- **Risks:**
  - Bridging GLib's main loop to NSRunLoop, including the nested loops used during plug-in calls.
  - Canvas performance: projection rendering, display color profiles, HiDPI, tablet input.
  - Interactive plug-ins still open GTK windows, so you have to ship GTK3 anyway.
  - Rigi's popover try-on is wrong for filters, because a click outside the popover commits a full-resolution render. Filters need a dialog instead.
  - GPLv3 probably rules out the Mac App Store (inferred).
  - The audience is estimated at 5k–30k users (unverified).

**C. New editor built directly on GEGL and babl (not a GIMP fork)**
- **Reused:** GEGL operations and babl. Patchy also uses G'MIC.
- **New:** document model, layers, undo, selection, painting, text, transforms, XCF import/export.
- **Effort (inferred):** 8–18 PM to something credible.
- **Maintenance:** lowest exposure to upstream changes. You can pick any license: Patchy is MIT on top of GEGL, though GEGL's and babl's LGPL terms need checking.
- **Reach:** Mac only, if built with Rigi.
- **Risks:**
  - XCF is changing: GIMP lead developer Jehan is building a zipped-XML successor.
  - You lose GIMP's plug-in ecosystem unless you reimplement part of its procedure database.
  - You compete directly with Patchy (cross-platform, GEGL-based, AI-built, very active) and with Seashore/Seahorse. Seashore's maintainer concluded that donations don't fund this kind of work.

**D. Upstream-friendly theme and config pack (plus upstream UX work)**
- **What it is:** a PhotoGIMP-style overlay with a Rigi-look `theme.css` plus GIMP's shortcut, tool, session and preference files. GTK3 CSS supports gradients, shadows, text shadows and minimum heights.
- **Effort:** 2–6 agent-weeks, then one re-port per major version. That is how PhotoGIMP survived GTK2→GTK3, with about 570k downloads (https://github.com/Diolinux/PhotoGIMP).
- **Reach:** all platforms. It is the only option that helps Linux and Windows users soon.
- **Limits:** it can only change what the config files expose. Whether the theme also applies to plug-in dialogs is unverified. Code contributed upstream must be written by hand. The GUI items you would want on the roadmap (toolbox, toolbar, window management, docking) haven't been started. The UX team only accepts incremental change; it closed gimp-ux #76, a wholesale UI overhaul proposal, as not feasible.

**E. Contribute to Patchy** (MIT, Qt 6, AI-friendly, on all three OSes, https://github.com/SethRobinson/Patchy). Rigi code doesn't carry over, but its guidelines could become a classic Qt style. Patchy is only 5 months old and about 99% of it is from one author.

## 4. Recommendation

Ship D now and run a B spike in parallel. Do nothing from A beyond data files. Keep C and E as fallbacks.

- **Why B:** it is the only option where Rigi is actual code rather than a style reference, and it reuses GIMP's ~350k-line engine without touching any GTK code. What keeps it from becoming Glimpse is discipline: almost no patches to GIMP source, and upstream consumed only at stable tags.
- **Bridge design:** write the bridge (vtable, display stand-in, tool event layer) in plain C/GObject and keep it independent of any toolkit, so a later Qt version could reuse it. Qt's GLib event dispatcher should make that easier (inferred).
- **Linux:** Rigi contributes nothing there. The idea that Lucerne's Qt port "follows the same guidelines" doesn't hold up: it contains no Rigi-like code and was written two months before Rigi existed. Linux gets D now. A Qt front-end (60–100k lines of C++) only makes sense if B proves both the bridge and the demand.
- **Licensing:** A and B are GPLv3 as combined works. Rigi's Unlicense is compatible, and your Swift code ships under GPLv3. Distribute as a notarized DMG or through Homebrew. C can use any license if it contains no GIMP application code.
- **Naming:** "GIMP" is a registered US trademark (Reg. 8270101, owned by the GNOME Foundation, registered 2026-05-26, https://tsdr.uspto.gov/statusview/sn99400712), and upstream says it defends the name actively. Pick a distinct name, describe it only factually ("uses GIMP's engine"), and ask licensing@gnome.org. Use your own config directory and bundle ID, and never conflict with an installed libgimp; Glimpse never solved that.
- **Relations with upstream:** disclose LLM use as you already do, present it as a Mac front-end rather than a replacement, keep its bugs off upstream's tracker, and donate to GIMP.

## 5. Phase-0 spike (3 weeks of agent work, on GIMP 3.2.8)

- **Week 1:** build GIMP's 14 GUI-free static libraries and its base libraries as an arm64 artifact that SwiftPM can use. Implement a minimal GimpGui vtable and GimpDisplay subclass. Drive GLib's main loop from NSRunLoop.
- **Week 2:** a CALayer canvas fed from GIMP's projection (the composited image), rendering the visible area first. Paintbrush driving `gimp_paint_core_*` with pressure from NSEvent. A layers palette through PaletteCenter. Open and save XCF.
- **Week 3:** one GEGL filter through GimpDrawableFilter in a Rigi dialog with live and split preview. One plug-in run non-interactively from an auto-generated dialog. A rebase drill onto master (3.3.1). In parallel, the D theme pack on Linux and Mac.

**Go only if all of these hold:**
1. The patch to GIMP source stays under about 300 lines. Anything more means you are drifting into A.
2. A 3.2 XCF with layer groups, text, masks and non-destructive filters round-trips with identical pixels, checked by flattening both files with gimp-console.
3. Pan, zoom and brush latency on a 50 MP, 20-layer file are no worse than GIMP 3.2.8 on the same Mac.
4. Committing a filter creates exactly one undo step; cancelling creates none.
5. A synchronous plug-in call, which runs a nested main loop, completes 100 times without hanging.
6. The rebase drill builds and passes criteria 2–5 within 2 agent-days.
7. A name without "GIMP" is cleared, and you accept owning a Mac-only GPLv3 app alone for 3+ years.

**No-go:** stop if the tools or display need deep stand-ins for GTK-bound code, if the main-loop bridge needs patches to GLib or GIMP core, or if performance needs a forked copy of GIMP's display code. Then drop B, keep D, and choose between a smaller version of C and contributing to Patchy.

**Where the reports disagree or are unverified:**
- **Glimpse usage:** 86k total downloads vs about 18k on Flathub. These measure different things.
- **Glimpse repo:** deleted between March and August 2023 per Wayback, vs "archived around May 2024."
- **Front-end size:** estimates range from 30k to 150k lines.
- **Estimates only:** the niche size and every effort figure above.
