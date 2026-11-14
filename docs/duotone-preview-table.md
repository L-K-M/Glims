# Duotone alternate-color table (private candidate)

Adobe documents PSD image resource 1066 as alternate ink colors followed by
an ordered array of encoded Lab colors, usually with 256 samples. This bounded parser
accepts version 1, up to four alternate colors and exactly 256 samples. It
copies the color words and Lab triples without color conversion. Other valid
resource forms are declined, allowing callers to preserve them opaquely.
Adobe says Photoshop does not read or use this resource; its description does
not establish how entries map to image samples.

The Photoshop CC 2018 fixture contains two alternate colors and 256 triples;
the test locates resource 1066 independently and verifies its color words and
table endpoints. Optimized and AddressSanitizer/UndefinedBehaviorSanitizer
runs pass 814 checks each, including all truncated lengths and malformed
counts. This parser does not yet retain the resource on import, render its
colors, or update or invalidate the table after changes. A preview must also
handle the destination color profile and prove its lookup mapping before use.

Reference: [Adobe Photoshop File Formats Specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/), image resource 1066.
