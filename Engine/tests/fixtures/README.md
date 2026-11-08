# Engine conformance fixtures

Made with GIMP 3.2.0 (the adapter's starting tag) by
`scripts/make-fixtures.sh GIMP_3_2_0`, which runs
[`../make-fixtures.py`](../make-fixtures.py) through libgimp in that
engine's own `gimp-console`.

| File | Content |
|---|---|
| `composite.xcf` | A text layer, a layer group holding a layer with a non-destructive Gaussian blur and a masked layer in multiply mode at 80 % opacity, and a background. |
| `composite.png` | GIMP's own composite of it: the visible layers merged in a duplicate, then exported. |
| `text-units.xcf` | A 144 dpi image with a text layer sized in points (24 pt type, 12 pt line spacing), for reading text settings back in pixels. Added later with the same GIMP 3.2.0; the two files above were kept as they were. |
| `qmask-name.xcf` | A channel named "Qmask" — the name the Quick Mask's channel reserves — beside ordinary "Saved" and "Other" channels, written while the mask was on. Made with GIMP 3.0.8 by `scripts/make-qmask-fixture.sh GIMP_3_0_8`, which runs [`../make-qmask-fixture.py`](../make-qmask-fixture.py): the engine turns the mask on when a channel takes the reserved name, and XCF stores no mask state, so every version adopts the channel as the live mask on open. |

The conformance tests open both through the adapter and require the
adapter's render of the XCF to equal GIMP's composite pixel for pixel, and
an XCF save and reopen to keep pixels and structure. The text layer's pixels
are stored in the XCF, so the comparison does not depend on installed fonts.
Regenerate only on purpose, and record the GIMP version here.
