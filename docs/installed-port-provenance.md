# Installed MacPorts recipe inventory

`scripts/installed-port-provenance.py` records exact installed recipe metadata
for an explicit set of ports. It uses Python 3.10+ and the standard library.
It runs no MacPorts command, Tcl, network request, build or package operation.
It does not read the mutable current ports tree.

```sh
python3 -I scripts/installed-port-provenance.py \
  --prefix /path/to/macports \
  --port aom --port zlib --port libidn2 \
  --output /tmp/new-installed-recipes.json --strict-metadata
```

The output parent must exist. An existing output is refused unless
`--overwrite` explicitly requests replacement. Output inside the source
prefix is always refused, including with `--overwrite`.

The registry is opened only with `mode=ro&immutable=1`, after checking that
its WAL is absent/empty and the database is stable while hashing. Database
hash/stat and WAL evidence must remain identical after inventory. A nonempty
WAL is refused rather than ignored; a database or WAL change makes the whole
report incomplete. This avoids the shared-memory bookkeeping writes that a
normal SQLite read-only connection can still perform.

For each requested name, the tool requires one `ports.state='installed'`
entry. Inactive `imaged` entries are excluded. It preserves installed epoch,
version, revision, variants, requested variants and architecture. It checks:

- The registry Portfile and software image's `+PORTFILE` against the exact
  SHA-256 and size in the installed registry key.
- The image's `+CONTENTS` header against the installed entry, retaining its
  ports commit and selected toolchain/platform metadata.
- Every recorded PortGroup's original file against its registry SHA-256 and
  size. The optional `+STATE`, when present, must confirm the recipe digest.

Recipe text is preserved through original file paths and content hashes;
the JSON does not copy/evaluate recipes or disclose arbitrary recipe text.
The currently supported active-image layout is an unpacked software image
directory, as used by the inspected MacPorts 2.12.7 prefix. Unsupported image
layouts are explicitly incomplete.

`metadata_complete` concerns only this requested metadata set. Missing,
ambiguous, mismatched or unstable evidence produces issues and a false flag.
Default mode still writes that diagnostic JSON and exits zero;
`--strict-metadata` writes the same report and exits one. Argument/output
errors exit two. Complete metadata still always reports:

```json
{"corresponding_source_complete": false, "source_delivery": "not_assessed"}
```

This is not a source archive, source-completeness assessment or release gate.
It does not infer conditional patch/distfile sets: for example, zlib's
installed Portfile contains a patch that applies only to the minizip subport.
It does not establish historical patch payloads from a later ports tree,
freeze upstream Git tags, validate full upstream source archives, or treat
license caches as source delivery. The recorded ports commit remains
metadata; the corresponding historical tree is not fetched or verified.

The focused tests use temporary SQLite registries and recipe/group fixtures:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -I -m unittest discover \
  -s scripts/tests -p test_installed_port_provenance.py -v
```

Fifteen checks cover original recipes versus a differing current tree,
independent SHA/size mismatches, ambiguous installed entries, inactive images,
missing/corrupt groups, database/WAL changes, required commit metadata and
output protections. A read-only sample of installed aom, zlib and libidn2
verified their exact recipes/groups; registry DB, WAL and SHM bytes and
modification/change timestamps were unchanged before/after that sample.
