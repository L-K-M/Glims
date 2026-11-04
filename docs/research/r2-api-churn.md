<!-- Generated research record. Written by AI research agents on 2026-11-04 and
kept verbatim for provenance. Claims were not all verified; see the matching
review file and docs/research/README.md for corrections. -->

# Round 2: Engine API churn across GIMP releases (measured)

# GIMP engine internal API churn between releases, as a replacement front-end would see it (measured 2026-11-04)

**Bottom line:**
- **Bindings to the engine:** keeping them compiling across stable micro releases is cheap. In 5 of 8 micro intervals no function GIMP's UI calls changed; the median was 0 call sites to fix, the mean about 8, the worst 57 (3.0.6).
- **Minor releases:** 3.0.8 → 3.2.0 broke 11 such functions (19 call sites) and moved a header directory. It also replaced the text-layer "modified" model.
- **Not guaranteed:** internal changes do land in micro releases (3.0.4, 3.0.6, 3.2.4, 3.2.8). Some of them the compiler cannot catch: a signal gained an argument and a property was renamed in 3.0.6.
- **"Trivially easy" fails elsewhere:** tool and palette behaviour lives in GIMP's GTK code. A native front-end has to review and port 0–39 of those fixes per micro release, and about 100 per minor release, by hand.

## Method and data
- **Repositories.** New bare blobless clone `/tmp/gimp-fork-research/full-apichurn.git`, history since 2024-09-01, with `master` (2aef5e7), `gimp-3-0` and `gimp-3-2`. All `GIMP_3_*` tags are present: 3.0.0/2/4/6/8, 3.1.2/4, 3.2.0/2/4/6/8. I only read text from it; nothing was built or run.
- **Release topology (measured).**
  - 3.0.2, 3.0.4, 3.2.2 and 3.2.4 were tagged on master.
  - `gimp-3-0` branched at abfd6cd6 (2025-05-22); 3.0.6 and 3.0.8 come from it.
  - `gimp-3-2` branched at c246727b (2026-04-17); 3.2.6 and 3.2.8 come from it.
- **Method.** The source trees for the engine, UI and libgimp directories at every tag were extracted into `/tmp/gimp-fork-research/apichurn-work/<tag>`. My own Python scripts in `/tmp/gimp-fork-research/apichurn-scripts/`, run with `python3 -I`, did the analysis:
  - `snapshot.py` parses every engine header: prototypes normalised to return and parameter types, struct fields, enum values, GObject types. It also collects `g_signal_new` and property definitions from engine `.c` files, and every identifier and string literal used in the UI directories.
  - `churn.py` diffs the snapshots between tags.
  - `percommit.py` parses each engine header before and after each of the 318 commits that touched one.
  - `attrib.py` maps changes to commits.
  - `signals.py` compares signal parameter lists and property types.
  - `split.sh` sorts each interval's commits into engine-only, UI-only and both.
- **Outputs** are in `/tmp/gimp-fork-research/apichurn-out/`: `churn.json`, `percommit.json`, `attrib2.tsv`, `signals.txt`.
- **Parser check.** On the 3.2.8 → master header diff, 147 of the 158 prototype names on removed lines were whitespace re-alignment only. Real parameter-line changes were caught, for example the `scale_factor` additions.

Key commands:
```
git clone --bare --filter=blob:none --shallow-since=2024-09-01 https://gitlab.gnome.org/GNOME/gimp.git full-apichurn.git
git fetch ... refs/heads/gimp-3-0 refs/heads/gimp-3-2 'refs/tags/GIMP_3*'
git diff --stat <emptytree> TAG -- <dirs>          # batch blob prefetch
git archive TAG -- <dirs> | tar -x -C apichurn-work/TAG
python3 -I snapshot.py <tree> <tag>.json ; python3 -I churn.py OUT WORK T1:T2 ...
git log -p master gimp-3-0 gimp-3-2 ^GIMP_3_0_0 -- ':(glob)app/core/**/*.h' ...   # 318 commits
python3 -I percommit.py ; python3 -I attrib.py items.tsv ; python3 -I signals.py ...
git rev-list A..B -- <engine> / -- <ui> / -- <focus files>    # commit split
```

