# Public gradient-create facade (slot 138)

API version stays `GLIMS_ENGINE_API_VERSION` = 1. One append-only member,
`resource_create_gradient`, is added as the final field of
`GlimsEngineAPI` (`Sources/CGlimsEngine/include/glims_engine.h`), after
`image_selected_items` (slot 137). No existing field, signature, order or
prefix changed; `struct_size` grows by one pointer, which is exactly how
consumers detect the slot: check `api_version` and that `struct_size`
reaches `offsetof(GlimsEngineAPI, resource_create_gradient) +
sizeof(member)` before dereferencing it — an older 137-slot producer
refuses cleanly instead of reading past its table.

## Public scope

```c
GlimsStatus (*resource_create_gradient)(GlimsEngine *engine, const char *name,
                                        const GlimsColor *left, const GlimsColor *right,
                                        GlimsResourceID *out, char **error);
```

Creates ONE saved gradient: a static two-endpoint gradient with exactly
one segment (positions 0 / 0.5 / 1, linear, RGB, both endpoint color
types fixed — never context-dynamic FG/BG), persisted as `.ggr` in the
engine's configured writable data folder and published to the gradient
factory. The full native name/color/busy/persistence validation lives in
the accepted internal creator `glims_resource_create_gradient`
(`Engine/resource-gradient-create.c`); the facade adds no second
implementation and touches no pipeline.

## Call contract

- Every call is marshalled onto the engine thread and blocks until done
  (`Engine/engine.c`: `GlimsResourceCreateGradientArgs` +
  `resource_create_gradient_on_engine` + `api_resource_create_gradient`,
  wired as `.resource_create_gradient` after slot 137). The bridge writes
  `*out = 0` BEFORE dispatch (NULL-safe), so a NULL-engine dispatch
  returns `NOT_RUNNING` and still clears a prefilled `out`. Required
  pointer arguments (`name`, `left`, `right`, `out`) are passed through
  untouched and validated inside the creator without pre-dereference:
  NULL `name`/`left`/`right`/`out` are `INVALID_ARGUMENT`. Arbitrary
  non-NULL opaque engine pointers are never fabricated or dereferenced.
- `name`: the shared resource label contract (nonempty UTF-8, no
  embedded NUL, no Unicode Cc controls, at most 255 UTF-8 bytes) plus the
  `.ggr` edge rule — ASCII whitespace at either name edge is refused,
  never silently trimmed (the loader strips it, which would change the
  name's identity on reload).
- `left`/`right`: every component, alpha included, finite and inside
  0...1. No clamping or normalization anywhere.
- `BUSY` while the engine is busy or ANY stroke/filter session is
  active; `FAILED` on an exact same-kind name collision (never silently
  uniquified) or a checked persistence failure. `out` is 0 on every
  failure and the positive catalog handle on success, usable with
  `resources`, `resource_identifiers`, `resource_resolve`,
  `resource_thumbnail` and the gradient consumers. No image, undo
  history, selection, context or clipboard is touched.
- Swift: `EngineSession.createGradient(name:left:right:)` takes plain
  owned `EngineSession.RGBAColor` values (an `Equatable, Sendable` value
  type, not NSColor/AppKit), validates via
  `EngineSession.validateGradientCreation` (validateResourceName + the
  byte-level GGR edge rule + finite 0...1 components), copies them into
  `GlimsColor` locals that live for the synchronous call, frees the
  native error through the existing `check`, and requires a positive
  handle on success. Call it off the main thread like other catalog
  work. No UI, form or ImageDocument changes.

## Checked vs not run here

Checked by compile/verification in this change: C syntax of `engine.c`
against all four frozen engine flag sets, strict
`clang -std=c11 -Wall -Wextra -Werror` compile of the facade-only harness
(`Engine/tests/gradient-create-facade-tests.c`, dlopen producer, public
header only) via `scripts/test-gradient-create-facade.py --compile-only`,
Python AST/`--help` of the runner, and `swift build` /
`swift build --build-tests` for the Swift half. Pure validation coverage
is in `Tests/GlimsKitTests/GradientCreationInputTests.swift` (compile
only here; no XCTest run).

NOT run here (runtime is root-owned): the harness phases (create/verify
with a real engine, cross-process reload, thumbnails, BUSY, refusal
matrix) and the Core 97-check native segment/pixel oracle in
`Engine/tests/gradient-create-tests.c`, which is a separate accepted
harness and is not claimed as this change's runtime validation. The
runtime behavior of the slot therefore remains unverified in this
worktree until root runs the producer.
