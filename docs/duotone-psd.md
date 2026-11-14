# Retaining Duotone settings in PSD export (candidate)

Duotone export is an explicit flat output for an ordinary, opaque, 8-bit
grayscale document with retained Duotone settings from a PSD. It writes the
original opaque color-mode bytes and the visible grayscale pixels, without
modifying the source. Output does not include layers, color profiles,
resolution or other metadata; XCF remains the editable copy. Transparency,
linked layers, missing settings, unsupported precision and invalid samples
are refused, and the destination is published atomically. Repeat Export and
Batch carry the same explicit choice. Old adapters cannot select this output.

Glims does not interpret the settings, show an ink-color preview, edit inks
or curves, or create Duotone settings. Adobe describes the color-mode data as
opaque, and describes Photoshop's Duotone mode as single-channel 8-bit.
Preserving bytes alone does not establish Photoshop round-trip or printing
fidelity. The format and precision constraints are documented in the
[PSD specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/)
and [Adobe's Duotone guide](https://helpx.adobe.com/photoshop/using/duotones.html).

The Photoshop CC 2018 fixture is correctly imported as opaque on the pinned
engines. Development GIMP 3.3 instead imports its Gradient Fill as an empty
adjustment group and produces transparent pixels. Export refuses those pixels;
it does not silently replace the missing image. A separate flat PSD carrying
the exact same Photoshop settings exercises export on that engine. Fixing the
development engine's layered PSD import remains open. No test claims that
this independently constructed flat fixture was authored by Photoshop.