## 1. The surface a front-end would call (measured)
"Surface" means functions declared in the engine layers that GIMP's own GTK UI refers to. The "focused" subset counts only references from 108 UI files relevant to a classic editor: the tools in the brief, filter tool, canvas and display, the layers/channels/paths/undo/navigator/info/colour/brush palettes, and the layer/channel/path/edit/select/file/filter commands.

| Tag | Engine functions declared | **Surface functions** | UI references | UI files | **Focused subset** (refs) | GObject types used by UI | Structs with fields used by UI | Enum values used by UI | Signal / property names used* |
|---|---|---|---|---|---|---|---|---|---|
| 3.0.0 | 3529 | **1311** | 7306 | 427 | **674** (3006) | 107 | 122 | 404 | 103 / 483 |
| 3.2.0 | 3645 | **1358** | 7489 | 445 | **694** (3016) | 110 | 123 | 407 | 107 / 492 |
| 3.2.8 | 3647 | **1360** | 7532 | 445 | **699** (3044) | 110 | 123 | 409 | 109 / 498 |
| master | 3738 | **1373** | 7703 | 451 | **704** (3121) | 109 | 115 | 408 | 110 / 502 |

\*Matched by string literal, so these overcount.

- **Where the 3.0.0 surface lives:** app/core 949, libgimpbase 51, libgimpconfig 47, app/operations 46, app/vectors 39, libgimpmath 35, paint 29, gegl 29, libgimpcolor 29, then pdb, text, config, plug-in, file and xcf with 14 or fewer each. About 12% is in the stable public libraries.
- **Direct struct field access is heavy.** At master the UI uses `gimp->` 744 times across 39 fields (`gimp->config` alone 313) and `image->gimp` 219 times.
- **No private headers.** The UI includes no engine `*-private.h` header (only `libgimpcolor/gimpcolor-private.h`).
- **GimpGui vtable:** 27 hooks at every tag.

## 2. Churn per interval, comparing tag to tag (measured)
"Call sites" counts the UI references, at the older tag, to functions that were removed, renamed or changed signature. Every one of them would need editing.

| Interval | Kind | Commits | Removed | Renamed | Signature changed | Header moved | **Call sites (all)** | **Focused: functions / sites** | Engine-wide removed / changed† | UI-visible struct changes | Signal parameter changes | Property / enum removals used by UI |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 3.0.0→3.0.2 | micro | 54 | 0 | 0 | 0 | 0 | **0** | 0/0 | 0/0 | 0 | 0 | 0 |
| 3.0.2→3.0.4 | micro | 280 | 0 | 0 | 0 | 0 | **0** | 0/0 | 0/1 | 0 | 0 | 0 |
| 3.0.4→3.0.6 | micro (backports) | 817 | 0 | 1 | 4 | 0 | **57** | 3/6 | 1/10 | 7 | **1** | 1 property |
| 3.0.6→3.0.8 | micro | 468 | 0 | 0 | 0 | 0 | **0** | 0/0 | 1/0 | 1 (field added) | 0 | 0 |
| **3.0.8→3.2.0** | **minor** | 2415 | 2 | 1 | 8 | 38 | **19** + 34 `#include` lines in 19 files | 7/10 | 3/12 | 8 | 0 | 3 properties + 1 enum value |
| (3.0.4→3.2.0, master line) | minor | 2436 | 2 | 2 | 12 | 38 | **76** | 10/16 | 5/22 | 15 | 1 | 4 + 1 |
| 3.2.0→3.2.2 | micro | 200 | 0 | 0 | 0 | 0 | **0** | 0/0 | 0/0 | 0 | 0 | 0 |
| 3.2.2→3.2.4 | micro | 258 | 0 | 0 | 1 | 0 | **1** | 0/0 | 3/3 | 0 | 0 | 0 |
| 3.2.4→3.2.6 | micro | 871 | 0 | 0 | 0 | 0 | **0** | 0/0 | 0/1 | 1 (field added) | 0 (1 signal added) | 0 |
| 3.2.6→3.2.8 | micro | 300 | 0 | 0 | 1 | 0 | **4** | 1/2 | 3/1 | 2 | 0 | 0 |
| 3.2.8→master | dev | 2076 | 0 | 1 | 6 | 0 | **26** + 1 GimpGui hook | 5/8 | 8/30 | 14 (8 made opaque) | 0 | 1 property + 2 enum values |

†All declared engine functions, whether or not the UI uses them. This is the upper bound if your front-end calls more than GIMP's own UI does.

