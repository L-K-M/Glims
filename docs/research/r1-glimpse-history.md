<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 1: Glimpse and other GIMP UI forks

# GIMP UI forks and reskins, including Glimpse: history and lessons (research as of 2026-11-04)

Glimpse never changed GIMP's UI. Its code changes were rebranding plus some changed defaults, and the planned new UI (Glimpse NX) got as far as mockups and Rust bindings. The project died because one person was doing most of the coding and nearly all of the support work, it kept changing plans, and it had to keep re-applying its changes onto a moving upstream. Every GIMP UI fork found here followed the same pattern: it froze on an old GIMP version, its single maintainer left, and it was abandoned. Two kinds of project survived. PhotoGIMP changes only GIMP's config files and has no code fork. Seashore and Patchy are separate apps that reuse GIMP's file format or its libraries (GEGL) instead of forking the GIMP application.

## 1. Glimpse Image Editor (July 2019 to May 2021)

### The two GitHub links you gave are mirrors
- The original repo, `github.com/glimpse-editor/Glimpse`, now returns 404. Wayback shows it live on 2023-03-25 and gone by 2023-08-11. The `glimpse-editor` org still exists but has 0 public repos (org record updated 2023-05-21, found via the GitHub API).
- `joshgiesbrecht/Glimpse` is a copy taken on 2019-07-19. Its last commits (2019-07-16, by Bobby Moss) are README edits on the GIMP 2.10.12 tree.
- `azubieta/Glimpse` belongs to Alexis López Zubieta, the AppImage-tooling developer who fixed Glimpse's AppImage. It is the most complete surviving copy, with branches `dev-g210`, `beta-g210`, `glimpse-0-1` and `glimpse-0-2`, and its last commit is 2021-02-11.

### Why it started
- **Trigger:** GIMP's GitLab issue #3617, "Consider renaming GIMP to a less offensive name," opened by Christopher Davis. GNOME moderators locked and hid it.
- **Founder:** Bobby Moss, a technical writer at Oracle (The Register).
- **First announcement**, "So It Begins" (2019-07-06): "Initially this fork will just re-brand the existing v2.10.12… in the future… add new functionality that addresses common user complaints."
  - Sources: https://www.theregister.com/2019/08/28/gimp_open_source_image_editor_forked_to_fix_problematic_name/ and http://web.archive.org/web/20190905123939/https://glimpse-editor.org/posts/so-it-begins/
- **Stated priorities:** fixing the name, replacing the Wilber mascot and updating translations were the primary objectives. UI cleanup was only a secondary one.
- **Self-assessment in Nov 2020:** UI cleanup was "Partially Delivered on 'professional', UX improvements deferred to Glimpse NX." Fixing usability and accessibility problems was "Not Delivered." Source: http://web.archive.org/web/20210320055513/https://glimpse-editor.org/posts/a-year-in-summary/
- **People:** Moss was creator and sole developer of the forked code. Christopher Davis and Luna ("Clipsey") were maintainers and governance. About a dozen others helped with packaging, design and moderation. Source: http://web.archive.org/web/20210507154003/https://glimpse-editor.org/posts/anniversary-plans/

### What it shipped
| Version | Date | Based on | Content |
|---|---|---|---|
| 0.1.0 | 2019-11-22 | GIMP 2.10.12, GEGL 0.4.16, babl 0.1.68 | Renamed strings, new logo and splash, Wilber/"eek" and easter eggs removed, different config paths and process IDs so it can run alongside GIMP, WiX MSI installer, Flatpak |
| 0.1.2 | 2020-03-02 | 2.10.12 | Errata release and packaging |
| 0.2.0 | 2020-08-25 | GIMP 2.10.18 | "introduces helpful configuration settings from PhotoGIMP" (keyboard shortcuts), 64-bit Windows build with G'MIC bundled, rewritten installers, high-contrast icons backported |
| 0.2.2 | never released | — | Moss: "made plenty of progress… but never actually released it" |

