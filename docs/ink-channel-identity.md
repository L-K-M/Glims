# Native ink identity

Facade slot 189 reads an authoritative ink plane's document-scoped UUID,
color mode, canonical role, ordinal and plane count. CMYK roles follow the
persisted C/M/Y/K map, regardless of channel names or native reordering.
Multichannel planes have an unspecified role. The same UUID in unrelated
documents is not an automatic binding permission. This query is a Recorder
prerequisite; it does not itself enable ink recording or replay.

The caller supplies the output size. A short or null output refuses untouched;
an admitted output preserves its size and unknown tail while clearing the
known payload on failure. Reads are allowed during engine work, change no
pixels or history, and validate the map, storage and CMYK profile before
publishing identity. IDs from another image, non-ink channels, damaged storage
and unsupported ordinary images refuse.

Swift exposes owned identity values and a separately gated committed Levels
method through slot 184. The loader accepts the required production prefix
through slot 182, copies only complete advertised known fields, and zeroes
missing optional fields. Slots 183–189 each retain capability checks. A larger
future tail is ignored. It no longer reads a current-size pointee from an
older producer.

## Verification

- Native identity fixtures: 1,269 checks per engine on GIMP 3.2.8, 3.0.8,
  3.2.0 and master, plus general conformance. Coverage includes all six
  mode/precision combinations, busy reads, output canaries, XCF identity,
  rename/reorder and damaged maps/profiles.
- Twelve Swift decoder/prefix tests pass. Real guard pages immediately after
  182-, 184- and 188-slot allocations detect any full-size legacy-table read.
- The live Swift fixture passes 104 checks per current engine and 27 checks
  against the older 184-slot producer. The latter first failed in the loader,
  then passed after the bounded copy fix. Direct Levels is compared with an
  independent scalar Fill oracle and exact Undo/Redo rendering.
- All 130 Python preflight tests pass. Independent native and Swift reviews
  are clear after the confirmed loader issue was corrected.

Full app qualification and CI are tracked in the integration PR. This does
not establish Recorder coverage or Photoshop 4 parity.