Not one GObject type name was removed or renamed in any interval; the GimpVectors → GimpPath rename happened before 3.0.0.

### Example changes, with GIMP's own UI edits in the same commit (measured)

| Commit(s) | Ships in | Change | Class | Call sites | GIMP's UI edits in that commit |
|---|---|---|---|---|---|
| 568afe80 | 3.0.4 | new `gimp_image_undo_push_filter_modified`; filter undo now swaps GeglNode values | new call pattern | n/a | 1 file |
| fef770ab (3-0) / 6eae69d2 | 3.0.6 / 3.2.0 | `gimp_container_get_children_type`→`get_child_type`; property `"children-type"`→`"child-type"` | rename; the property part is silent | 40 | 13 files, +44/−44 |
| 0a12e667 → 923d19fc → ae696244 (3-0); 3038c751, 7262faed, c2195a24 | 3.0.6 / 3.2.0 | `gimp_viewable_get_{preview,new_preview,pixbuf,new_pixbuf}` gained a GeglColor, then two, then back to one; same for the GimpViewableClass vfuncs | mechanical + semantic (theme colours) | 17 | 11, 12 and 22 files (ae696244 +378/−467) |
| 170d676a / e9b2b1ad | 3.0.6 / 3.2.0 | signal `GimpContainer::reorder` gained a 3rd argument (`VOID__OBJECT_INT_INT`) | **silent**: old handlers get the wrong `user_data` | handlers | 7 files |
| c480a661 (backport of 2baab5aa) | 3.0.6 | `gimp_drawable_filter_{set,get}_temporary`; temporary filters kept out of undo and XCF | new call pattern + semantic | n/a | 8 files |
| 6129ad10, 57f21db5 | 3.0.6 / 3.2.0 | `G_DECLARE_DERIVABLE_TYPE` for GimpFilter, GimpItem, GimpViewable, GimpObject (structs made opaque) | invisible to callers | 0 | 0 |
| 69f84942 | 3.2.0 | `app/vectors`→`app/path`; build library `libappvectors`→`libapppath` | mechanical | 34 `#include` lines | 19 files |
| 66cdecb0, 28bf061f, 4f3aee5e | 3.2.0 | `file_open_image`, `file_open_layers`, `file_open_with_proc_and_display` gained booleans (link layers) | mechanical | 6 | up to 9 files |
| 789d8235 / e7842fea / b87bab9e / d88a3b93 | 3.2.0 | `gimp_layer_add_mask` +edit_mask; `gimp_image_merge_down` +`GimpItem**`; `gimp_curve_set_curve`→`set_sample`; enum GimpVectorExtendMode→GimpStrokeExtendMode | mechanical | 3 / 1 / 3 / 1 | 1–4 files |
| **d593cb32** | 3.2.0 | **GimpRasterizable** replaces `gimp_text_layer_discard`, `undo_push_text_layer_modified` and the `"modified"`/`"auto-rename"` properties | **semantic** | 2 + 3 property uses | 3 files |
| 08b7f978 | 3.2.4 | `gimp_pickable_contiguous_region_by_color` gained a `const GeglRectangle*` | mechanical | 1 | 1 file |
| a950e630 | 3.2.6 | new signal `"selected-drawables-changed"` | new call pattern | n/a | n/a |
| **67084b71** / 3ad1a129 | **3.2.8** (committed 2026-11-01, tag 2026-11-02) | `gimp_image_pick_color` gained `GeglBuffer**` (keeps the picked buffer during a press) | mechanical + semantic | 4 | 9 files, +45/−19 |
| 646ea512 | master | `scale_factor` added to the viewable preview API and vfuncs (HiDPI) | mechanical, but matters on Retina | 19 | 14 files |
| 496a3cc6 | master | `gimp_gegl_buffer_dup` gained `GimpDrawable*`; drawable buffers become file-backed | semantic | 5 | 4 files |
| ed668b3e | master | `gimp_progress_get_window_id`→`_handle`, plus the GimpGui hook and GimpProgressInterface vfunc | mechanical | 2 + 1 hook | 5 files |
| 2144ba94, 1285f05d, 93a6163c, 57185cf2 | master | `G_DECLARE_DERIVABLE_TYPE` wave: 8 UI-used structs made opaque | invisible to callers | 0 | 57185cf2 touched 51 UI files, but that is GIMP's own UI classes, not caller fixes |

