# Offline core source inputs

`scripts/collect-core-sources.py` creates a new, uncompressed tar archive from
explicit **local Git commits**. It collects GIMP, GEGL, babl, their recursively
pinned gitlinks, and a Glims build-recipe/adapter snapshot. It uses Python3.10+
and Git, without downloading, checking out, updating submodules or building
anything. This is one input to source delivery, not a complete release source set.

No CI/release gate invokes it yet. Do not treat the installed-port recipe
inventory or this three-project archive as complete corresponding source for
all bundled dependencies.

## Inputs and output

For the pinned engine, the local install stamp identifies these commits:

| Project | Revision | Local source path under the Glims checkout |
|---|---|---|
| GIMP | `7addd2b77efb798bbdc4d2fb082e786a48478ced` (`GIMP_3_2_8`) | `_engine/src/GIMP_3_2_8/gimp` |
| GEGL | `02096df3c53f95970c4347a57b43ee571c78a968` (`GEGL_0_4_72`) | `_engine/src/GIMP_3_2_8/gegl` |
| babl | `4abcea43550699e0c93e6f154c44d68822e62753` (`BABL_0_1_128`) | `_engine/src/GIMP_3_2_8/babl` |
| GIMP data gitlink | `fe4ecc0bf70fc8ff3bd929ce6abdd50fb5621072` | `_engine/src/GIMP_3_2_8/gimp/gimp-data` |

Each root input takes a repository directory and a revision. Revisions are
resolved once to full commit IDs. The Glims revision must describe the actual
build being documented; a later Main revision is not a substitute. For example,
the earlier verified API 164 bundle records Glims source `2453eab266b26b48b1261e93225c505846e931df`.
This illustrative command uses that earlier bundle's revision. The recorded
offline collection below used Glims recipes from `b425e320`; binding that
source set to a released binary remains a separate review/validation step.

```sh
python3 -I -B scripts/collect-core-sources.py \
  --gimp /absolute/Glims/_engine/src/GIMP_3_2_8/gimp GIMP_3_2_8 \
  --gegl /absolute/Glims/_engine/src/GIMP_3_2_8/gegl GEGL_0_4_72 \
  --babl /absolute/Glims/_engine/src/GIMP_3_2_8/babl BABL_0_1_128 \
  --glims /absolute/Glims 2453eab266b26b48b1261e93225c505846e931df \
  --submodule gimp/gimp-data=/absolute/Glims/_engine/src/GIMP_3_2_8/gimp/gimp-data \
  --output /tmp/glims-core-source-inputs.tar
```

Every gitlink requires an explicit mapping `COMPONENT/PATH=LOCAL_REPO`; nested
ones use the full parent path, such as `gimp/gimp-data/nested`. The parent
commit supplies the child commit ID; the mapped repository's HEAD never
replaces that pin. Missing commits/mappings, unused mappings and excessive
recursion refuse collection. No `.gitmodules` URL is followed.

Output must be new, with an existing parent directory, outside all input
working trees, actual/common Git directories and resolved object directories.
Input repositories with nonempty object-alternates files are refused in this
initial slice; no indirect object store is silently omitted from protection.
Existing files or symlinks
are never overwritten. A temporary archive in the output directory is
published with an exclusive atomic hard link only after it is complete;
unsupported hard-link filesystems fail rather than falling back to replacement.

## What the archive establishes

`sources/{gimp,gegl,babl}/` contains committed source files and recursively
mapped submodules. `build/glims/` contains the selected commit's `Engine/`,
`Sources/CGlimsEngine/`, `scripts/`, `Resources/Info.plist` and `LICENSE`.
These retain the adapter, facade, build, dependency bootstrap, packaging and
license-generation recipes without treating ignored engine/dependency outputs
as source. The archive does not capture an installed prefix, configured build
trees or a binary build's actual toolchain/options; those need separate
provenance evidence from its install stamp and Meson introspection.

