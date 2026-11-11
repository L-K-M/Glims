# Foreign effect settings in compressed XCF

Opening bzip2 and XZ XCF now preserves the same supported explicit effect
blend/composite fields as plain and gzip XCF. Previously these compressed
inputs were refused when the native loader reported XCF: accepting the
normalized image would have lost those settings. The adapter now decodes a
bounded snapshot once and gives both the native image loader and the field
reader that same decoded stream. The original compressed file remains the
document's identity and is never rewritten during Open.

The private decoder accepts one complete stream, verifies its checksum and
refuses truncation, trailing data, unsupported checks and exceeded limits.
XZ permits its format-defined zero padding in multiples of four bytes;
concatenated streams remain outside this recovery contract. Input and
decoded output retain the existing 4 GiB recovery limits. XZ decoder memory
is limited to 512 MiB; bzip2 uses its low-memory decoding mode. Non-XCF
compressed data returns to the ordinary native format loader without a
partially decoded output. Gzip behavior and the public facade are unchanged.

The codec contracts are described in the
[XZ file format, section 2.2](https://tukaani.org/xz/xz-file-format.txt) and
[bzip2 low-level decompression API](https://sourceware.org/bzip2/manual/manual.html).
The adapter links the existing dependency prefix's bzip2 and liblzma libraries;
their absolute link inputs remain visible to the engine bundler.

Verification on 2026-11-11:

- The pinned 3.2.8 native fixture first reproduced two Open refusals in 31
  checks. With production `a760a43`, all 47 checks pass, including independent
  compressed fixtures, native normalization controls, rendered/raw pixels,
  recovered fields, clean history and unchanged original bytes.
- All four engines pass 7,454 existing native checks and 136 codec checks.
  Codec cases include exact and exceeded caps, truncation, corruption,
  trailing data, XZ padding, non-XCF fallback and multiple input/output buffers.
- The existing pinned gzip pathname-swap regression passes 117 checks.
- The ordinary editor workflow passes 3,233 checks against the fresh pinned
  adapter, using the unchanged reviewed Swift source with its build tree
  denied. This explicit-adapter debug run is not standalone release validation.
- SWE-2 completed a separate production source review with no important
  finding. It did not independently approve the root-authored runtime fixtures.

Raw local results are ephemeral under `/tmp/glims-completion/` with prefixes
`compressed-xcf-first-fix`, `compressed-xcf-a760-matrix`,
`compressed-xcf-gzip-regression` and `compressed-xcf-a760-broad`.
The 47-check native field oracle is specified for 3.2.8 only; the all-engine
counts cover the general suite and decoder cases. These checks do not imply
arbitrary XCF schema recovery or a complete final release audit.