Release notes: http://web.archive.org/web/20191130100154/https://glimpse-editor.org/posts/glimpse-0-1-0-release-notes/ and http://web.archive.org/web/20210825203304/https://glimpse-editor.org/posts/glimpse-0-2-0-release-notes/

Usage: at least 86,159 downloads by November 2020. A short Ubuntu Software Center feature in March 2020 produced a spike to 16.9k active Snap users.

### How much was real UI change (my own measurement)
Method: `git diff` between upstream tag `GIMP_2_10_18` (de7f0456) and the tip of `glimpse-0-2` in the azubieta mirror.
- **Scale:** 340 commits on top of upstream, 260 of them by Moss.
- **Translations:** 439 `po*` files changed, about 1.7M lines of churn. This is the rename running through the translations.
- **All C/H files:** +461 / −1,549 lines across 124 files.
- **App, libs, themes and etc only:** +802 / −1,840 lines.
- **Biggest code diffs** were deletions: `gimpcairo-wilber.c` (−1,010), the `tool_manager_cast_spell` easter egg, and display "blink" code. After that came `GIMP_NAME→GLIMPSE_NAME` swaps, the About dialog and help URLs.
- **The "UI" changes** are default settings, not code:
  - `etc/menurc`: Photoshop-style shortcuts.
  - `etc/gimprc.in`: 1920×1080 default image, `toolbox-wilber no`, Dark theme.
  - `etc/toolrc`: different default tool in some groups.
  - Default theme and icon set changed to "System"/"Legacy".
