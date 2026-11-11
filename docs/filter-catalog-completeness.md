# Complete cold filter discovery

GEGL can discover operation classes while the catalog is being enumerated.
On a fresh pinned engine, the count query reports131 rows and the subsequent
fill reports183. The former Swift wrapper allocated131 rows and silently
returned that prefix. A later request saw the complete catalog, so fixtures
that warmed discovery before checking menus missed the first-launch defect.

The wrapper now checks counts before allocation and before accepting a fill.
A growing fill retries with its reported capacity; only a complete response
escapes. Shrinking and empty catalogs keep their actual contents. Three fill
attempts and a10,000-row policy bound allocation and retries. Invalid counts,
continued growth and native errors fail explicitly rather than publishing a
partial list. Native order and all row fields remain intact.

Complete catalog storage still includes engine-internal operations for effect
lookup. Human Filter sections omit only untitled `gimp:` infrastructure such
as buffer sources, profile transforms and blend modes. Titled GIMP operations
stay available. Untitled GEGL or external operations keep their names as menu
labels, including an unavailable-source explanation where appropriate. This
changes neither the native operation allowlist nor capability flags.

## Verification

Tests-only `1908a54` executes the first public request immediately after engine
startup, before any catalog warm-up. It reports131/183/183 and four checks with
one first-response completeness failure. Later-response stability and unique
names pass. Three additional pure menu tests at `bee0f95` reproduce three
blank/internal-label assertion failures while titled controls pass.

Production integration `bf37550` includes Main `5c55b8f` and passes:

| Scope | Result |
| --- | --- |
| Fresh native-backed first/second/third responses, GIMP3.2.8 |183/183/183;4/0 |
| Same, GIMP3.2.0 |182/182/182;4/0 |
| Same, GIMP3.0.8 |182/182/182;4/0 |
| Same, master |183/183/183;4/0 |
| Growth/field-order/count/error callbacks and menu policy |11 unit tests/0 |
| Full combined unit suite |1,216 tests/0 |

The cold cases start separate processes and use private settings directories;
no images or AppKit application are constructed. The menu tests verify layout
and label decisions, rather than claiming an observed normal-launch menu.
Independent source review finds no important issue in the bounded read, row
lifetime or menu policy. Hosted CI and the final standalone application remain
separate gates. No native production, facade layout or upstream source changes.
