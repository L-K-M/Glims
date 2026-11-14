# Duotone PSD metadata preservation (candidate)

Adobe's PSD specification describes the Duotone color-mode block as opaque
and suggests preserving it when a reader treats the image as grayscale. GIMP's
PSD loader currently imports that block into a nonpersistent image parasite,
so saving XCF loses it. This candidate promotes the loader's grayscale tag to
a persistent tag before the image is adopted. The data is copied byte for
byte without adding an Undo step. An existing persistent tag is left alone;
a new empty or larger-than-16-MiB tag is refused with an error rather than
silently dropped.

A synthetic PSD envelope and a 4×4 Photoshop CC 2018 fixture verify import,
XCF save, reopen and resave, exact opaque bytes and source-file preservation.
The synthetic block is a marker, not a Photoshop ink specification. The
fixture is attributed in the test-fixture README. These preservation checks
pass on all four supported engines. This change does not interpret ink
settings, provide a Duotone color preview, create or edit ink curves, or add
Duotone PSD export. Oversized new metadata refuses. Four-engine
editor qualification, export workflow and review remain open.

Reference: [Adobe Photoshop File Formats Specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/), Color Mode Data Section.
