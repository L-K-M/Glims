# Lab sample codec (private, bounded)

This document describes the private pure-C Lab sample row codec added in
`Engine/lab-samples.h` and `Engine/lab-samples.c`, with checks in
`Engine/tests/lab-samples-tests.c` run by `scripts/test-lab-samples.py`.

It is a candidate codec only. It does **not** enable Lab documents, Lab
rendering, Lab storage, or Lab edits in Glims.

## Candidate API and representation

The codec is explicit and independent from ink/component scalar APIs:

- `GlimsLabRole`: `GLIMS_LAB_ROLE_L`, `GLIMS_LAB_ROLE_A`, `GLIMS_LAB_ROLE_B`.
- `GlimsLabFormat`: `GLIMS_LAB_FORMAT_U8`, `GLIMS_LAB_FORMAT_U16`,
  `GLIMS_LAB_FORMAT_FLOAT`.

`glims_lab_decode_row` converts encoded, unaligned sample bytes to unaligned
physical `double` values. `glims_lab_encode_row` converts unaligned physical
`double` values to encoded, unaligned sample bytes. All loads and stores use
`memcpy`; both buffer parameters use `void` pointers, so callers need not construct
misaligned typed pointers. The implementation makes no alignment or aliasing
assumptions. All source bytes must remain unchanged and all buffers remain alive
until the call returns.

## Exact conversions

- U8 decode: `L = 100*q/255`, `chroma = q - 128`.
- U16 decode: `L = 100*q/65535`, `chroma = q/257 - 128` (ICC v4). Neutral
  chroma code `32896` decodes to `0.0` (not legacy 32768 behavior).
- Float decode: raw physical `binary32` loaded by `memcpy` and converted to
  `double`. All finite extended `binary32` values are accepted. Signed zero is
  preserved through the `float` to `double` conversion.

## Encoding rules

U8/U16 encode accepts only finite represented input `double` values in nominal
ranges: `L` in `[0,100]`, chroma in `[-128,127]`. Values are quantized to the
exact mathematical nearest integer code with halves rounded up, relative to the
represented input `double` and not to a separately rounded intermediate.

To avoid lost deciding bits near half boundaries (especially U16 chroma ties
around `q/257 - 128` and neighbors from `nextafter`), quantization uses an
ordinary approximate code followed by a single-FMA exact boundary-sign comparison
against its lower and upper half boundaries. The constants at these boundaries
are exact integers; chroma is not shifted by 128 before the comparison. This
keeps tie decisions stable when a plain `(x + 128) * 257` or `long double` path could lose the deciding bit on
platforms where `long double` has `double` precision.

Float encode rejects non-finite values and values whose magnitude exceeds
`FLT_MAX` (overflow). Finite underflow follows the C `float` cast. Signed zero
is preserved. Every finite `binary32` value round-trips exactly through
decode/encode. Storage acceptance is not a guarantee that a later color
transform can render every extended value. In particular, finite extreme Lab
inputs require separate transform-domain validation; this codec does not clip
them to accommodate a renderer.

## Validation, overlap, and atomic failure

Enums and basic arguments are validated even for `count == 0`. `NULL` source or
destination buffers are accepted only when `count == 0` and other required
arguments are valid.

Sample byte counts and address-range endpoints are checked for overflow.
Unsigned 16-bit samples use native byte order; file endianness is outside this
private memory codec. No dynamic allocation is performed.

Float decode and every encode perform a full first pass that validates every
sample before a second pass writes any output. Every unsigned code is valid,
so integer decode needs only the complete row argument validation before writing.
If a late input is bad, the call fails and leaves all destination bytes unchanged.

All source/destination overlap is forbidden, including equal pointers. Overlap
is detected with bounded `uintptr_t` range comparisons and rejected before any
write. The implementation also documents that caller memory must remain
immutable for the duration of a call.

## Tests and runner

`Engine/tests/lab-samples-tests.c` uses independent expected constants and
rational/midpoint calculations (not an oracle that mirrors the implementation).
Coverage includes exhaustive all-256 and all-65536 code round-trips for each
role, ICC v4 literal neutral/extrema values, integer half ties and `nextafter`
neighbors, partial/unaligned buffers with canaries, zero-count/invalid
enum/NULL/size-overflow cases, overlap refusal, and late-bad-input unchanged
output. Float cases include `±0`, signed chroma, extended negative and huge
values, min subnormal, `FLT_MIN`/`FLT_MAX`, NaN/Inf/range/overflow refusals
with unchanged output, and `double` underflow behavior.

`scripts/test-lab-samples.py` supports `all` (default), `optimized`, and
`sanitized` modes. It uses `xcrun clang` on Darwin when available, otherwise
`clang`, builds C11 code with `-Wall -Wextra -Werror -pedantic`, `-O2` for
optimized, and `-O1 -g -fsanitize=address,undefined` with
`-fno-sanitize-recover=all -fno-omit-frame-pointer` for sanitized. It links `-lm`, runs commands with a 60-second timeout, and cleans up a
temporary build directory.

## Non-goals

This change does not add or enable Lab image documents, rendering, storage, UI,
editing operations, import/export integration, or any engine/app behavior beyond
the private row codec and its isolated tests. No public mode enum, facade,
plate-map acceptance, document adoption or operation policy is changed.

The integer convention follows [ICC.1:2022, Tables 12–13](https://www.color.org/specification/ICC.1-2022-05.pdf). It is distinct from legacy ICC v2 Lab encoding.
