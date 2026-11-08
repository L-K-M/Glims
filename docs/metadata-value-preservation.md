# Exact metadata value lists

A real-controls test exposed a successful four-value IPTC write returning
only three values: its empty member disappeared. Separate native tests also
proved a one-value write appended to the old list instead of replacing it.
The three regression checks failed before this change.

IPTC writes now clear the old private tag first. Repeatable tags use the
multiple-value setter even for a one-value replacement. Arrays and text
are read back and compared exactly before the image receives the private
copy. If the native representation cannot preserve a requested value,
the operation returns Unsupported and leaves metadata and history intact.
Numeric scalar tags retain native canonicalization. Copy verification also
compares complete ordered IPTC string vectors, alongside the raw checks.
Facade inputs remain count-bounded; no caller terminator is assumed.

The native suites pass 1,883 / 1,669 / 1,883 / 1,883 checks on the four
engines. Nonempty multiline/duplicate lists and single-value replacement
succeed; empty entries are refused atomically by the current native stack.
The nine pinned forced-error checks still pass. Independent source review
found no important issue; its remaining focused-coverage gaps concern
copy-loss isolation and repeatable tags beyond Keywords.
