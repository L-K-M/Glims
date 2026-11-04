<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 1: Image editor landscape and target users

# Landscape and target-user report: a "user-friendly, 2010-style professional" GIMP fork (as of 2026-11-04)

## Bottom line

1. **On the Mac, "free" no longer sets anyone apart.** Affinity has been free since Oct 2025 and passed 3M downloads in 33 days. Pixelmator Pro costs $49.99 once, or comes in a $12.99/mo bundle. Acorn costs $29.99. A friendlier GIMP on Mac competes on being free software, needing no account or subscription, and running the GIMP ecosystem. It does not compete on price.
2. **Rigi's platform and the likely users don't line up.** The largest group with no polished free editor is on Linux, where Affinity isn't available. Rigi only runs on macOS. GIMP 3.2's first 11 days saw roughly 1M Windows installer downloads against 150k macOS DMGs. A Mac-only fork serves a small slice of GIMP's audience.
3. **People want familiarity added on top of upstream GIMP, not a fork.** PhotoGIMP, a layout and shortcut patch for stock GIMP, has had about 570k release downloads and 18.5k stars. Glimpse's Flathub build reached about 18k downloads before the project stalled. Glimpse's planned UI rewrite, "Glimpse NX", never shipped.
4. **Rigi already covers the chrome half of a 2010 pro UI.** That means toolbars, inspector palettes, tear-off palettes, live-preview pickers, and a status bar with zoom. It has none of the image-editor widgets: layers list, histogram, curves and levels, brush picker, navigator, rulers, dark HUDs, panel docking. Those are most of the work.

---

## 1. Competitive landscape (Nov 2026)

### macOS

