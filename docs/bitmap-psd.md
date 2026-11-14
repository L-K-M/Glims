# Photoshop Bitmap PSD work

GIMP's PSD loader reads Photoshop Bitmap images as indexed images; its PSD
exporter emits indexed PSD instead of Bitmap mode. This candidate adds an
explicit Bitmap (1-bit) option to the PSD export sheet and Batch. It writes
the visible canvas of a grayscale or indexed document as a flat one-bit PSD.
The default method accepts only exactly black or white, fully opaque pixels.
An explicit Threshold method accepts an opaque grayscale document and maps
8-bit grayscale values at or below the chosen 0–255 cutoff to black. The
sample is converted to the document's Y-prime encoding and rounded to the
nearest 8-bit value before comparison. Neither method changes the source.
Color and transparency are refused rather than silently converted; linked
layers are also refused because their file contents may change during export. Layers, profile, resolution and other metadata are omitted. Save an
XCF to keep the editable source. Repeat Export retains this explicit choice.
Old adapters do not advertise methods they lack. Dithering and a preserved
editable Bitmap document mode remain future work.

The private serializer writes PSD v1 Bitmap mode, one one-bit channel, raw
row-major image data, and empty color-mode, resource and layer sections. Rows
stream in bounded chunks, black pixels use the set bit and unused row-padding
bits are zero. A shared atomic local-file transaction keeps an existing target
intact on validation, source, cancellation or pre-commit I/O failure and
refuses symlink targets. The engine samples a private duplicate, so export does
not change the source pixels, history, dirty state or file identity.

Reference: [Adobe Photoshop File Formats Specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/).
Optimized and address/undefined-sanitized pure C tests check literal bytes,
odd widths, chunk boundaries and refusals. A 9-by-2 test image was independently
read with macOS ImageIO, which reproduced all 18 source pixels. Public-facade
checks against all four supported engines reopen and re-export a Bitmap PSD,
check the binary pixels, and verify failure leaves the destination unchanged.
A focused real-window test exercises the sheet, document export and Repeat
Export; an older adapter disables the option. Full editor compatibility,
review and integration remain open for this candidate.