## 3. Cost per update for an adapter (measured)
"Breaking commits" are commits that changed or removed a surface prototype. "Call sites" adds up the references for every such commit, so a function changed three times counts three times.

| Range | Commits | Touch engine headers | **Breaking commits** | Distinct functions | Call sites | Commits changing a UI-visible struct only |
|---|---|---|---|---|---|---|
| 3.0.0..3.0.2 | 54 | 0 | 0 | 0 | 0 | 0 |
| 3.0.2..3.0.4 | 280 | 6 | 1 | 1 | 2 | 0 |
| 3.0.4..3.0.6 | 817 | 41 | 5 | 6 | 99 | 7 |
| 3.0.6..3.0.8 | 468 | 6 | 0 | 0 | 0 | 1 |
| 3.0.4..3.2.0 (dev cycle, about 43 weeks) | 2436 | 127 | **20** | 25 | 142 | 17 |
| 3.2.0..3.2.2 | 200 | 2 | 0 | 0 | 0 | 0 |
| 3.2.2..3.2.4 | 258 | 9 | 1 | 1 | 1 | 0 |
| 3.2.4..3.2.6 | 871 | 13 | 0 | 0 | 0 | 1 |
| 3.2.6..3.2.8 | 300 | 6 | 1 | 1 | 4 | 2 |
| 3.2.4..master (about 28.5 weeks) | 2079 | 106 | **5** | 9 | 31 | 12 |

The bigger cost is fixes in GIMP's UI layer that never touch the engine. Tool and palette behaviour lives there, so a native front-end has to port those by hand:

| Interval | Engine-only commits (free on rebuild) | UI-only commits | Engine + UI in one commit | **Focused-UI commits with no engine change** |
|---|---|---|---|---|
| 3.0.0→3.0.2 | 0 | 7 | 1 | 2 |
| 3.0.2→3.0.4 | 19 | 36 | 3 | 10 |
| 3.0.4→3.0.6 | 69 | 138 | 29 | **39** |
| 3.0.6→3.0.8 | 55 | 19 | 6 | 5 |
| 3.0.8→3.2.0 | 292 | 283 | 92 | **101** |
| 3.2.0→3.2.2 | 24 | 7 | 1 | 0 |
| 3.2.2→3.2.4 | 41 | 21 | 9 | 9 |
| 3.2.4→3.2.6 | 58 | 114 | 9 | 25 |
| 3.2.6→3.2.8 | 31 | 63 | 4 | 14 |
| 3.2.8→master | 248 | 264 | 43 | 61 |

## 4. Public plug-in API, for comparison (measured from the `.def` files and headers)

| Interval | libgimp symbols | Removed | Signature changed | Added | libgimpui added | base / color / config / math added |
|---|---|---|---|---|---|---|
| 3.0.0→3.0.2 | 1064 | 0 | 0 | 0 | 0 | 0 |
| 3.0.2→3.0.4 | 1064 | 0 | 0 | 0 | 0 | 0 |
| 3.0.4→3.0.6 | 1065 | 0 | 0 | +1 (`gimp_trc_type_get_type`) | 0 | 0 |
| 3.0.6→3.0.8 | 1065 | 0 | 0 | 0 | 0 | +1 color, +2 config (`gimp_config_{get,set}_xcf_version`) |
| 3.0.8→3.2.0 | 1175 | 0 | 0 | +110 | +13 | +2 base |
| 3.2.2→3.2.4 | 1176 | 0 | 0 | +1 (`gimp_resources_loaded`) | 0 | +1 base (`gimp_env_exit`) |
| 3.2.0→3.2.2, 3.2.4→3.2.6, 3.2.6→3.2.8 | 1175–1176 | 0 | 0 | 0 | 0 | 0 |
| 3.2.8→master | 1188 | 0 | 0 | +12 | +1 | +8 base |

- Deprecation markers (`GIMP_DEPRECATED`) in the public headers went from 4 (3.0.0) to 26 (3.2.0), 28 (3.2.8) and 33 (master). Nothing was removed.
- **GIMP's published policy** ([developer.gimp.org/core/maintainer/versioning](https://developer.gimp.org/core/maintainer/versioning/), updated 2025-11-21):
  - "backwards-compatibility is promised within a major series."
  - "A plug-in created for GIMP 3.2.4 should continue working on any further release of GIMP 3."
  - "New features or functional changes should imply a minor version bump."
  - "Bugfix-only releases imply a micro version bump only."
  - The page covers only the libraries. It says nothing about `app/` internals, so I infer they have no stability promise.