- **Conclusion:** no layout, widget or interaction changes at all. It was about 100% rebranding, packaging and defaults.
- **Even the rename was costly.** The FAQ explains that find-and-replace would break the plug-in API, so they had to swap names selectively, using "GNU I.M.P" wherever upstream code was referenced. Making it installable next to GIMP in distros (the libgimp conflict, issue #7) was never finished.

### Glimpse NX and the other plans (strategy changed four times in two years)
1. **Aug 2019:** soft fork now, then a "hard fork" on GIMP 3 with a "front-end UI rewrite… a few years down the road" (The Register).
2. **Late 2019 to mid 2020:** a custom cross-platform UI toolkit plus a new BSD-licensed editor written in D. After "six months of incubation… cannot be delivered in a two year timeframe." Luna spun it out as "Yuzu Studio". *I found no evidence that Yuzu Studio ever shipped (unverified).*
3. **Sept 2020 plans:**
   - "Glimpse Redux": a private fork of the GIMP 3.0 pre-release code.
   - **Glimpse NX**: "using GNOME technologies… lightweight and accessible user interface for the same underlying components [GEGL/babl]," with Rust "most likely," GPLv3, and ports to Windows and macOS.
   - Source: http://web.archive.org/web/20220707142532/https://glimpse-editor.org/posts/an-exciting-second-year-ahead/
4. **Oct 2020, NX tech-stack work:**
   - Christopher Davis worked on gtk4-rs (GTK4 was still pre-final) and filed GTK4 popover and Wayland bugs.
   - Bilal Elmoussaoui produced Rust bindings for GEGL and babl. Those bindings outlived Glimpse: they are now `gitlab.gnome.org/World/Rust/gegl-rs`, crate v0.4.0, updated 2026-05 (https://crates.io/crates/gegl).
   - Source: http://web.archive.org/web/20210513181557/https://glimpse-editor.org/posts/first-steps-towards-the-future/
5. **Nov 2020:** Redux dropped in favour of NX, with an "alpha in 2021, stable 2022" target (A Year In Summary).

**How far NX got:** only `glimpse-nx-design`, a CC-BY-SA mockup repo with 20 commits from 2020-09-09 to 2021-02-05. It held folders for header-bar, color-picker, primary-window, quick-export and tools, and 7–10 issues (Header Bar, Color Picker, Primary Window Layout, Layers Panel, Personas, and so on). Its stated basis was "Designs… for Glimpse NX should use the GNOME Human Interface Guidelines" (http://web.archive.org/web/20210208024647/https://github.com/glimpse-editor/glimpse-nx-design). That is a GNOME header-bar style, not a 2010-era professional style. *No public NX application code was found.*

### Why it was discontinued (its own post-mortem, 2021-05-23)
http://web.archive.org/web/20210523153529/https://glimpse-editor.org/posts/a-project-on-hiatus/
- "By the second half of 2020, there was just me (Bobby Moss) and a couple of external contributors working on the fork itself. Our other remaining project contributors were occupied with trying to start the UI rewrite called 'Glimpse NX'."
- "Our problem was not a lack of financial contributions or users… we could not find contributors willing to step up and help with non-code tasks like moderating communication channels, triaging bugs, fixing packaging problems, working with the GNU Image Manipulation Program contributors, monitoring our social media accounts, running servers, testing/documenting new releases…"
- Support work "turned working on this project into an unpaid part-time job… I rarely had enough time to actually work on the fork itself." His employer raised conflict-of-interest concerns and he left in February 2021. When he tried to return 10 weeks later, "almost all project activity had ceased."
- **Shutdown:** Open Collective closed with $836 left (Glimpse had given $750 to GIMP in total), repos archived, Discord sign-ups closed.
- **Afterwards:** Snap removed in Jan 2023 (https://forum.snapcraft.io/t/remove-glimpse-editor/33581). Flathub EOL was still pending (https://github.com/flathub/org.glimpse_editor.Glimpse/issues/7). Coverage: https://www.omgubuntu.co.uk/2021/05/glimpse-gimp-fork-project-on-pause/amp and https://itsfoss.com/news/glimpse-gimp-fork-archived/
- **Infrastructure problems in the last months** (http://web.archive.org/web/20210301182405/https://glimpse-editor.org/posts/work-continues-on-glimpse-image-editor-0-2-2/):
  - The EV code-signing certificate was lost because the donor organisation wound down after Brexit.
  - The Snap Launchpad build had been broken since November 2020.
  - The MSYS2 Windows build broke on a dependency change.
  - A GEGL 0.4.28 breakage had to be fixed by backporting.
- **macOS was blocked by upstream:** "until the GNU Image Manipulation Program developers themselves are able to successfully build and package the software for MacOS again, we will not be able to recreate it" (Oct 2020).
- **Rebase cost, in their own words** (http://web.archive.org/web/20220129002636/https://glimpse-editor.org/posts/changing-plans/): they stayed on 2.10.12 because "completely re-basing our hard fork will likely prevent us from working on more meaningful changes." Rebasing to 2.10.18 brought upstream regressions with it (Liquid Rescale).
- **Controversy:** "a four-month-long storm of undeserved criticism & trolling in 2019." An FAQ claim that GIMP's GUI team had "stopped meeting in 2012" was misreported as "GIMP's UI development stopped," and Glimpse had to apologise to upstream (April 2020).

## 2. Other attempts and what happened to them

| Project | Approach | Years | Outcome and cause |
|---|---|---|---|
| **GIMPshop** (Scott Moschella) | Patched GIMP 2.2 with Photoshop-like menus and terms; Windows "Deweirdifyer" plug-in for a single window | 2005 (Mar 30) to about 2006; final base GIMP 2.2.11 | Dead. A third party took gimpshop.com and shipped adware. Moschella in 2014: "I didn't really know how to code, so updating the source to stay current was a huge undertaking… I let it slip away into obscurity." https://news.ycombinator.com/item?id=7483947 · https://en.wikipedia.org/wiki/GIMPshop · https://www.woodwardweb.com/post/2005/04/2005-04-06-gimpshop-for-windows |
| **Film Gimp / CinePaint** | 1998 `HOLLYWOOD` CVS branch of GIMP 1.0.4 with 16-bit/float support; funded by Silicon Grail and Rhythm & Hues | 1998 to 2021 | GIMP's committee rejected merging it ("the one you throw away"; it should be "designed into GIMP 2.0", which became GEGL). It lived while studios (R&H, Sony Imageworks) needed deep colour that upstream lacked. GIMP got high bit depth in 2.9.2 (2015). The FLTK rewrite "Glasgow" files stop in 2007. Last release 1.4.5 on 2021-05-30, now stalled. https://filmgimp.sourceforge.net/docs/history.html · https://sourceforge.net/projects/cinepaint/files/ · https://en.wikipedia.org/wiki/CinePaint. *The year of the rename to CinePaint is unverified.* |
| **GIMP-Painter** (Sygetch/seagetch) | One-person fork adding mixing brushes, textures, toolbar and dropdown panels | 2.6 (about 2009–11), then 2.7/2.8 branches | The 2.6 features never reached 2.7/2.8 (David Revoy, 2011). Revoy kept using 2.6 and later moved to Krita (well known, not re-sourced here). Its default branch is still on the **GIMP 2.8 base**, last commit 2022-12-25. https://www.davidrevoy.com/article89/what-come-next-after-gimp-painter-2-6 · github.com/seagetch/gimp-painter |
| **GIMP single-window mode** (upstream) | Martin Nordholts and Michael Natterer, with Peter Sikking as interaction architect | Work began late 2009; 2.7.3 dev in 2011; shipped as an option in 2.8 (May 2012) | Survived because it was done upstream. It is now the default for first-time users (docs). *Which release made it the default is unverified.* https://www.gimp.org/release-notes/gimp-2.8.html |
| **PhotoGIMP** (Diolinux) | **Not a fork.** Overlay of `toolrc`, `shortcutsrc`, `sessionrc`, `gimprc`, `theme.css`, `contextrc`, tool-options, splash, `.desktop` and icon | 2020 to now | **Alive:** 18.5k stars, PhotoGIMP 3 on 2025-03-17, 3.1 on 2026-07-11, HN front page in May 2026 (198 points). Riding upstream costs one re-port per major version. It can only change what GIMP's config files expose. Glimpse couldn't bundle its assets because of licensing. https://github.com/Diolinux/PhotoGIMP · https://news.ycombinator.com/item?id=48167890 |
| **Seashore** (Mark Pazolli, then Robert Engels from 2017) | Native **Cocoa** macOS editor that grew out of GIMP and uses XCF; GIMP code mostly replaced by CoreGraphics/CoreImage | 2003 to now | Survived by diverging completely, so it never had to rebase. In 2025 it was deprioritised for **Seahorse**, a closed-source paid Swift/SwiftUI/Core Image rewrite requiring macOS 13+: "The donation model hasn't worked," and "Maintaining backwards compatibility has become more and more difficult." https://github.com/robaho/seashore · https://eolcoderllc.github.io/Seahorse/future_of_seashore · https://librearts.org/2019/01/meet-seashore-free-image-editor-for-macos/ |
| **Patchy** (Seth Robinson) | **New** C++/Qt 6 app, MIT licence, Photoshop/PSD-focused; **uses GEGL (117 filters) and G'MIC as libraries**; MCP "AI control"; README says "developed with significant assistance from AI tools" | Repo created 2026-05-29; v1.26 on 2026-11-04 | Very active: about 3,500 commits, about 99% from one author, 662 stars, signed builds for Windows/macOS/Linux plus web. My count of `src/ui` is about 274k lines (593 files). Shows that LLM-era output can reach this scale, but it is too young to judge whether it will last. *Any private history before May 2026 is unverified.* https://github.com/SethRobinson/Patchy |
| Other GEGL front-ends | GNOME Photos (GEGL-based editing) | — | Dropped from GNOME core in GNOME 45 (2023) "due to lack of active maintenance." https://blogs.gnome.org/mcatanzaro/2023/05/10/gnome-core-apps-update/. Small experiments such as GraphPhoto (GEGL + Dear ImGui) are not significant. |
| 2026 GitHub forks | e.g. `Mow3d/gimp` ("Photoshop-like experience") | — | Imported GIMP 3.3.1 source on 2026-06-28; no commits since. |

**Upstream today:**
- GIMP 3.0 shipped 2025-03-16/17. The GTK2→GTK3 port took about 7 years from 2.10.0 (April 2018).
- 3.2 shipped 2026-03-14, followed by 3.2.2, 3.2.4, 3.2.6 and 3.2.8 (2026-11-02) (https://www.gimp.org/news/).
- The roadmap does not list a GTK4 port. Open GUI items include "Better window management," "Improved toolbox," "Toolbar" and "Dockable interaction review" (https://developer.gimp.org/core/roadmap/).
- An upstream GIMP UX team has existed since August 2024 and was active as of 2026-11-03 (https://gitlab.gnome.org/Teams/GIMP/Design/gimp-ux).
- The GIMP FAQ still rejects copying Photoshop's UI.

**Size of the job (my measurements):**
- **Code size (GIMP 3.2.8 tarball):** `app/` is 743k lines of C/H. The GTK-bound parts (widgets 158k, tools 80k, display 69k, dialogs 40k, actions 40k, gui, propgui and menus about 17k) total about 405k. `libgimpwidgets` adds 59k and plug-ins are another 300k.
  - 454 of the 1,168 `.c` files in `app/` call GTK, but only 3 files in `app/core` do.
- **Rate of change:** the GitLab compare API shows about 2,770 commits between 3.0.0 and 3.2.0. The file list was capped at 1,000, and at least 346 of those files are UI files. These numbers are approximate.

## 3. Lessons

**What killed these projects**
1. **Being different only in branding.** Glimpse delivered every primary goal (the name), and that left it with nothing users couldn't get from GIMP. Users switched back as soon as maintenance stopped.
2. **Rebase cost on a fast-moving upstream.** This killed every project that patched GIMP's GUI code:
   - GIMPshop: "huge undertaking."
   - GIMP-Painter: frozen on 2.8.
   - CinePaint: frozen at its 1.0.4-era base.
   - Glimpse: held on 2.10.12, then dropped Redux.
   - Today's churn is about 2,770 commits a year, and the GUI layer, more than half of `app/`, is the part that changes most.
3. **One-person dependency.** Every fork had one coder. Glimpse died about 10 weeks after Moss stepped back.
4. **Non-code work, not money.** Moderation, packaging, signing certificates, CI breakage and the macOS build drowned the only developer. Glimpse had users and donations; what it lacked was people for that work.
5. **Splitting effort and changing strategy.** Glimpse maintained a fork while also starting a rewrite, and tried four strategies in two years: a custom D toolkit, then GTK4 before it was final, plus Rust bindings. Toolkit rewrites stalled every time: CinePaint's FLTK "Glasgow", Yuzu, NX.
6. **Upstream controls things you depend on.** Glimpse's macOS build waited on upstream. Plug-in ABI and libgimp packaging conflicts were inherited. Strained relations with upstream cost the project goodwill.

**What worked**
1. **Config overlays (PhotoGIMP).** Zero code, no rebase. They survived GTK2→GTK3 with a single re-port. They cannot change how the interface behaves, for example multi-select in the layers panel, which HN users still complain about.
2. **Upstream UX work.** Single-window mode was designed and built inside GIMP, so it never had to be maintained separately. The GIMP UX team is the channel for that kind of change now.
3. **Diverging completely and taking only engines or formats.** Seashore went native Cocoa and kept XCF. Patchy is a Qt app that uses GEGL and G'MIC as libraries. Neither has to rebase, because neither follows GIMP's app code.
4. **A funded reason to exist.** CinePaint lasted as long as studios needed a feature GIMP lacked.
5. **Plan for long-term costs.** Seashore's maintainer concluded donations don't fund this kind of work and moved to a paid app. Patchy shows that AI-assisted solo development can produce a large UI in months, but its maintenance over years is not yet proven.

**What I could not verify:** whether Yuzu Studio shipped; whether any Glimpse NX code repo existed (I found none); the exact date the Glimpse org repos were deleted (bracketed by Wayback between March and August 2023); CinePaint's rename year; when single-window mode became the default; Patchy's history before it went public.
