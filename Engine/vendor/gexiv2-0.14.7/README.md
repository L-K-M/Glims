# GExiv2 private metadata layout

Unmodified `gexiv2/gexiv2-metadata-private.h` from GExiv2 0.14.7.
Upstream: https://gitlab.gnome.org/GNOME/gexiv2/-/tree/gexiv2-0.14.7
License: GPL-2.0-or-later, stated in the header.
SHA256: `b0a6eb3de8b21500b1eed693dde93880ac649e5f7c37baaaab7ae51daab10f8d`.

The adapter uses this pinned layout only to count all current Exiv2 XMP
entries. GExiv2's public listing excludes zero-count values, and Exiv2's
packet encoder also omits empty LangAlt maps, so those two public views
cannot prove a metadata copy is complete. An inventory-count mismatch
refuses the write before duplication. No dependency source is patched.

The C++ bridge requires exact compile-time and runtime GExiv2 0.14.7 and
Exiv2 0.28.9 before accessing private state. Dependency updates must review
this layout and the enumeration behavior deliberately; unknown versions
refuse rather than dereferencing an assumed layout. The header remains
GPL-2.0-or-later; the combined adapter is conveyed under GPL-3.0-or-later,
whose license text is distributed in the project's LICENSE.
