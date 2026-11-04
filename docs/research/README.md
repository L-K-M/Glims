# Research records

AI research agents wrote these on 2026-11-04, in two rounds. Each round had
parallel researchers, a synthesis memo and independent skeptical reviews. The
files are kept verbatim for provenance; [`../plan.md`](../plan.md) and
[`../design.md`](../design.md) are the maintained conclusions. Where a review
corrects a report or memo, the review wins.

GIMP evidence came from read-only clones of GIMP master (2aef5e7, 2026-11-03)
and its tag history. Nothing from GIMP was built or run.

## Round 1: is a user-friendly GIMP-based editor worth doing?

| File | Content |
|---|---|
| [`r1-glimpse-history.md`](r1-glimpse-history.md) | Glimpse, GIMPshop, PhotoGIMP, CinePaint and why they stalled |
| [`r1-gimp-architecture.md`](r1-gimp-architecture.md) | Source study: which parts of GIMP depend on GTK |
| [`r1-gimp-status.md`](r1-gimp-status.md) | GIMP 3.x releases, UX governance, macOS build, trademark |
| [`r1-landscape.md`](r1-landscape.md) | Competing editors and target users |
| [`r1-rigi-fit.md`](r1-rigi-fit.md) | What Rigi provides and lacks for an image editor |
| [`r1-memo.md`](r1-memo.md) | Synthesis memo |
| [`r1-review-technical.md`](r1-review-technical.md), [`r1-review-product.md`](r1-review-product.md) | Reviews of the memo |

Main corrections from the round 1 reviews: GIMP's tools cannot be reused
without GTK, so a native front-end rewrites all tools and the canvas; filter
commit and undo logic is GUI-side code; file import and export run through GTK
plug-in processes; Glimpse rebased to GIMP 2.10.18 and its post-mortem
describes good relations with GIMP contributors.

## Round 2: a fully new interface with cheap engine updates

| File | Content |
|---|---|
| [`r2-api-churn.md`](r2-api-churn.md) | Measured engine API churn per release interval, 3.0.0 to master |
| [`r2-engine-hosting.md`](r2-engine-hosting.md) | Hosting the engine with no patches; out-of-process alternative |
| [`r2-classic-design.md`](r2-classic-design.md) | Design principles, palette model, GIMP concept mapping |
| [`r2-memo.md`](r2-memo.md) | Architecture memo |
| [`r2-review-churn-recount.md`](r2-review-churn-recount.md), [`r2-review-hosting-check.md`](r2-review-hosting-check.md) | Independent recount and hosting check |

Main corrections from the round 2 reviews: the churn numbers reproduce, but
micro releases also bring dependency bumps, XCF version changes and small
features; startup signal/property checks miss macro, enum and behavior
changes; unmodified GIMP does not configure against Homebrew's gexiv2, so
use MacPorts; GIMP's paint thread and display scheduling must be rebuilt;
`app/tests/tests.c` is not a valid startup model for an interactive host.

## Scripts

[`scripts/`](scripts/README.md) holds the measurement scripts used in round 2.
