# Typed language-alternative read facade

API1 appends slot139 `image_metadata_languages` and slot140
`metadata_languages_free`. The reader delegates to the merged internal parser;
it does not enable a writer or change generic metadata editing policy.

The returned plain-C array owns both UTF-8 strings in each pair, with an explicit
count and one all-NULL sentinel. It survives image closure and engine shutdown;
free it through slot140 while the library remains loaded. Both outputs clear
before dispatch, including NULL-engine refusal. No borrowed metadata or native
layout crosses the facade. A read during a stroke/filter is allowed.

The Swift wrapper performs one read, frees the C array on decode success or
failure, and returns immutable owned language/text values. It rejects invalid
counts, NULL/invalid-UTF-8/empty fields, duplicate case-folded languages and a
bad terminator before publishing the result. No native pretty-string parsing
or language/text reconstruction occurs in the frontend.

Validation:833 unit tests pass. All four real140-slot adapters pass their
existing native suites (1917 checks on3.2.8,3.2.0 andmaster;1703 on3.0.8).
A public-header-only harness passes30 checks on every engine: known maps and
Unicode, refusal output clearing, reads during actual stroke/filter sessions,
history/dirty preservation, native serialization and ownership across closure
and engine shutdown. The Core-only fixture generator validates independent
known maps before saving the committed1.6KB XCF. A fresh pinned run through the
public driver also passes with fatal GLib criticals enabled. The focused
`metadata-language-read` app smoke case passes five real Swift-bridge checks
on every engine using an explicit `GLIMS_LANGUAGE_FIXTURE`: known maps,
Unicode, native refusal, history preservation and Swift ownership after close. Master emits its
existing missing cached-XML cleanup diagnostic; no GLib critical or test fails.

Reproduce:

    python3 scripts/test-metadata-language-facade.py build
    python3 scripts/test-metadata-language-facade.py run --library LIBRARY --work PRIVATE_WORK

Regenerate the known fixture with `make-metadata-language-fixture.py build`,
using a producer matching the current full facade, then its explicit `run`
subcommand. Neither driver modifies a producer or the user's native settings.

One bounded LongCat implementation timed out with a partial result. Root
completed the contract and decoder checks. A bounded independent CLI review
claimed a report that did not exist, so it supplies no approval. A separate
relay inspected the five complete production bodies and recorded fingerprints;
that source inspection found no important issue. The native runtime evidence
above is Root-executed, separate from review. Hosted CI remains pending.