| App | Price / terms now | License | Platforms | UI style | Notes |
|---|---|---|---|---|---|
| **Affinity (by Canva)** | Free for individuals. A Canva account is required. Generative Fill, Expand & Edit and Remove Background need Canva premium. | Proprietary | Mac, Win. iPad was announced for Nov 3, 2026, and affinity.studio lists it as a new release. No Linux. | Modern, dark, Photoshop-like: context toolbar plus studio panels. Photo, vector and layout in one app. | Released 30 Oct 2025 ([MacRumors](https://www.macrumors.com/2025/10/31/canva-relaunches-affinity-free-app/), [Wikipedia](https://en.wikipedia.org/wiki/Affinity_(software))). 1M users in 6 days and 3M downloads in 33 days ([PetaPixel](https://petapixel.com/2025/11/06/affinity-added-1-million-users-in-less-than-a-week/), [PetaPixel](https://petapixel.com/2025/12/03/affinity-hits-3m-downloads-of-its-new-editing-software-in-just-33-days)). Canva's terms tie use to an active Canva account ([Canva terms](https://www.canva.com/policies/affinity-additional-terms/); the page blocked my fetch, so this is from a search snippet). Some forum users report forced license check-ins after long offline use; this is anecdotal ([L&L forum](https://forum.literatureandlatte.com/t/im-thinking-of-leaving-adobe-cloud-for-affinity/151874?page=4)). V2 perpetual licenses still work but get no updates. Linux runs only via community Wine/AppImage installers ([OMG! Ubuntu](https://omgubuntu.co.uk/2026/01/run-affinity-linux-ubuntu-appimage)). iPad date is from a PetaPixel headline ([PetaPixel](https://petapixel.com/reel/2026/10/27/affinitys-ipad-app-is-coming-november-3/)); I couldn't fetch the page, so release on that date is unverified. |
| **Pixelmator Pro (Apple)** | Apple Creator Studio: $12.99/mo or $129/yr (students $2.99/mo). The one-time Mac version is still $49.99 but frozen at 3.7.1 with no updates. Version 4.x and the Warp tool are subscription-only. | Proprietary | Mac (subscription version needs macOS 26). iPad via subscription only. | Modern single window with sidebars. | [apple.com/pixelmator-pro](https://apple.com/pixelmator-pro), [MacRumors](https://www.macrumors.com/2026/01/28/apple-creator-studio-now-available/), [heise](https://heise.de/-11160196) |
| **Pixelmator Classic** | Off the Mac App Store since 2020; developer says it needs macOS 13 or earlier for stability. Pixelmator for iOS gets no updates since Jan 2026. | — | — | The original dark HUD-style palettes. | [Pixelmator helpdesk](https://helpdesk.pixelmator.com/support/solutions/articles/60001126482-pixelmator-classic-s-end-of-life-cycle), [9to5Mac](https://9to5mac.com/2026/01/13/apple-confirms-pixelmator-for-ios-will-no-longer-receive-updates/) |
| **Photomator** | $29.99/yr, or a lifetime license (prices vary: $119.99 to $199.99 reported, unverified). Not in Creator Studio; its future is unclear. | Proprietary | Mac, iOS, iPad, visionOS | Photo-centric, Lightroom-lite. | [Galaxus review](https://www.galaxus.de/en/page/apple-photomator-lightroom-light-mit-ungewisser-zukunft-41213), [Pixelmator FAQ](https://support.pixelmator.com/faq-photomator/general/app-store-and-purchases) |
| **Acorn 8** (Flying Meat) | $29.99 one-time; 14-day trial; often discounted to $19.99. | Proprietary | Mac (macOS 14+); latest 8.7.1 | Single window since Acorn 7 (2021); floating palettes still available as an option. | [Macworld 2026 review](https://www.macworld.com/article/3015747/acorn-photo-editor-review.html), [Wikipedia](https://en.wikipedia.org/wiki/Acorn_(software)) |
| **Photopea** | Free with ads. Premium about $5/mo or roughly $40–50/yr prepaid (third-party figures). | Proprietary | Web | Close Photoshop clone. | Developer says it was "used 350 million times" in 2025 (via search snippet, unverified) ([search ref](https://en.wikipedia.org/wiki/Photopea)) |
| **Krita** | Free from krita.org; paid store copies (Mac App Store was $14.99 in 2023). | GPLv3 | Win, Mac, Linux, Android | Qt with dockable panels; built for painting. | Krita 6.0 (Qt6) and 5.3 (Qt5) both shipped 24 Mar 2026 ([Phoronix](https://www.phoronix.com/news/Krita-6.0-Released), [krita.org](https://krita.org/en/posts/2023/krita-in-stores-update/)) |
| **GIMP 3.2.x** | Free; latest 3.2.8. | GPLv3 (libgimp LGPLv3) | Win, Mac, Linux | GTK3 with dockable panels. | 3.2 released Mar 2026 with link layers, vector layers and "a TON of small UI/UX improvements" ([Phoronix](https://www.phoronix.com/news/GIMP-3.2-Released), [gimp.org RC3](https://www.gimp.org/news/2026/03/02/gimp-3-2-RC3-released/)) |
| **Preview** | Bundled with macOS | — | Mac | Basic adjustments and markup, no layers (from general knowledge). | — |

### Linux and Windows

| App | Price | License | Platforms | UI style / status |
|---|---|---|---|---|
| **Krita** | Free | GPLv3 | all | See above. Strongest free open-source alternative, but for painting. |
| **Pinta 3.0** (Apr 2025) | Free | MIT (from memory) | Win, Mac (arm64 build), Linux | Paint.NET clone, ported to GTK4/libadwaita, so it looks like a GNOME app ([release notes](https://www.pinta-project.com/releases/3-0)). |
| **Photoflare 1.7.x** (May 2026) | Free | GPL (from memory) | Linux, Win | Qt6 port with G'MIC built in, after 6 years without a release; small project (473 stars) ([Linuxiac](https://linuxiac.com/photoflare-1-7-image-editor-released-after-years-of-silence/)). |
| **darktable 5.4** (Dec 2025) | Free | GPLv3 | all | Raw developer built from many modules; not a layer editor ([Linuxiac](https://linuxiac.com/darktable-5-4-1-raw-released-with-extensive-bug-fixes/)). |
| **RawTherapee 5.12** (2025) | Free | GPLv3 | all | Raw developer. |
| **Paint.NET 5.1.x** (5.1.12, Mar 2026) | Free download; paid Store copy that funds development (price unverified) | Freeware, closed source | Windows only | Simple, approachable classic Windows app ([Betanews](https://betanews.com/2024/11/14/paint-net-5-1-unveils-color-management-support-new-and-improved-effects/)). |
| **Affinity** | Free | Proprietary | Win only (no Linux) | See above. |

Platform context: in the July 2026 Steam survey, Linux was 4.01% and macOS 2.32% ([GamingOnLinux](https://gamingonlinux.com/2026/08/linux-back-over-4-percent-in-the-july-2026-steam-survey)). That survey is gaming-biased.

---

## 2. Who would actually switch?

### Size signals

| Signal | Value | Source |
|---|---|---|
| GIMP 3.2, first ~11 days | Windows installer >1M downloads; MS Store ~50k installs; **macOS DMG >150k**; Flathub ~300k active users (estimate); Snap 359k active devices | [GIMP Mastodon post, 25 Mar 2026](https://notestock.osa-p.net/@GIMP@floss.social/20260325/view) |
| Flathub GIMP | 56,312 downloads/month | [Flathub](https://flathub.org/en/apps/org.gimp.GIMP) |
| Homebrew GIMP cask | 3.6k installs in 30 days; 43.3k in 365 days | [formulae.brew.sh](https://formulae.brew.sh/cask/gimp) |
| **PhotoGIMP** (Photoshop-like layout and shortcuts patch) | 18.5k stars. Release zips: v3.0 (Mar 2025) ≈347k, v3.1 (Jul 2026) ≈71k, v1.x ≈151k, total ≈570k. That is roughly 18–22k per month. | GitHub API, checked today: [Diolinux/PhotoGIMP](https://github.com/Diolinux/PhotoGIMP) |
| GIMP's own GitHub mirror | 6.6k stars (PhotoGIMP has about 3x more) | [GNOME/gimp](https://github.com/GNOME/gimp) |
| Glimpse | Flathub build ≈18k downloads by Jul 2020. Paused May 2021 because "we could not find contributors willing to step up and help with non-code tasks". Archived ~May 2024. | [OMG! Ubuntu](https://www.omgubuntu.co.uk/2020/07/glimpse-0-2-0-beta), [OMG! Ubuntu](https://www.omgubuntu.co.uk/2021/05/glimpse-gimp-fork-project-on-pause/amp), [It's FOSS](https://itsfoss.com/news/glimpse-gimp-fork-archived/) |

The two repos the user linked are minor mirrors, not the main project. joshgiesbrecht/Glimpse has 5 stars and was last pushed Jul 2019. azubieta/Glimpse is a fork of it based on GIMP 2.10.18, with 3 stars. Glimpse's README says its first goal was a **less problematic name**; UI work was planned for later. The UI rewrite (Glimpse NX) was put on hold indefinitely and never shipped. Glimpse showed that rebasing a hard fork is the easy part to start and the hard part to keep going.

### Sentiment

GIMP's UI complaints persist. Creative Bloq's GIMP 3.0 review says: "despite continuing promises of an improved interface, GIMP 3.0 is still much of the same" ([Creative Bloq](https://www.creativebloq.com/photography/photo-editing-software/gimp-3-0-review-20-years-on-from-2-0-has-gimp-kept-up-with-the-times)). Reddit and r/linux threads repeat the same points: it differs from Photoshop, features are buried, it feels "programmer-centric". Many of these posts predate 3.2, and I only sampled them through mirrors, so treat this as unverified for 2026. The GIMP team says it wants designer feedback ([gimp.org](https://www.gimp.org/news/2026/03/02/gimp-3-2-RC3-released/)). On Affinity going free, people split: some switched, and others distrust Canva and "may as well go the GIMP route" ([GIMP forum](https://www.gimp-forum.net/Thread-New-to-Gimp--11326?pid=46026)).

### Segments

| Segment | Would they switch to a friendlier GIMP? | Fit with Rigi (macOS) |
|---|---|---|
| Linux users who need a layer editor | **Highest need.** No Affinity, Photopea is web-only, Krita is painting-first, Pinta is basic. | **None.** Needs a Qt or GTK UI, as Lucerne's Qt port does. |
| Windows budget users | Low. Affinity is free, plus Paint.NET and Photopea. | None. |
| Mac budget users | Low. Affinity is free, Acorn costs $29.99, Pixelmator Pro $49.99. | Good, but heavily contested. |
| Mac users with principles (free software, no account, no subscription, no AI upsell, privacy) | Moderate. They are put off by Canva's account requirement and Apple's frozen one-time Pixelmator version. | **Best fit.** |
| GIMP ecosystem dependents (Script-Fu/Python plug-ins, G'MIC, Resynthesizer, XCF, scientific and education users) | Moderate, only if compatibility is preserved, which argues for staying close to upstream. | Good on Mac. |
| Former Photoshop CS-era users and fans of classic Mac UI | Some, for taste and familiarity. PhotoGIMP's numbers show familiarity demand. | Good. |
| Institutions bothered by the GIMP name (Glimpse's original reason) | Small, and mostly on Windows. | Weak. |

**Realistic niche** (my estimate, unverified): Mac users of GIMP plus Mac users who want free software and no account. Going by 150k DMG downloads in 11 days and 43k Homebrew installs a year, GIMP's active Mac base is probably in the low-to-mid hundreds of thousands. Taking 2–10% of that gives about 5k–30k users. That is enough for an indie open-source project, not enough to sustain a team that rebases a GTK3 fork. The demand PhotoGIMP proves is around 20k downloads a month, and it is concentrated among Windows and Linux users.

---

## 3. "2010-style professional UI" exemplars and Rigi coverage

### What made these apps approachable

- **Photoshop CS4/CS5.** The context-sensitive **Options bar** under the menu. I believe it dates from Photoshop 6, but that is from memory and unverified. CS3 added collapsible icon panel docks ([Peachpit](https://peachpit.com/articles/article.aspx?p=1228212)). CS4 added the Application Frame with tabbed documents and a non-modal **Adjustments panel** with presets, "no dialog box maze" ([CreativePro](https://creativepro.com/review-adobe-photoshop-cs4/2/), [PhotographyBlog](https://www.photographyblog.com/reviews_adobe_photoshop_cs4.php)). It also added a **Masks panel** that reviewers called good for beginners.
- **Aperture 3 (2010).** Floating **HUDs** let you "edit it right where you are" ([Kennett, "A Lament for Aperture", Jan 2026](https://ikennd.ac/blog/2026/01/old-man-yells-at-modern-software-design/)). It had an Inspector HUD plus per-tool HUDs ([Apple help](https://help.apple.com/aperture/mac/3.6/en.lproj/apr528ec387.html)), the loupe, and non-destructive brushes. Apple promoted it as "more iPhoto-like, larger type, streamlined sliders" ([Macworld](https://www.macworld.com/article/202518/aperture3.html)). Its design was quiet so the photos stayed the focus.
- **Pixelmator 1.x.** A transparent HUD UI at $59 ([Pixelmator 2007](https://www.pixelmator.com/blog/2007/09/25/pixelmator-team-releases-pixelmator/)). The look was **polarizing**: "overloaded with black", palettes that don't dock ([Wired](https://wirednews.pages.dev/2007/10/hands-on-review-pixelmator-a-photoshop-lite-for-mac-shutterbugs), [mjtsai](https://mjtsai.com/blog/2007/09/27/pixelmator-10)). Version 1.2 toned it down.
- **Acorn 1–3.** Pitched as image editing "without the palettes, steep learning curve, and off-putting price" ([Macworld](https://www.macworld.com/article/187280/acorn.html)). It put tools, options and layers in one wide palette. Acorn 4 (2013) split this into a tools palette and an inspector palette because there was "too much good stuff for a single palette" ([Flying Meat newsletter](https://secure.flyingmeat.com/newsletter/archive/2013.5.html)).
- **iWork '09.** An icon-and-label toolbar, a one-row **Format Bar** below it, a small floating tabbed **Inspector**, and full-screen mode ([O'Reilly Missing Manual](https://www.oreilly.com/library/view/iwork-09-the/9780596802073/ch01s07.html), [Macworld](https://www.macworld.com/article/194406/pages09_firstlook.html)).
- **Fireworks.** A single context-sensitive **Property Inspector**, docked at the bottom and showing the current selection, tool or document. Smashing Magazine called it "the core of Fireworks and one of its best features" ([Smashing Magazine](https://www.smashingmagazine.com/2010/05/adobe-fireworks-is-it-worth-switching-to-cs5/)).

The common threads: one context-sensitive place for properties; labeled controls instead of bare icons; non-modal adjustments with live preview; presets before raw parameters; editing in place; platform-native conventions (Cmd-I inspector, standard menus); few panels by default; quiet chrome.

### Rigi coverage

Checked against the Rigi README and `docs/interface-guidelines.md`.

| Trait | Exemplar | Rigi status |
|---|---|---|
| Gradient toolbar with icon-and-label buttons | iWork '09, Aperture | **Has** (`ClassicToolbarButton`, `ClassicBarView`) |
| Context format or options bar | Photoshop, iWork | **Has the building blocks**: a 34pt format bar metric, 20pt compact controls, pop-ups, size fields, segmented controls. The per-tool option sets are app work. |
| Floating inspector that follows the selection | iWork '09, Fireworks | **Has** (inspector palette body; `PaletteCenter` retargets to the front document) |
| Tear-off palettes | ClarisWorks, Photoshop tool flyouts | **Has** (tear-off contract) |
| Presets with live preview and a single undo | CS4 Adjustments presets, Aperture presets | **Has for list choices** (`TryOnPopover`, `PickerListView`). Live preview while dragging sliders or curves is **missing** and needs GEGL preview integration. |
| Status bar with zoom | Photoshop, Pages | **Has** (`StatusBarView`) |
| Labeled compact rows, engraved labels, mixed-state handling | iWork inspectors | **Has** (guidelines) |
| Tool palette / tool selector | all | **Partial** (`ClassicToolControl`, segmented). No vertical tool palette with flyouts was found in the README or guidelines. |
| Dark HUD panels | Aperture, Pixelmator 1.x | **Missing.** Rigi's chrome is light classic. |
| Panel docking and collapse to icons | Photoshop CS3–5 | **Missing.** Palettes are floating only; the guidelines say long palette bodies should scroll rather than collapse. |
| Tabbed documents / app frame | CS4 | Not in Rigi; native AppKit window tabs exist. |
| Image-editor widgets: layers list (thumbnails, blend mode, opacity), histogram, levels/curves, brush and gradient editors, navigator, rulers/guides | all | **Missing.** This is the bulk of the work. |

---

## 4. Demand for retro or classic Mac UI

**Signals for:**
- **Liquid Glass backlash.** Users criticized it at launch ([MacRumors](https://www.macrumors.com/2025/09/17/ios-26-liquid-glass-critiques/)). macOS 27 "Golden Gate" adds a transparency slider and goes back to a "more Big Sur-ish" design in places ([MacRumors forum summary](https://forums.macrumors.com/threads/all-the-liquid-glass-changes-in-macos-golden-gate.2483664/), [Six Colors](https://sixcolors.com/post/2026/06/wwdc-2026-no-tahoe-yes-golden-gate/)). This is demand for legibility, which a dense, opaque, labeled UI addresses.
- **"A Lament for Aperture"** (Jan 2026) reached 243 points and 55 comments on HN, praising HUDs and quiet design ([HN](https://news.ycombinator.com/item?id=46699697)).
- **Retroactive** (runs Aperture, iPhoto and iTunes on macOS Golden Gate): 2.3k stars, updated Jun 2026 ([GitHub](https://github.com/cormiertyshawn895/Retroactive)).
- **RetroMac** (2026 indie app that themes macOS as System 6 through 10.8; free, $10 Pro). A third-party site says it placed #4 on Product Hunt with 201 upvotes (unverified). TidBITS called it an "art project", though commenters said they "would pay to get rid of Liquid Glass" ([TidBITS, Oct 2026](https://tidbits.com/2026/10/07/appbits-retromac-and-reframe-let-you-theme-your-mac-like-its-1999/)).
- **Poolsuite FM** (Mac OS 9-style app): 30k Mac installs in 3 weeks in 2020 and featured by Apple ([Wikipedia](https://en.wikipedia.org/wiki/Poolsuite)).
- **Retro-look projects on GitHub:** SerenityOS 33.9k stars, WhiteSur GTK theme (macOS look) 9.4k, Chicago95 6.0k, Infinite Mac 1.65k (GitHub API, today).
- **Frutiger Aero revival** among Gen Z ([Creative Bloq](https://www.creativebloq.com/news/frutiger-aero-aesthetic-resurgance)). The "416M TikTok views" figure is unverified.

**Assessment:** the interest is real, but it shows up mostly as free themes, emulators and novelty apps. I found almost no evidence of people paying for, or switching their main tool to, a retro-styled pro app. Pitch it as clear, dense, labeled, with no account, subscription or AI upsell. The 2010 look is the vehicle, not the reason to switch.

---

## Unverified or estimated items

- Affinity iPad release actually happening on Nov 3, 2026.
- Exact wording of Canva's Affinity terms on revocation and offline use.
- Affinity 3.3.3 release date.
- Photomator lifetime price.
- Paint.NET Store price.
- Pinta and Photoflare licenses.
- Photoshop 6 as the origin of the Options bar.
- Photopea usage figures.
- RetroMac Product Hunt rank.
- TikTok view counts.
- Reddit sentiment from 2026 (most threads sampled were 2024–25).
- The niche size of 5k–30k users, which is my own estimate.
