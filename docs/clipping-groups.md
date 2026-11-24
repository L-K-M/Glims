# Clipping groups

A clipping group is the classic "clip to the layer below" workflow: a
layer shows only where the layer directly under it has pixels, while its
own opacity and blend mode still apply. Layer > Group with Previous clips
the active layer to its base; Layer > Ungroup releases it; Layer > Merge
Group bakes a group into one layer named after its base.

## Model

A clipping group is a GIMP layer group in normal mode whose bottom child
is the base and whose other children carry
`GIMP_LAYER_COMPOSITE_CLIP_TO_BACKDROP`. This is the model GIMP's own PSD
loader builds (`plug-ins/file-psd/psd-load.c`, `add_clipping_group`), and
XCF and PSD both store it. The facade reports a group as a clipping group
only when its mode is normal, its bottom child is a non-group layer whose
raw composite mode is not CLIP_TO_BACKDROP, and at least one other child
has raw composite mode CLIP_TO_BACKDROP. The raw
`gimp_layer_get_composite_mode` decides, never the resolved mode, because
legacy blend modes are intrinsically clip-to-backdrop.

The group itself is created in normal mode, not pass-through. Inside a
normal group the children composite over transparency, so a clipped child
sees only the group's own content, the base. A pass-through group would let
it see the layers below the group too, which is not the classic clip.

The facade owns the representation. Slot 259 `image_layer_clipping` is one
read-only call that reports every layer in `image_layers` order (all
depths, top of the stack first, depth-first) with a role:

| Role | Meaning |
| --- | --- |
| `GLIMS_CLIPPING_NONE` | not part of a clipping group |
| `GLIMS_CLIPPING_BASE` | the group's bottom child |
| `GLIMS_CLIPPING_CLIPPED` | a child clipped to the base |
| `GLIMS_CLIPPING_GROUP` | the clipping group itself |

Each row also names the base and the group; both are 0 for NONE. `rows`
NULL with capacity 0 counts only.

## Rendering

The composite facts come from
`app/operations/layer-modes/gimpoperationlayermode-composite.c`: the
clip-to-backdrop composite writes `out[ALPHA] = in[ALPHA]` and blends the
layer's own result into the backdrop, so a clipped layer keeps the base's
alpha while its opacity and blend mode still apply. The group's own
opacity then scales the whole group, exactly as it scales an ordinary
group.

The engine conformance test pins these values against a white-based
fixture with an opaque left half and a transparent right half, and a fully
opaque red clipped layer:

- red shows only over the left half; the right half stays transparent;
- clipped-layer opacity 50% gives `(255, 188, 188, 255)` in sRGB, the
  linear-light blend GIMP performs;
- Difference over the white base gives `(0, 255, 255, 255)`;
- base opacity 50% scales the group's alpha to about 128 while the color
  stays red.

## Commands

Slot 260 `layer_clipping_edit` runs the three commands, each as ONE undo
step or a refusal that changes nothing.

**Group with Previous(L).** B is L's sibling directly below in the same
parent. If B is the base or a clipped child of a clipping group, L moves
into that group directly above B and becomes CLIP_TO_BACKDROP. If B is
itself a clipping group, L joins it above its top clipped layer, as the
classic command extends a clip from the layer above. Otherwise a
new normal-mode group named "Clipping Group" is created at B's position,
B moves to its bottom and L above it, and L becomes CLIP_TO_BACKDROP. L
and B keep their other properties, and the selection is preserved.

**Ungroup(L).** L is the base, a clipped child, or the group row itself
(which acts as Ungroup of the base). If L is the base, every clipped child
is released; if L is clipped, L and the clipped children above it are
released. Released layers move out of the group to directly above it in
its parent, in the same order, with composite mode AUTO. When no clipped
child remains, the base moves out to the group's position and the empty
group is removed.

**Merge Group(L).** L is the group, its base or a clipped child. The group
is merged with `gimp_image_merge_group_layer`, the result takes the base's
name and becomes selected, and the result id is returned. Group with
Previous returns the new group; Ungroup returns 0.

Every command validates all of its preconditions before the first
mutation, so a refusal changes nothing. The native steps after that can
fail only on broken engine invariants; the undo group still closes, so
Undo removes any partial change.

## Refusals

- An unknown command is INVALID_ARGUMENT.
- An unknown image or layer is NOT_FOUND.
- A Lab (layered Lab storage), CMYK or multichannel component document is
  UNSUPPORTED; an indexed image is UNSUPPORTED.
- A busy engine, a floating selection, disabled undo or an open undo group
  is BUSY.
- Group with Previous refuses when there is no sibling below, when L is a
  layer group, when B is a layer group other than a clipping group, when
  L or B is a genuine editable text, link or vector layer, when
  L is already clipped, or when L's blend mode cannot change composite
  mode. Position locks on L or B are LOCKED. Pixel locks do not refuse:
  no pixels change.
- Ungroup refuses a layer outside a clipping group.
- Merge Group refuses a layer outside a clipping group and any member
  locked against pixel or position changes.
- Ungroup's members that move refuse a position lock: the released
  layers, and the base and the group when the group dissolves. Layers that
  stay are not checked. A group is never removed while a layer it does not
  release is inside it.

## Layers palette

The real tree stays visible: the clipping group row is the ordinary group
row it is, and its children stay nested under it. A clipped row carries a
small `arrow.turn.down.right` marker before the name, with the
accessibility description "Clipped to the layer below". The base row's
name is underlined. The group row's details read "Clipping Group".

Option-clicking the bottom few points of a row toggles clipping between
that row and the sibling below it: Group with Previous when the upper row
is not clipped, Ungroup when it is. The two rows must be layer siblings;
effect rows and non-adjacent rows do nothing.

## Menus

Layer > Group with Previous (Command-G), Layer > Ungroup
(Shift-Command-G) and Layer > Merge Group sit beside Merge Down, and the
Layers palette's menu lists the same three. Menu validation reads only
cached state and shows the refusal reason as the tool tip, as Merge Down
does. `ImageDocument.clippingRefusal` adds the document gates (slot
support, ordinary layout, accepting edits, no pending target command, no
floating selection, one selected layer) around the pure structural rules
in `ClippingCommandRules`.

## Files

XCF stores the group structure and every layer's composite mode, so a
saved and reopened image keeps its roles; the engine test checks this.
PSD export and import use GIMP's own file plug-ins, which read and write
the same composite mode and group, so the model round-trips; the engine
test does not drive a PSD export, and that path is not covered here.

## Recorder

Recorder saves a `clipping` command at file format version 37 with an
owned `command` tag (`groupWithPrevious`, `ungroup` or `mergeGroup`) and
an explicit layer binding, like Matting. Merge Group also names its merged
layer as a produced symbol, so a later recorded row can bind it. A version
37 file must contain at least one successful clipping row; earlier
versions refuse the tag.
