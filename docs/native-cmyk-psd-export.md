# Native CMYK PSD export

Native CMYK documents can export their four authoritative process inks as a
flat PSD, using their exact source ICC profile. Export offers PSD at 8-bit and
16-bit precision, including hidden inks. No samples pass through RGB. Float
refuses before output; XCF retains its precision. The existing RGB-to-CMYK
conversion workflow remains separate.

Slot182 snapshots the four validated scalar buffers with GEGL copy-on-write
and retains the admitted ICC bytes before servicing any nested calls. The
native document's pixels, UUIDs, dirty state, file identity and Undo are unchanged.
Swift remembers the successful destination/settings for Repeat Export. An
incompatible format, merged-appearance request or destination profile refuses.

The private serializer writes PSD v1, uncompressed planar samples, native U8
or big-endian U16 and the exact ICC resource. Dimensions are at most 30,000
pixels and total file length at most 2,147,483,647 bytes. Layers, alpha, print
resolution and other metadata resources are omitted; the Export form states
its preservation policy. This is one native CMYK output route, not complete
CMYK command support or Photoshop 4 parity.

## File transaction and cancellation

The absolute local .psd destination is never opened for truncation. Output
streams into a private exclusive sibling in an opened parent directory. Writes
handle short results and interruptions. Only successful serialization, permission
application, file sync, close and a final cancellation check permit atomic
rename. Known symlink/nonregular targets refuse; rename never follows a late
racing destination symlink. Existing regular files use last-writer replacement,
not cross-process compare-and-swap. Ordinary permission bits are preserved on
replacement; new files are private. Other ownership/ACL/xattr metadata and
power-loss directory durability are not promised.

Failure attempts to remove the uncommitted temporary while retaining the primary
error. External permission/filesystem failures can prevent cleanup; no finite
procedure can guarantee removal then. After a successful rename, the result is
success even if closing the parent directory encounters a later cleanup error.

Export holds the engine's busy gate across snapshots, streaming and cleanup.
Read RPCs and cancellation can run at bounded context-dispatch checkpoints;
mutations, close, active strokes/filters and overlapping exports refuse. A
progress cancel signal and the lock-protected shutdown flag both abort before
publication. Polling does not bound an individual blocking disk or native call.
The activity records its source document so progress and Cancel reach its window.

## Qualification in progress

The private transaction passes 251 independent checks in optimized and ASan/
UBSan builds: new/replacement files, permissions, exact codec output, symlinks,
nonregular targets, invalid paths, source failures, early/mid/final cancellation
and a subprocess file-size-limit write failure. A separate syscall fixture passes
691 checks across 24 scenarios in both builds, including sync/close/rename/chmod
failures, short/interrupted writes, cleanup refusal and descriptor reuse after a
failed close. Negative controls reject unsafe close retries and ignored sync
errors. Remote filesystems and crash/power loss have not been injected.

All four engines pass 174 independent native numeric checks each covering exact
U8/U16 samples and ICC, reordered/renamed/hidden inks, file replacement, source
state preservation and invalid-mode/profile/path/dimension sentinels. Another
22 checks each cover read delivery, busy refusals, cancellation, retry and shutdown
using a test-only nested checkpoint. The actual CMYK workflow, native Export
sheet, Repeat Export, incompatible-setting preservation and float refusal pass.
All 1,523 Swift tests and rebuilt native adapter conformance pass. Three
independent reviews of the bridge, file transaction and UI found no important
findings. An independent reader fixture passes 38 checks on each engine:
the unmodified PSD loader imports U8/U16 files as RGB, with appearance within
one 8-bit level of a double-precision LittleCMS oracle using the actual effective
imported profile. This is appearance interoperability, not native CMYK reimport.
The full app matrix, standalone packaging, startup and latest CI remain pending.

Reproduce with a matching isolated adapter producer and an external CMYK ICC:

```sh
bash scripts/test-cmyk-psd-file.sh
bash scripts/test-cmyk-psd-file-faults.sh
python3 scripts/test-native-cmyk-export.py --producer /absolute/adapters/GIMP_3_2_8 \
  --cmyk-profile /absolute/source.icc
python3 scripts/test-native-cmyk-export-control.py --producer /absolute/adapters/GIMP_3_2_8 \
  --cmyk-profile /absolute/source.icc
python3 scripts/test-native-cmyk-psd-import.py --producer /absolute/adapters/GIMP_3_2_8 \
  --cmyk-profile /absolute/source.icc
```

The actual app scenario is `GLIMS_SMOKE_CASE=cmyk`. Set
`GLIMS_SMOKE_CMYK_PICKER=1` only with an external desktop driver to accept the
native file sheet at the exact temporary path printed by the fixture.