An isolated bare Git view reads existing local objects. It neutralizes
`export-ignore`/`export-subst` and original repository archive attributes, then
checks each exported file/symlink against its committed Git blob ID. File and
symlink SHA256 values, sizes/modes, component commit/tree IDs and selected paths
are recorded in `manifest.json`. Symlink payloads are preserved, never followed;
absolute/escaping targets and unsafe/special archive paths refuse collection.
Before writing archive members, the collector validates the complete committed
symlink graph, including mapped submodules. It substitutes links before parent
traversals and confines each target to its owning repository's archive root,
without consulting host filesystem targets. Contained multihop and dangling
links remain valid. Each resolution allows at most 40 link expansions and
4,096 path components; cycles or larger resolutions refuse collection.
Graph lookup uses Unicode NFD normalization and case folding to account
conservatively for Mac filename aliases. Distinct committed spellings that
collide under that comparison, including directory names, refuse collection;
the exported names and link payloads remain byte-exact. This does not certify
every platform's filename aliases or extraction behavior.

Tracked worktree dirtiness is observed and recorded with optional Git index
writes disabled. Worktree content is never exported. Untracked files are neither
consulted nor exported; the manifest does not claim a globally pristine checkout.
Repositories with configured clean/smudge filters are refused before status
inspection rather than executing those programs. Global/system Git configuration,
optional index writes and lazy/network fetching are disabled for Git subprocesses.

Bounds are 68 repository nodes, depth 16, 100,000 files and 4 GiB of selected source
payload; Git commands have timeouts and accepted metadata has a 32 MiB limit.
These are collection bounds, not a promise of constant-memory processing.
The collector records the supplied project labels and resolved objects; it does
not authenticate remote origins or bind them to a binary. A later release gate
must compare these pins with the verified artifact's build evidence.

The manifest always includes:

```json
{"corresponding_source_complete": false, "source_delivery": "local_collection_only"}
```

It explicitly omits MacPorts dependency sources/conditional patch payloads and
other build/runtime dependencies. In particular, GTK, Python's dependencies,
Ghostscript and other GPL/LGPL/AGPL-labelled bundled components remain outside
this slice. No public source hosting/offer, legal completeness determination,
signing/notarization or release publication is performed.

## Focused tests

```sh
python3 -I -B -m unittest discover \
  -s scripts/tests -p test_collect_core_sources.py -v
```

The fixtures create only temporary synthetic repositories. They verify exact
commit/recursive-gitlink payloads, missing objects/mappings, symlink preservation
and refusal, recipe/hash scope, dirty input isolation, attribute neutralization,
output overlap/overwrite/race protection (including external object-store
symlinks and alternate stores), bounds, configured-filter refusal and
deterministic archives. CLI cases additionally cover composed-link escapes,
case/Unicode aliases, filename collisions, and contained multihop/dangling links.
They do not execute or build the app/engine, access the real dependency registry,
or establish completeness of the real source set.

On 2026-11-10, the initial candidate passed 73 packaging-script tests, including
19 collector fixtures. Later CLI regressions exposed four failures in the
pre-fix collector: composed-link escape, case-alias escape, Unicode-alias escape
and case-colliding committed names. After the graph fix at `d144af4`, all
26 collector fixtures and all 80 packaging-script tests passed.

A real offline collection with the corrected collector used the pinned
GIMP 3.2.8, GEGL 0.4.72, babl 0.1.128 and exact GIMP data gitlink, with Glims
recipes still pinned to `b425e320`. An independent pass read the archive without
extracting it and verified all 8,760 file/symlink payloads against manifest
SHA256 and committed Git blob IDs, plus modes and directory sets. Payload rows
and component records matched the original collection exactly. The entire
281,620,480-byte archive retained the original SHA256:
`bd39ed0efa1f7132568b7806e64175811edca86f6911aea4f5b966c48c22f0a6`.
The manifest still records `corresponding_source_complete: false`; these checks
do not cover the omitted dependencies or bind this archive to a released binary.
