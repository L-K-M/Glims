<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 1: Review (product)

Would change recommendation: True

## Summary

Most of the memo's factual claims check out. GIMP 3.2's download split, free Affinity, the 3.2.6 macOS CI change, the GIMP trademark registration, the roadmap status, gimp-ux #76, PhotoGIMP's numbers, Patchy's profile and Seashore's donation verdict are all right. Several claims about Glimpse are wrong or overstated:
- It did not stay on 2.10.12; 0.2.0 rebased onto 2.10.18.
- Its post-mortem says relations with GIMP contributors were positive.
- Its repos were archived in May 2021 and deleted around 2023, not archived in 2024.
- Flathub shows about 53k installs, not 18k.
- 'Signing' is not in the post-mortem, and the memo omits the pandemic and employer causes.

The no-AI checkbox is new as of 2026-10-03, but the no-AI policy is older, and the checkbox is not enforced on core developers. 'Notarized DMG or Homebrew' hides that the user currently ships unsigned apps and that Homebrew now requires Gatekeeper-passing builds. The memo also omits Pixelmator Pro, underrates Patchy (free, notarized on the Mac, imports XCF, about 968k lines in 5 months), and treats a one-week-old Rigi 0.1.0 as the main asset.

The recommendation does not follow well from the evidence. D is the CSS-only approach the memo itself calls 'Rigi-looking without being Rigi', in a niche PhotoGIMP already holds. B's spike has no demand gate, even though the competition is free or cheap. Before any spike, the user should decide whether this is a passion project, run a cheap demand test, and set up signing, notarization and a security-update process. Contributing to Patchy, or putting a Rigi front-end on Patchy's MIT core, deserves a real look alongside B.

## Claims checked

### CONFIRMED: In GIMP 3.2's first 11 days there were over 1M Windows downloads against about 150k macOS.

