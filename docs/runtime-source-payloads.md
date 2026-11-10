# Explicit local runtime payload collection

`scripts/collect-runtime-source-payloads.py` copies explicitly declared regular
files into a new uncompressed tar. It does not evaluate Tcl, call MacPorts or
Git, fetch files, unpack archives, discover installed packages, or inspect
licenses. Archive bytes remain opaque. The script is standalone and has no
dependency on the separate core-source collector.

```sh
python3 -I -B scripts/collect-runtime-source-payloads.py \
  --spec /tmp/reviewed-runtime-inputs.json --output /tmp/new-runtime-inputs.tar
```

Success means the declared local bytes matched their expected sizes and
SHA256s. It always records `corresponding_source_complete: false`,
`source_delivery: "local_collection_only"`, `binary_binding: null`, and
`historical_patch_payloads_verified: false`. Installed identities and evidence
descriptions are caller-supplied snapshot metadata, not a fresh registry,
historical-commit or bundled-binary attestation. This is not a complete source
delivery or license/release-compliance declaration.

## Closed request schema, version 1

Every object rejects missing and unknown fields; repeated JSON keys, nonfinite
numbers, invalid types and duplicate references are refused. The five required
top-level fields are:

| Field | Contents |
| --- | --- |
| `schema_version` | Integer `1`. |
| `roots` | Map of unique root IDs to absolute canonical directory paths. IDs match `[a-z0-9][a-z0-9_-]{0,63}`. |
| `payloads` | Map of lowercase 64-digit SHA256 keys to `{size, sources}`. Each source is `{root, path}`, naming a declared root and a strict relative file path. |
| `components` | Map of component IDs, with the same ID syntax, to `{installed, bindings, unresolved_patches}`. |
| `evidence` | List of `{label, sha256, notes}` metadata records; labels are unique. These evidence bytes are not automatically collected. |

An `installed` object requires `registry_id` (unique positive integer), `name`,
`epoch`, `version`, `revision`, `variants`, `requested_variants`, `archs`, and
`ports_commit` (40 lowercase hex digits). Epoch/revision are nonnegative
integers. Variants and requested variants retain their exact strings; neither
Tcl branches nor applied variants are inferred.

A binding is `{role, name, version, sha256}`. Role is `archive`, `recipe` or
`portgroup`; version is a nonempty string for a PortGroup and `null` otherwise.
Every component has exactly one recipe binding. A duplicate
`(role, name, version)` within one component is refused, including conflicting
digests. Components may share a PortGroup payload. Different historical
digests for an equal group name/version remain distinct payloads. Every root
and payload must be referenced, and every declared source alias must verify.

Each unresolved patch declaration is `{name, guard}` with literal original
recipe text; duplicate pairs are refused. It contains no patch bytes or
claim that a conditional patch was applied. A source entry uses a relative
path without empty, dot, parent, backslash or control-character components:

```json
{"root": "macports", "path": "var/macports/distfiles/example/source.tar.xz"}
```

Put both verified registry and installed-image Portfile paths in one recipe
payload's `sources` list when they must match. Both are read and checked; the
recipe is exported once. The component schema accepts later selected ports
without hardcoding the initial three names or IDs.

## Bounds and file handling

The request is at most 1 MiB and eight JSON levels. Limits are 16 roots,
128 components, 64 unique payloads, 16 aliases per payload, 64 bindings and
64 patch declarations per component, and 16 evidence records. Strings have
at most 4,096 UTF-8 bytes. Each file is at most 128 MiB; total unique payload
bytes are at most 256 MiB, output manifest 2 MiB, and final tar 260 MiB.

Callers resolve root aliases before writing the spec. Input roots containing
symlink ancestors, source symlinks, directories, devices and FIFOs refuse.
Directory/file descriptors use no-follow opens; leaf files use nonblocking
read-only opens and must be regular. Length, EOF, hash and file metadata are
checked around reading; root/ancestor/leaf identities are rechecked before
publication. All source aliases verify even when a blob is shared.

The output parent must exist. The CLI may resolve its parent and the spec's
parent, so a spec and different output can both reside in `/tmp`. The spec
parent is not implicitly a protected source root. The spec file and every
declared input root remain protected: output inside a root or at an existing
path, including a hardlink or dangling symlink, is refused. Directory identities
along output ancestry catch case aliases of source roots.

Staging and cleanup use a pinned output-parent descriptor and a private
directory. The completed tar is flushed/fsynced and published by an exclusive
hardlink; a competing output is never replaced. Inputs are copied, never
hardlinked into the output. Cleanup removes only validated owned entries;
an unexpected replacement or cleanup I/O failure can leave staging evidence
and is reported rather than deleting another entry.

Tar entries are regular files with fixed names `manifest.json`,
`payloads/sha256/<digest>` and `request.json`, sorted and normalized to mode
0644, uid/gid/mtime zero and empty owner names. `request.json` preserves exact
validated request bytes; the manifest records its SHA256, declared identities,
bindings, verified payload sizes/paths and unresolved inputs. No input filename
or recipe text becomes a tar path.

## Initial scope and verification status

The reviewed initial inventory specifies GTK3, Ghostscript and jbig2dec:
six cached archives, three original recipes and seven unique PortGroups,
with eight PortGroup component references and 16 unique payloads total.
Recorded installed ports commit is `6a711eae0e6a12978e50fda5be276da231523c53`.
Its historical patch bytes remain unverified. Current-tree candidates and
the cached ports archive marker `4c08b016c1c498b30295f05d72c40921fee87b5a`
are not substitutes; a failed historical lookup establishes no patch identity.
Deduplication does not imply coverage of all 119 bundled components.

All 36 synthetic tests pass, covering opaque-byte copying, shared bindings,
determinism, aliases, schema/bounds, symlink/path swaps, output containment,
concurrent publication and injected I/O failure/interruption. The full local
packaging suite passes 90 tests on this source revision.

An actual offline collection on 2026-11-10 read the explicit three-port
inventory and all 19 declared source aliases. It produced 16 unique payloads
(120,378,775 bytes), plus the exact request and manifest, in an archive of
120,422,400 bytes. SHA256:
`1b82db9fb6073024dbd8fd17ec527e2571a8ec7b617dc548192974bd565dd3ce`.
Independent tar streaming verified all 18 regular members, normalized headers,
exact request bytes, every expected payload size/SHA, source alias hashes,
component bindings and the mandatory partial-scope flags. No archive was
unpacked. The first external verifier incorrectly required the manifest's
sorted binding lists to retain request order; its comparison was corrected
without changing the collector or archive.

The initial spec, archive and verification receipt remain local review
artifacts, not a public source download or released-binary binding.
Independent code review, hosted CI and integration remain pending.