- **What actually happens:** micro releases add public API ([3.2.4 notes](https://www.gimp.org/news/2026/04/19/gimp-3-2-4-released/) announce `gimp_resources_loaded()`), but never break it.

## 5. The pattern
- **Where churn lands (measured).** Most internal API churn comes in the minor/dev cycle: 20 breaking commits over 43 weeks before 3.2.0. Micro releases are not immune:
  - Master-cut micros (3.0.4, 3.2.4) carry whatever landed on master.
  - Branch micros carry backports. 3.0.6 is the outlier: 817 commits, including refactors, the renamed function and the reorder signal change.
  - 3.2.8 shipped a signature change committed the day before the tag.
- **Mechanical vs semantic.** On the released line 3.0.0 → 3.2.8 there were 18 function-level changes:
  - 15 (about 83%) were mechanical: renames, added booleans or nullable parameters, an enum type rename, a header move.
  - 3 were semantic: two removals from the GimpRasterizable change, and the `pick_color` buffer.
  - The semantic changes cluster where a classic editor needs them: text layers, layer previews and thumbnails, colour picking, filter undo.
- **Changes the compiler cannot catch** (1 signal-argument change, 4 property renames or removals), found by string-keyed lookups:
  - `reorder` signal arity (3.0.6)
  - `"children-type"` (3.0.6)
  - `"modified"`, `"auto-rename"`, curves `"linear"` (3.2.0)
  - `"help-browser"` (master)
- **Changes with no signature change** (found by sampling commit messages, not exhaustively):
  - temporary filters kept out of undo and XCF (3.0.6)
  - preview background redo (3.0.6)
  - file-backed drawable buffers (master)
  - XCF version bumps on master, e.g. eac03ffe → version 27

## Conclusion: what an in-process adapter would cost (estimates, inferred from the data above)

| Tracking mode | Compile and binding fixes | Silent and semantic risk | Parity work (porting UI-layer fixes) | Realistic cost |
|---|---|---|---|---|
| **Each stable micro** | median 0, mean about 8, worst 57 call sites (focused: worst 6) | 0–2 items per release (3.0.6: 1 signal + 1 property) | 0–39 focused-UI commits to review; typically 5–25 | a few hours to about 1 day for the bindings; 1–5 days if you want behaviour to match |
| **Each minor** | 11–16 functions, 19–76 call sites, a directory move, a build library rename, 3–4 properties | 1–2 model changes (GimpRasterizable) | about 100 focused-UI commits, many of them new features | 2–5 days to compile and run; 1–3 weeks for parity |
| **Master nightly** | about 1 breaking commit per 2 weeks during a dev cycle; about 1 per 6 weeks after a branch point | file-backed buffers, NDE filter changes, HiDPI `scale_factor`, XCF bumps | continuous | hours per week on average, with spikes; needs CI and a pinned fallback |

**Verdict:**
- **Achievable:** "trivially easy" is roughly achievable for the engine bindings if you track the `gimp-3-x` stable tags. Run the surface-diff scripts in CI before each rebuild. Add typed wrappers with runtime checks (`g_signal_query`, `g_object_class_find_property`) to catch the silent class.
- **Not achievable:** keeping tool behaviour current, because those fixes ship in GTK code you will have replaced.
- **Not recommended:** following master nightly.

## Caveats
- **What "surface" means:** it is the set GIMP's UI references, a stand-in for what your front-end would call. "References" counts every occurrence of the identifier, not only true calls. Macros, inline functions and enum type names are only partly captured; removed enum values are captured.
- **Struct and string matching:** struct field changes are taken from declaration text, and UI field access is matched by name only. Signal and property use is matched by string literal, so it overcounts.
- **Semantic changes:** these were sampled from commit messages, not found exhaustively.
- **Coupled-commit counts:** commits that touch both engine and UI include feature work, so they are an upper bound.
- **Dates and history:** dates are author dates unless stated (cherry-picks differ). History starts 2024-09-01, and every tag in scope is present.