**Evidence.** GIMP's Mastodon post of 2026-03-25 says "Windows installer already downloaded over a million times" and "macOS DMGs downloaded more than 150,000 times", and gives 3.2.0's release date as March 14 (https://notestock.osa-p.net/@GIMP@floss.social/20260325/view). The GIMP_3_2_0 tag is dated 2026-03-14.

**Correction.** The figures count only the Windows installer and the DMGs. They leave out the MS Store, Flatpak, Snap and distro packages, so they say nothing about Linux demand.

### UNVERIFIABLE: The biggest unmet need is on Linux.

**Evidence.** The memo gives no data for this. The download numbers it cites leave Linux out. Patchy (MIT, Photoshop-style workflows) now ships Linux as a Flatpak and an AppImage (https://github.com/SethRobinson/Patchy), which narrows any gap that existed.

### CONFIRMED: On the Mac, Affinity is now free.

**Evidence.** Canva relaunched Affinity on 2025-10-30 as one free app combining Photo, Designer and Publisher, for macOS and Windows. It needs a Canva account, and the generative AI features are paid (https://www.macrumors.com/2025/10/31/canva-relaunches-affinity-free-app/, https://tidbits.com/2025/10/31/canvas-affinity-combines-photo-designer-and-publisher-into-one-free-app/).

**Correction.** Affinity is free on Windows as well, so this hurts Option D's Windows reach too, not just the Mac. The memo also leaves out Pixelmator Pro. Apple now sells it for $49.99 once or inside Apple Creator Studio at $12.99 a month (https://daringfireball.net/linked/2026/01/13/apple-creator-studio).

### CONFIRMED: Glimpse only ever shipped a rebrand; its UI changes were default config files; Glimpse NX never got past mockups.

**Evidence.** 0.2.0 added PhotoGIMP shortcuts, custom config settings, a logo, icon packs and an installer (https://www.omgubuntu.co.uk/2020/08/glimpse-0-2-0-released-based-on-gimp-2-10-18). Libre Arts wrote: "Neither project was successful, but this is one of the mockups," and noted that the NX mockup repo was removed (https://librearts.org/2023/11/radical-redesign-of-gimp/). I could not check the +461/-1,549 line diff because the GIMP tags are missing from the surviving forks.

**Correction.** Glimpse's main goal was the name and branding ("demand for a fork ... with better branding"), not UI. That makes it a weak precedent for whether UI forks are viable.

### OVERSTATED: The post-mortem says the shortage was people for moderation, triage, packaging, signing, testing and upstream work, not money; activity stopped about 10 weeks after Moss stepped back.

**Evidence.** The hiatus post says: "Our problem was not a lack of financial contributions or users". It lists moderation, bug triage, packaging, working with GIMP contributors, social media, servers, testing and documentation, and user questions. Moss left in February 2021, and "by the time I started to plot my return ten weeks later, almost all project activity had ceased" (http://web.archive.org/web/20210523153529/https://glimpse-editor.org/posts/a-project-on-hiatus/).

**Correction.** The post does not mention signing. It names the COVID pandemic and Moss's employer's conflict-of-interest review as direct causes, and the memo leaves both out.

### REFUTED: Glimpse stayed on 2.10.12 because rebasing would crowd out "more meaningful changes."

**Evidence.** Glimpse 0.2.0 (August 2020) was rebased from 2.10.12 onto 2.10.18 (https://www.omgubuntu.co.uk/2020/08/glimpse-0-2-0-released-based-on-gimp-2-10-18, https://github.com/probonopd/Glimpse). The memo itself describes the 0.2 diff as being against 2.10.18. I could not find the quoted phrase anywhere.

**Correction.** Glimpse rebased once and then fell behind (2.10.18 while upstream shipped 2.10.20 and 2.10.22). It did not stay on 2.10.12.

### OVERSTATED: Glimpse had four plans in two years: a custom toolkit in D, pre-release GTK4, Rust bindings.

**Evidence.** A D forum thread from July 2020 confirms the plan to rewrite in D with a bespoke cross-platform toolkit under a permissive license (https://forum.dlang.org/post/rdmcdf$2uej$2@digitalmars.com). I found no source for the GTK4 or Rust plans.

### OVERSTATED: The 2019 launch soured relations with upstream.

**Evidence.** The post-mortem says "We built a positive relationship with the GNU Image Manipulation Program contributors" and reports $750 donated to GIMP. The "four-month-long storm of undeserved criticism & trolling" came from critics, not specifically from GIMP developers (same archived hiatus post).

### CONFIRMED: Since 3.2.6 the macOS .dmg is built in upstream's main CI.

**Evidence.** The 3.2.6 release notes say the .dmg is now built alongside the Linux and Windows packages, which "has not been possible for many years" (https://www.gimp.org/news/2026/09/10/gimp-3-2-6-released/).

### OVERSTATED: GIMP requires a "no AI-generated content" checkbox on every merge request, mandatory since 2026-10-03.

**Evidence.** Commit d09bff26 (Bruno Lopes, 2026-10-03) turned the template into a checklist that includes "I declare this MR have no AI-generated content". It is labelled "for contributors without Developer role", and the commit says core developers don't need to tick it (https://gitlab.gnome.org/GNOME/gimp/-/raw/master/.gitlab/merge_request_templates/default.md).

**Correction.** The no-AI rule is older. It was already a guideline in the template before October 2026, and Jehan described a "strict No-AI policy" at LGM in April 2026 (https://librearts.org/2026/04/gimp-at-lgm2026/). The checkbox is a template item for newcomers. I saw no CI enforcement. The conclusion that nothing AI-written goes upstream still holds.

### CONFIRMED: "GIMP" is a registered US trademark (Reg. 8270101, GNOME Foundation, registered 2026-05-26).

**Evidence.** TSDR serial 99400712 shows the GIMP standard character mark, owned by GNOME Foundation, Reg. 8270101, registered May 26, 2026, Class 009, live (https://tsdr.uspto.gov/statusview/sn99400712).

### UNVERIFIABLE: Upstream says it defends the name actively; ask licensing@gnome.org.

**Evidence.** licensing@gnome.org is the contact given in GNOME's trademark guidelines (https://foundation.gnome.org/licensing-guidelines). I found no upstream statement about actively defending the name, only a 2015 objection to SourceForge's misleading mirror (https://lists.gnome.org/archives/gimp-developer-list/2015-June/msg00025.html).

### CONFIRMED: PhotoGIMP survived GTK2 to GTK3 with about 570k downloads.

**Evidence.** GitHub release asset totals come to about 598k: 1.0 79k, 1.1 72k, 3.0 370k (released 2025-03-17, the day after GIMP 3.0), 3.1 77k (https://github.com/Diolinux/PhotoGIMP).

**Correction.** PhotoGIMP already fills the shortcut and layout overlay niche that Option D targets. Its reach also depends on Diolinux's large existing audience, which a new pack would not have.

### CONFIRMED: The UX team closed gimp-ux #76, a wholesale UI overhaul proposal, as not feasible.

**Evidence.** Issue #76, "Draft: GIMP Overhaul Proposal: Adwaita Mode", was closed 2025-08-26 with the note "Moving straight to Adwaita is not feasible. However we can improve from where we are" (GNOME GitLab API, Teams/GIMP/Design/gimp-ux issue 76).

**Correction.** It was a GNOME-HIG/Adwaita proposal specifically, not a generic overhaul.

### CONFIRMED: Toolbox, toolbar, window management and docking items on the roadmap haven't been started; new XCF and CMYK are 3.4 work.

**Evidence.** The roadmap lists Improved toolbox, Toolbar, Better window management and Dockable interaction review as "Not started". High-end CMYK is WIP for 3.4, and the new XCF format is "Discussed" (https://developer.gimp.org/core/roadmap/). A zip+XML format being built by Jehan is reported only by a secondary source (https://pasqualepillitteri.it/en/news/11717/gimp-new-file-format-29-years-xcf).

### CONFIRMED: Patchy: MIT, Qt 6, three OSes, about 5 months old, about 99% one author, about 274k UI lines.

**Evidence.** The repo was created 2026-05-29 under MIT. SethRobinson has 3,488 of about 3,524 commits. A sparse clone today counts about 307k lines in src/ui and about 968k in src. It is signed and notarized on macOS, also runs in the browser, has 12 UI languages and opens XCF (https://github.com/SethRobinson/Patchy).

**Correction.** Patchy is a stronger competitor than the memo admits. It is free, already on the Mac and signed there, imports XCF and targets Photoshop users, which overlaps most of what Option B would give a Mac user.

### CONFIRMED: Seashore's maintainer concluded donations don't fund this kind of work.

**Evidence.** The maintainer writes "The donation model hasn't worked" and has moved to Seahorse, a commercial, closed-source Swift/SwiftUI app for Mac and iPad on the App Store (https://eolcoderllc.github.io/Seahorse/future_of_seashore). Seashore itself is GPL-2.0 and is on the Mac App Store (https://github.com/robaho/seashore).

### UNVERIFIABLE: GPLv3 probably rules out the Mac App Store (inferred).

**Evidence.** The inference is reasonable: any of GIMP's many copyright holders could object, as happened with VLC. GIMP publishes nothing on the Mac App Store and warns that listings there are third-party (https://www.gimp.org/downloads/). GPL apps do appear on the store when a single copyright holder publishes them (Seashore).

### OVERSTATED: Distribute as a notarized DMG or through Homebrew.

**Evidence.** Homebrew said it would drop casks that fail Gatekeeper as of 2026-09-01 (https://github.com/Homebrew/brew/issues/20755), so Homebrew is not a way around notarization. macOS Sequoia removed the Control-click bypass (https://www.macrumors.com/2024/08/06/macos-sequoia-gatekeeper-security-change/). The user's Lucerne CICD.md says releases are ad-hoc signed and "not notarized" on purpose.

**Correction.** Both paths require a paid Developer ID and a working notarization pipeline. That pipeline would have to sign GLib/GTK3, Python and the plug-in executables, and probably disable library validation so third-party plug-ins load. The user has none of this today.

### CONFIRMED: Rigi's Unlicense is compatible and the combined work ships under GPLv3.

**Evidence.** The FSF lists the Unlicense as GPL-compatible (https://www.gnu.org/licenses/license-list.html#Unlicense). Linking GIMP's GPLv3+ app/ code makes the combined work GPLv3.

### OVERSTATED: Lucerne's Qt port contains no Rigi-like code and was written two months before Rigi existed, so the 'same guidelines' idea doesn't hold up.

**Evidence.** The first commit under Lucerne/linux is 2026-08-23 and Rigi's initial commit is 2026-10-28. But Rigi's README says it was "extracted from Lucerne", and Lucerne's Linux README calls the Qt port the same "ClarisWorks-style" product.

**Correction.** The conclusion is right: no Rigi code carries over to Linux. The dating argument is misleading, though, because the design language existed in Lucerne before the Rigi repo did.

### REFUTED: Glimpse repo deleted between March and August 2023 vs "archived around May 2024."

**Evidence.** The hiatus post (May 2021) says "we have archived our GitHub repositories". The glimpse-editor GitHub org now has 0 public repos, and its updated_at of 2023-05-21 is consistent with deletion in 2023. The surviving copies are joshgiesbrecht/Glimpse, now the root of the fork network, and azubieta/Glimpse.

**Correction.** The repos were archived in May 2021 and deleted around May 2023. The "archived around May 2024" version is wrong.

### REFUTED: Glimpse usage: 86k total downloads vs about 18k on Flathub.

**Evidence.** The Flathub stats API reports installs_total 52,862 for org.glimpse_editor.Glimpse, with a few installs a day still happening in late 2025 (https://flathub.org/api/v2/stats/org.glimpse_editor.Glimpse). I could not check the 86k figure.

### CONFIRMED: Spike on GIMP 3.2.8 with a rebase drill onto master (3.3.1).

**Evidence.** GIMP_3_2_8 was tagged 2026-11-02 and is the current stable release (https://www.gimp.org/downloads/). Master's meson.build says version 3.3.1, and no 3.3.x release has been published.

### CONFIRMED: GTK4 preparation is touching the APIs the tools depend on.

**Evidence.** The 3.2.6 notes say GTK4 is not yet planned, but contributors are already replacing deprecated GTK calls to prepare for it (https://www.gimp.org/news/2026/09/10/gimp-3-2-6-released/).

### UNVERIFIABLE: The audience is estimated at 5k–30k users.

**Evidence.** No source or method is given, and the spike's go criteria include no demand test.

### OVERSTATED: Recommendation: ship D now and run a B spike in parallel.

**Evidence.** The memo's own risk list for A says GTK CSS "looks like Rigi without being Rigi", yet D is exactly CSS plus config files, in a niche PhotoGIMP already holds with about 600k downloads. B's Mac-only audience must choose it over free Affinity, free and notarized Patchy (which imports XCF), Pixelmator Pro at $49.99, and Seahorse. None of the seven go criteria tests whether anyone wants it, and the memo also says the Qt follow-up depends on proving demand.

## Missing considerations

- Rigi is one week old: initial commit 2026-10-28, API version 0.1.0, 3 commits. Option B needs 6–10k lines of Rigi extensions, roughly doubling a 4.7k-line toolkit, so calling Rigi the 'real asset' is premature.
- Solo maintenance load: the workspace holds about 69 projects. A GIMP-core-based editor with no stable upstream API and the CMYK/new-XCF churn coming in 3.4 is a multi-year commitment on top of all of them. Criterion 7 names this but nothing in the plan budgets for it.
- Signing and distribution: the user's apps currently ship ad-hoc signed and not notarized (Lucerne CICD.md). A professional image editor needs a Developer ID and notarization of GLib/GTK3/Python/plug-in binaries, plus a hardened-runtime exception for unsigned third-party plug-ins. Sequoia removed the Gatekeeper Control-click bypass, and Homebrew is dropping casks that fail Gatekeeper.
- Security updates: B links GIMP's file loaders, which have had recent high-severity bugs, e.g. CVE-2025-14424 (XCF use-after-free, https://cvefeed.io/vuln/detail/CVE-2025-14424) and CVE-2025-10925 (ILBM, https://cvefeed.io/vuln/detail/CVE-2025-10925). A fork pinned to stable tags must ship fixes within days. Glimpse's own shutdown post told users to switch back to GIMP for security reasons.
- No demand validation before committing: there is no target-user definition (who needs GIMP compatibility and a Mac-native 2010 look, and won't use free Affinity, Patchy or Pixelmator?) and no cheap test such as a landing page, waitlist or interviews.
- What 'user-friendly' means: GIMP refugees mostly complain about the interaction model (Photoshop-style shortcuts and tools, export vs save, layer boundaries, modifier keys), which is what PhotoGIMP and Patchy target, not about chrome. A 2010 skeuomorphic look is a taste bet against macOS 26 conventions.
- Competitors left out: Pixelmator Pro (Apple, $49.99 or Creator Studio), Acorn, Photopea, and Seahorse as the closest solo-developer Mac analog.
- Plug-in ecosystem: GIMP 3 broke many 2.10 plug-ins. Users expect G'MIC-Qt, Resynthesizer, BIMP and Script-Fu/Python consoles. Interactive plug-ins open GTK or Qt windows, which breaks the native feel B is selling and forces shipping GTK3 anyway.
- Localization: GIMP ships about 80 languages. A new Swift UI starts English-only and will mix with translated core strings (undo labels, GEGL operation names). Patchy already has 12 UI languages.
- Accessibility: custom-drawn gradient controls need full NSAccessibility support, small 20pt controls are hard targets, and Increase Contrast, Reduce Transparency and dark mode all need handling. The memo lists accessibility only as one line item.
- User trust in forks: GIMP warns about third-party App Store listings, and GIMPshop's domain and SourceForge's 2015 mirror both carried adware. An AI-built fork, in a community that has adopted a strict No-AI policy, risks the kind of public backlash Glimpse got. Upstream developers may also decline to help with internal-API questions.
- Documentation: GIMP's large base of tutorials won't match a new UI, so help content must be written and maintained.
- An option the memo never weighs: a Rigi front-end over Patchy's MIT core, or contributing a classic Mac theme to Patchy. This avoids GPL and App Store limits and reuses an actively maintained, AI-friendly cross-platform engine. Feasibility is unverified, since Patchy's core may depend on Qt Gui.
- Is this a product or a personal project? If it is mainly for the user's own use or taste, Mac-only reach and a small audience matter far less, and the recommendation should be framed that way.
- Internal inconsistencies: the engine is described as about 394k lines and also about 350k lines; '2.10.12' conflicts with the memo's own 2.10.18 diff.
