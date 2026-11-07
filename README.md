# Glims

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

A native Mac image editor with a classic, uncluttered interface, built on the
GIMP image engine.

<img src="Resources/AppIcon.png" alt="Glims app icon" width="160">

**Version:** v<!-- version -->0.1.0<!-- /version -->

**Status:** phase 0 is finished with a go verdict
([`docs/phase0-report.md`](docs/phase0-report.md)) and the native editor is under active development. GIMP's engine builds
unmodified and runs behind the C adapter in `Engine/`; the app opens, paints,
filters, runs GIMP's plug-ins with their own dialogs and exports images
through it, and normal app builds include the engine. Nothing has been released.

Glims pairs GIMP's GUI-free engine (layers, masks, painting, selections,
non-destructive filters, XCF, plug-ins) with a new AppKit interface made with
[RigiUI](https://github.com/L-K-M/Rigi). The interface follows the design
sensibilities of mid-1990s professional editors: one compact tool palette,
draggable tabbed palettes, document windows with a status strip, every tool one
click or one key away, and readable labels. It is not a clone of any existing
application.

## How Glims relates to GIMP

Glims is not affiliated with or endorsed by the GIMP project. It links GIMP's
engine libraries, built from unmodified upstream source, and replaces the
entire GTK interface with its own. Engine updates arrive by rebuilding against a
new GIMP release. [`docs/plan.md`](docs/plan.md) describes how that is kept cheap
and what it costs.

Do not report Glims bugs to GIMP. GIMP does not accept AI-generated
contributions, so this project never proposes changes upstream.

## Name

Glims is named after Piz Glims, a 2,868 m peak in the Silvretta range of
Graubünden, and Lai Glims, the small lake below it on the way up from the Linard
hut. Like Rigi and Lucerne, it keeps to Swiss places.

## Build

Requires macOS 13 or later to run, and Xcode 26 or later to build (CI pins
Xcode 26.0). The shared build and release engines come from
[release-tool](https://github.com/L-K-M/release-tool): clone it and run
`./install.sh`.

```sh
scripts/build.sh              # Editor with engine in dist/Glims.app, revealed in Finder
scripts/build.sh --run        # …and launch it
swift test                    # unit tests
dist/Glims.app/Contents/MacOS/Glims --smoke-test
```

The editor requires its engine, built once on the development Mac:

```sh
scripts/bootstrap-deps.sh     # First setup takes hours; builds dependencies from source
scripts/build-engine.sh       # Builds the pinned engine from unmodified sources
scripts/build-adapter.sh      # Builds Glims's C facade
scripts/build.sh --run        # Bundles the engine and launches the working editor
```

A normal build fails with setup instructions if the engine is missing; it
never silently produces an editor with disabled commands. To build only the
interface on a machine without the engine, explicitly use
`scripts/build-app.sh --shell-only`. That development bundle needs
`GLIMS_ENGINE_LIBRARY` to edit images and must not be distributed.
`scripts/build-app.sh --engine GIMP_REF` selects another built engine set.

`scripts/build.sh` also takes `--clean`, `--debug`, `--install`, `--zip`,
`--dmg` and `--check`. [`CICD.md`](CICD.md) describes CI and releases.

## Documents

- [`docs/plan.md`](docs/plan.md): architecture, engine update model, the phase-0
  spike and its go/no-go criteria.
- [`docs/design.md`](docs/design.md): interface principles, palette model, how
  GIMP's concepts appear in the classic interface, menus and keys.
- [`docs/research/`](docs/research/README.md): the research records behind both
  documents, dated 2026-11-04.

## License

Glims's own code is released under the [GPL-3.0-or-later](LICENSE), because
it is built to link GIMP's GPLv3+ engine code. The app bundles RigiUI, which keeps its own
license (the Unlicense). The license text and the third-party notices ship in
the app's `Contents/Resources` as `LICENSE.txt` and `Third-Party-Notices.txt`.
