<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 1: Upstream GIMP status and UX direction

# Upstream GIMP, state as of 4 Nov 2026: releases, UX direction, macOS, complaints, naming

Everything here was checked on 2026-11-04 against gimp.org, developer.gimp.org (I cloned both site repos), the GitLab API and USPTO TSDR. Items marked **[unverified]** come only from secondary sources or are my inference.

## 1. Releases and roadmap

**Release timeline** (from the gimp.org news archive and GitLab tags, https://www.gimp.org/news/):

| Date | Release |
|---|---|
| 2025-03-16 | **3.0** |
| 2025-03-23 / 05-18 / 10-06, 2026-01-24 | 3.0.2, 3.0.4, 3.0.6, 3.0.8 (bugfix releases) |
| 2025-06-23, 2025-09-01 | 3.1.2 and 3.1.4 (development releases) |
| 2025-11-17, 2025-12-15, 2026-03-02 | 3.2 RC1, RC2, RC3 |
| 2026-03-14 | **3.2** |
| 2026-03-28, 04-19, 09-10, 11-02 | 3.2.2, 3.2.4, 3.2.6, **3.2.8** (latest stable) |

- There is no 3.3.x development release yet. The newest tag is `GIMP_3_2_8`. The August 2026 update says 3.3.2 is waiting on roadmap items.

**GIMP 3.0** (https://www.gimp.org/release-notes/gimp-3.0.html):
- Port to GTK3, which brought HiDPI scaling, better tablet support, CSS themes and native Wayland.
- Non-destructive (NDE) filters, saved in XCF files.
- Colour spaces beyond sRGB (the "space invasion" groundwork).
- Multiple selection of layers, channels and paths.
- Paste now creates a new layer instead of a floating selection.
- Auto-expanding layers and off-canvas editing.
- Welcome dialog, better text support, and a new Wilber logo by Aryeom Han.

**GIMP 3.2** (https://www.gimp.org/news/2026/03/14/gimp-3-2-released/, https://www.gimp.org/release-notes/gimp-3.2.html):
- Link Layers (similar to Photoshop's linked smart objects).
- Vector layers created with the Path tool.
- MyPaint brushes ported to v2, plus an Overwrite paint mode.
- An on-canvas text editor you can move, with Ctrl+B and similar shortcuts.
- Import of Photoshop .acv/.alv/.pat presets and more PSD layer styles.
- Small UX fixes: Shift+X switches to the previous tool, images can be dropped on the tab bar, and a new "System" colour scheme.

**3.2.6** (https://www.gimp.org/news/2026/09/10/gimp-3-2-6-released/):
- Fixes for 28 CVEs.
- A GIMP SDK for building plug-ins against official packages.
- A large macOS overhaul (section 3).
- First preparation for GTK4: "Even though we are not yet planning a GTK4 port, it doesn't hurt to start preparing for it!"

**3.2.8** (https://www.gimp.org/news/2026/11/02/gimp-3-2-8-released/): bug fixes, better right-to-left text, and macOS fixes (section 3).

**Roadmap** (https://developer.gimp.org/core/roadmap/, page and data files edited in Oct–Nov 2026):
- **3.4:**
  - Done: filters on layer masks.
  - In progress: a modern default resource set, vector layer masks, a Shape tool, a high-end CMYK backend, PSD layer effects and adjustment layers (import and export), and possibly OpenCL.
  - New XCF format: "Discussed" on the roadmap, but the August 2026 update says Jehan is actively building a zipped-XML format (https://www.gimp.org/news/2026/08/16/dev-update-august-2026/).
  - Auto-save: not started.
  - Foreground Select rework: being designed.
- **3.6:** core animation (the plug-in is being rewritten), proper page support, and an inpainting tool.
- **GUI section** (all four rows are "No", i.e. not started): "Improved toolbox", "Toolbar (customizable)", "Better window management (one single-window mode that can do everything)", and "Dockable interaction review". The page text adds: "a horizontal toolbar is often wished for, as well as improvements of dockable management. These are all topics which could be redesigned and worked on."
- **Other rows:** Text tool rewrite is in progress ("closer to well-known interactions, such as in LibreOffice"). A better layer-effects GUI is "Specified", and a node/graph view is "Discussed".
- **Space invasion:** spot colour and an Indexed mode review are not started. CMYK work is under 3.4.
- **GTK4:** the roadmap has no GTK4 row and no GIMP 4.0. The FAQ answer is "Please give us some time to breathe" (https://www.gimp.org/docs/userfaq.html). A "9. Initiative: Port to GTK4" label exists on the tracker, with about 10 open issues and 6 merge requests, all preparatory.
- **Upcoming 3.4 features already merged or in progress** (August 2026 update):
  - Native platform file chooser dialogs (Alx Sa), after "**strong** feedback" about the GTK3 chooser.
  - All 78 cursors converted to SVG, and new lock icons (Denis Rangelov).
  - A redesigned Search Actions dialog.
  - Many SpinEntry widgets replaced with SpinScale.
- **GSoC 2026:** includes a redesign of the Keyboard Shortcuts dialog with importable/exportable shortcut profiles (MR !2843, https://www.gimp.org/news/2026/07/18/gsoc-2026-midpoint-progress/).

## 2. UX governance and how receptive upstream is

**Design team**
- A dedicated UX tracker was created on 2024-08-08: https://gitlab.gnome.org/Teams/GIMP/Design/gimp-ux. On 2026-11-04 it had 624 open and 459 closed issues, many migrated from the old Bugzilla. Its last activity was 2026-11-03.
- It was announced in the Oct 2024 development update (https://www.gimp.org/news/2024/10/05/development-update/): "looking to build a team of designers ... that also respect existing user's workflows". Designer **Denis Rangelov** is the main design volunteer.
- The FAQ credits Aryeom Han's long collaboration with Jehan as the origin of the tracker.
- Specifications live at https://developer.gimp.org/core/specifications/ (layers, locks, layer-effects UI, theme, welcome dialog, and others).
- Historically, Peter Sikking (Man+Machine Works) was UX architect from 2006 to 2013 (https://gui.gimp.org).

**Most-upvoted design proposal**
- gimp-ux #76, "GIMP Overhaul Proposal: Adwaita Mode" (24 upvotes, by rangelovd), proposed floating tool panels, icon buttons instead of checkboxes, and similar changes.
- It was closed in Aug 2025 with an edited header: "Moving straight to Adwaita is not feasible. However we **can** improve from where we are." That header strongly suggests upstream only accepts incremental change.

**Official stance on Photoshop-likeness and UI change** (FAQ, last edited Jun–Oct 2026):
- Spec-driven design is "superior to merely copying others' user interaction decisions."
- "We should not change things unless we have good reasons to."
- On adding opt-out checkboxes for disliked changes: "we respectfully disagree to make extra behaviour switches."
- From the 3.0 notes: "We know many people have strong opinions of GIMP's UI, and we want to make good, well-reasoned decisions about UX improvements."

**Jehan on forks** (LinuxFR, 2019-08-28, https://linuxfr.org/nodes/117950/comments/1780795):
- "on a rien contre les forks" ("we have nothing against forks").
- Glimpse "a été hostile du début à la fin" ("was hostile from start to finish") and its developers had "never contributed a single line of code to GIMP".
- GIMP has "never refused quality code for any feature".

**Generative AI: hard ban, stricter than GNOME overall**
- The merge request template now requires a checked box: "I declare this MR have no AI-generated content (neither code nor text, images…), only human created works" (https://gitlab.gnome.org/GNOME/gimp/-/blob/master/.gitlab/merge_request_templates/default.md). Jehan added the rule on 2025-03-22. It became a mandatory checkbox on 2026-10-03.
- The developer-access rules were extended on 2026-05-24: "We have a strict no-genAI rule (be it for code, images, text…) ... do not use your commit rights to stealthily add LLM-generated code" (https://developer.gimp.org/core/maintainer/giving-developer-right/).
- The internship rules (2026-02-18) say AI use leads to rejection or a failed project.
- The 3.2.6 news post: "as long as you don't use genAI in your toolset, everyone is very welcome."
- GNOME as a whole has no foundation-wide policy ("Sadly we don't have it", https://discourse.gnome.org/t/does-gnome-has-an-official-stance-on-llm-usage/34364). Individual projects such as Loupe, libadwaita and Calendar ban it. GNOME Circle tightened its AI rules in 2026 **[secondary sources only]**.

**Takeaway:** upstream welcomes small, spec-backed UX fixes from humans. It has not started any of its own big GUI-structure items and rejected a wholesale reskin. LLM-written patches cannot be upstreamed at all, so an LLM-driven fork would be a permanent hard fork.

## 3. macOS

**Who maintains it**
- **Bruno Lopes** has done the work since 2025-12-19, on a MacBook Pro M5 bought with donations. He made 38 of the 40 commits to `build/macos` since Dec 2025.
- Before that it was mainly Lukas Oberhuber and Gabriele Barbero. The old build ran through a separate gimp-macos-build repo, a GitHub mirror, CircleCI and MacStadium.
- Since 3.2.6 the .dmg is built in the main CI alongside Linux and Windows, and GIMP builds with MacPorts and Homebrew.
- The project itself says it "traditionally" has fewer macOS developers.

**Integration status**
- **Menu bar:** GIMP uses the macOS global menu bar. A GTK3 regression where the menus didn't follow Mac conventions was tracked in #9322 and closed in Aug 2024. Since 3.2 the GIMP menu has Hide GIMP and Show All, and Quit follows the normal macOS shutdown. Since 3.2.6 the GIMP, Windows and Help menus match the standard macOS menus.
- **3.2.6 fixes:** title bars and scrollbars follow system settings, Cmd works like Ctrl for number inputs, accent colours are used, and plug-ins no longer appear in the Dock.
- **3.2.8 fixes:** title bars and menu icons render again on macOS 27, screenshots use ScreenCaptureKit, Intel builds are notarized, and the long-standing "Blank UI" startup bug should be fixed.
- **Still missing:** native file dialogs (coming in 3.4). The widgets themselves are GTK3 drawn, not native AppKit controls.

**Quality signals**
- 251 issues labelled `OS: macOS` were filed since Mar 2025, but only 13 are open. Regressions after 3.2.6 included a black screen, clipboard breakage, repeated Accessibility permission prompts, a macOS 12 launch failure and a malware flag on Sequoia.
- Garbled UI fonts were fixed through a Pango update during the 3.0 release candidates.
- GIMP 2.10 had a history of slow painting on Apple Silicon (#10353, about 6 fps). I found no systematic 3.x performance benchmarks **[unverified]**.
- Hacker News on 3.0: "GIMP is notoriously bad on macOS" (https://news.ycombinator.com/item?id=43393822).

## 4. Most-cited usability complaints, 2024–2026

1. **Save vs Export.** Save only writes XCF, and closing after an export still triggers an unsaved-changes warning.
   - Creative Bloq 3.0 review (Lance Evans, 2024-12-16): "unforced error", and the format popup opens off-screen (https://www.creativebloq.com/photography/photo-editing-software/gimp-3-0-review-20-years-on-from-2-0-has-gimp-kept-up-with-the-times).
   - Hacker News, 3.0 thread: "user-hostile", "Absolutely infuriating behavior".
   - gimp-ux #844 asks to make the Export popup optional.
   - On 2026-06-28 the FAQ dropped "Save/Export" from its question title and removed the link to the "Saver" plug-in workaround (https://gitlab.gnome.org/Infrastructure/gimp-web/-/commit/e4b47ff6e60f59678aa7c2b0c2c4ab4ddd4bbd7e).
2. **Toolbox and tool grouping.** Poor use of screen space, no reasonable customisation, and shortcuts that differ from Photoshop and Krita (B, C). Sources: Creative Bloq; the roadmap's unstarted toolbox item; gimp-ux #1085.
3. **Non-standard shortcuts.** Zoom is -/+ instead of Ctrl-/+ (gimp-ux #939, May 2026: "New users at work have complained"). No delete-layer shortcut (#515). Redo as Ctrl+Shift+Z (#94). Multiple shortcuts per command (#239).
4. **Layer and selection model.** Floating selections and anchoring (fixed by default in 3.0 but still cited). Fixed layer boundaries (partly addressed by auto-expand). The Move tool can't move a selection's contents (#682).
   - gimp-ux #800 (Dec 2025) lists layer-list problems: no mouse-only multi-select, one mask per layer, masks can't be dragged or named, text layers have no preview, and you can't tell layer types apart at a glance.
5. **Text tool.** Font previews too small, no text warp, problems with font selection (#391, #392). A rewrite is on the roadmap as in progress. Forum reports: https://www.gimp-forum.net/Thread-Gimp-3-2-2-and-3-0-text-tool-problems
6. **Terminology.** "Free Select" instead of Lasso, "Fuzzy Select", "Foreground Select". Inconsistent capitalisation (gimp-ux #250). Drop shadow and glow are hidden under "GEGL Styles" (Hacker News, 3.0 thread).
7. **Dialogs.**
   - The GTK3 file chooser, now being replaced.
   - The New Image dialog: no create-from-clipboard, templates in one long list (Creative Bloq; gimp-ux #533).
   - The Preferences "Folders" pages (#389).
   - Tiny icons in the quit dialog (#866).
8. **Docking and windows.** The split between single- and multi-window modes, and fiddly dockables. Upstream acknowledges both on the roadmap but hasn't started.
9. **Discoverability and learning curve.** Common lines: "Gimp needs a Blender 2.8 moment" (Creative Bloq); "still feels like it was designed by engineers for engineers" (2026 blog coverage); Hacker News Aug 2026: "enduring bad UX for decades ... efforts to improve it are unwelcome" (https://news.ycombinator.com/item?id=49326156).
10. **Demand signal.** PhotoGIMP (Diolinux), a config patch giving a Photoshop-like layout and shortcuts, has about 18.5k GitHub stars and was updated Oct 2026 (https://github.com/Diolinux/PhotoGIMP; Hacker News May 2026: https://news.ycombinator.com/item?id=48167890).

## 5. Trademark and naming

**Registered trademark**
- "GIMP" is a **registered US trademark**: Reg. No. 8270101 (serial 99400712), filed 2025-09-18, registered 2026-05-26, owned by the **GNOME Foundation**.
- It covers Class 9 image-editing software, with first use claimed from 1995. There is also an international (Madrid) registration, No. 1914175 (https://tsdr.uspto.gov/statusview/sn99400712).
- I found no published GIMP-specific trademark usage policy. The GNOME Foundation trademark page lists GNOME, GTK, Flatpak and Flathub but not GIMP, and points to licensing@gnome.org (https://foundation.gnome.org/legal-and-trademarks/).
- **Inference:** a fork should not carry "GIMP" in its name without permission. The GPLv3 lets the code be forked but explicitly allows trademark rights to be withheld.

**Upstream's position**
- The current FAQ (rewritten by Jehan on 2026-06-30, https://gitlab.gnome.org/Infrastructure/gimp-web/-/commit/dec97e90f8cb0cd06e7596087dccbc627b5cba45) says: "We have been fighting for the trademark 'GIMP' ... fake 'GIMP' apps on stores ... we need to keep control of the name". It also says the team is "_not_ opposed in principle to changing the name". An internal experiment makes "the program name configurable" **[no implementation found]**.
- The old FAQ text it replaced said: "exercise your software freedom to fork and rebrand GIMP."
- In 2017 Simon Budig asked an app developer to choose a different name, preferring to "reserve the name 'GIMP' for an app that uses gimp's technology with a suitable UI layer" (https://lists.gnome.org/archives/gimp-developer-list/2017-April/msg00001.html).

**Glimpse**
- Its README said the project existed mainly to get "a less problematic name" and called upstream's explanation inadequate. It promised GUI fixes "in future versions" (https://github.com/joshgiesbrecht/Glimpse).
- It went on hiatus in May 2021 for lack of contributors (it said it "could not find contributors willing to step up and help with non-code tasks"), not lack of money, and told users to support GIMP instead (https://itsfoss.com/news/glimpse-gimp-fork-archived/, published 2021-05-27).
- The original `glimpse-editor/Glimpse` GitHub repo now returns 404.

## What this means for a Rigi-style fork
- An LLM-built fork could never upstream anything, so it would carry the full cost of rebasing onto GIMP's moving codebase: the GTK4 prep, the new XCF format and the native file choosers.
- A non-"GIMP" name is required.
- Upstream does not plan to rebuild the toolbox, toolbar, window management or docking itself, and that is the space a fork would fill.
- The new in-tree macOS build pipeline makes Mac builds of a fork much easier to produce.
