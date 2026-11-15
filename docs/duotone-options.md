# Duotone settings codec (private candidate)

Adobe documents a 524-byte version-1 Duotone Options settings file (`.ADO`):
up to four ink colors and Pascal names, thirteen transfer-curve values per
ink, compatibility fields and overprint colors. The private codec accepts that
exact version and size, checks active names and curve ranges, and retains all
bytes. Field edits retain compatibility, inactive-ink and overprint bytes.
Names remain raw bytes; a future interface must choose and validate an encoding.

The codec does not compute overprint colors, validate color-space semantics,
render a preview or publish changes to an image or file. Those decisions are
needed before exposing editing. Adobe describes the PSD color-mode block as
undocumented. A Photoshop CC 2018 fixture in this repository has a 524-byte
block whose plate count, ink names and curves match the documented `.ADO`
layout, but one fixture does not establish a general PSD contract. Existing
opaque metadata preservation remains unchanged.

The portable test checks every truncated length, invalid active fields,
field-local updates, preserved bytes and the Photoshop fixture in optimized
and AddressSanitizer/UndefinedBehaviorSanitizer builds (551 checks each).

Reference: [Adobe Photoshop File Formats Specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/), Duotone Options and Color Mode Data sections.
