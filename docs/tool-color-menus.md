# Tool and color menu parity

View > Tools mirrors the existing 26 tools in sixteen palette slots, plus
Swap Colors and Default Colors. Group choices have one submenu level.
These context commands share the palette's ToolState paths, remain available
without an image or during engine work, and do not edit native images.
Stable owned command IDs support the existing shortcut customizer. Factory
items leave canvas tool letters available to text fields.

## Verification

The old menu fails three literal menu tests. Six new catalog/menu methods
pass on current production `9b2a67c`. The corrected focused fixture `27ff3c9`
passes 106 checks on each of the four supported engines: all 26 real menu
routes/checkmarks/palette choices, colors, invalid packets, busy context and
actual field-editor typing with unchanged native pixels, selection and Undo.
The full isolated, leased suite passes 1,021 tests. Independent production
source review found no important finding.

The initial whole-root performKeyEquivalent probe returned true for plain D,
although actual field typing and context/native invariance already passed.
Diagnostic output showed two AppKit-injected Start Dictation Function-D items
beside the existing Command-D Deselect item. Exact OS dispatch was not traced.
The direct probe now checks the new Tools submenu; unchanged actual
NSApp.sendEvent typing continues to test the whole application's routing.
No production change was made for that overbroad oracle.

Every run exits and releases the desktop. The unit run and first failed UI
run had incomplete final AX reads; all four corrected UI snapshots were clear.
Temporary signed hosts and external API165 adapters do not establish physical
keyboard or self-contained release coverage. Current CI/review and combined
integration remain required.
