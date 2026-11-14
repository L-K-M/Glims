# Photoshop Bitmap PSD work

GIMP's PSD loader reads Photoshop Bitmap images as indexed images; its PSD
exporter emits indexed PSD instead of Bitmap mode. The work in this branch
starts a preserving export path for opaque, binary black-and-white images.
It does not yet add a document mode, conversion controls or an export command.

The private serializer writes PSD v1 Bitmap mode, one one-bit channel, raw
row-major image data, and empty color-mode, resource and layer sections. It
accepts only exact 0/255 luminance; conversion, alpha, metadata and any
potentially destructive flattening must be handled explicitly by its caller.
Rows are streamed in bounded chunks, black pixels use the set bit and unused
row-padding bits are zero. A shared atomic file transaction keeps an existing target intact on
validation, source, cancellation or I/O failure and refuses symlink targets.

Reference: [Adobe Photoshop File Formats Specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/).
Optimized and address/undefined-sanitized pure C tests check literal bytes,
odd widths, chunk boundaries and refusals. A 9-by-2 test image was independently
read with macOS ImageIO, which reproduced all 18 source pixels. Further work
must add engine and interface integration, compatibility
checks across supported engines, and round-trip tests before this is usable.
