# Committed-filter selection accessibility

The Layers palette's drawn filter badge now exposes an accessibility image.
Its existing Filter and Selected filter labels track the same live badge as
the effective filter selection changes. The image has no controls or key
handlers, so it exposes the mark without masking the row's eye, name or
opacity controls.

The old actual AppKit suite ran 13 tests with two failing assertions: the
badge was not an accessibility element and its role was AXUnknown. Label
tracking and the other row behavior already passed. With production
`6d7281e`, all 13 focused tests pass. Integration `7a7388d` with Main `64f778a`
passes all 1,222 unit tests, using private leased runs. These local raw results
were captured on 2026-11-11 in ephemeral directories; the paths are not a
portable evidence archive. The runs are
`/tmp/glims-completion/effect-badge-ax-old-units.I7RUmJ`,
`effect-badge-ax-fixed-units.3E7ZpZ` and
`effect-badge-64f-full-units.YSqBYJ` under the same directory.

SWE-2 completed an independent source review with no important finding;
its report is `effect-badge-6d7281e-devin-source-review.log` in that evidence
directory. This does not establish spoken VoiceOver behavior or a complete
keyboard/accessibility audit. Native engine code and the facade are unchanged.
