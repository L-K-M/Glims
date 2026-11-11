# Floating selections and tool changes

The earlier design table generalized anchoring too broadly. Choosing a tool
is distinct from the pointer operation subsequently performed with it. An
idle floating selection must remain available to Move and paint tools.

The checked source is GIMP 3.2.8, commit
`7addd2b77efb798bbdc4dbf2b082e786a48478ced`. Relevant 3.0.8 paths agree on
these rules. These are source observations, not a new native runtime claim.

| Interaction | Native behavior and primary source |
| --- | --- |
| Permanent tool choice | Commits the old tool operation, then halts/resets/selects tools. No generic floating-selection anchor occurs. `app/tools/tool_manager.c`, active-tool deactivation and tool-change handlers. |
| Choose Move or paint with an idle float | Keeps the float available. Merely selecting the tool does not execute its pointer press/release logic. |
| Move pick mode hits the float | Uses edit-selection translation and preserves it. `app/tools/gimpmovetool.c:251` and `gimpeditselectiontool.c:408`. |
| Move pick mode hits another layer | Records the float to anchor on non-cancel release. Cancellation does not anchor. `gimpmovetool.c:251–262,440–444`. |
| Selection-tool anchor click | Concrete rectangle/polygon/region gesture handlers anchor; tool choice alone does not. `gimpselectiontool.c:289–325`, `gimprectangleselecttool.c:684–711`, `gimppolygonselecttool.c:236–260`, `gimpregionselecttool.c:162–199`. |
| Create a text layer | Anchors explicitly within text creation's native undo group. `gimptexttool.c:1655–1680`. |
| Direct Core layer/channel target replacement | Refused while floating unless selecting the float itself. The setters do not anchor automatically. `app/core/gimpimage.c:5094–5100,5164–5166`. |
| Space with default PAN setting | Scrolls the display and preserves an idle float. `app/config/gimpdisplayconfig.c:322–328`, `app/display/gimpdisplayshell-tool-events.c:2075–2093,2135–2137`. |

Temporary tool push/pop preserves the parent tool rather than resetting it
(`tool_manager.c:237–282,682–699`). GIMP's configurable Space MOVE instead
changes/restores the context tool and may commit a pending old operation.
Neither mechanism establishes blanket anchoring of an idle float.

On native macOS Quartz, Command supplies the GDK modify-selection modifier.
Paint tools use the constrain-only modifier for temporary color picking
(`gimppainttool.c:471–488`). Glims' Command-Move is its own input mapping;
it must not be presented as an identical native universal tool switch.

Glims provides explicit Anchor, New Layer and Discard and preserves a float
across tool choices. Move defaults to Current Layer. Choose Pick Layer or
Guide from Tool Options or View > Move Target to use the layer under the
pointer. A guide takes priority. An opaque hit on the floating selection
moves it. A press on another layer anchors the float on release.
A miss leaves it alone. A stationary picked click only selects its hit;
guide or grid snapping cannot reposition the layer without pointer motion.
A real drag still snaps and records one native movement Undo. Escape cancels. If Pick temporarily selected another
layer, cancellation restores the prior target when the engine is free, unless
a newer choice already took ownership. Holding Command keeps Current Layer
behavior; Space still pans.

Move passes 1,712 focused checks across four engines and 1,115
unit tests. The busy-cancellation fixture reproduced the missed restore
before the fix and passes afterward.

Rectangle, ellipse and Lasso keep the floating selection's identity from
press through release. An eligible stationary click outside its opaque
pixels anchors. An opaque press can move the float without anchoring. A
shape or polygon drag still uses the selection path. Lasso distinguishes
a short or long stationary press from motion that returns to the start.

Wand and Select by Color use an unmodified miss to anchor on noncancelled
release, even if the pointer has since moved. An opaque press uses Move.
Shift or Option instead captures the point and selection options at press
and selects on release, with the fresh empty-mask guard for Subtract and
Intersect. Without a float, both tools still select at press. Escape,
closing or replacing the captured float cannot apply its pending edit.

On each of the four supported engines, the focused app runs pass 62
rectangle and ellipse, 39 Lasso, and 42 Wand and Select by Color checks.
The separate Text creation route anchors only within its grouped native
edit. None of these gestures changes the rule for merely choosing a tool.

No upstream source is modified or GUI library linked by this policy note.


The combined selection and stationary-pick source at `ed40a43` passes
924 focused checks in20 actual app processes across all four engines, plus
1,115 unit tests. A separate16-check fixture first reproduced the
stationary-click mutation with snapping enabled; its unchanged assertions
then pass, including an independent literal guide-drag pixel/Undo oracle.
Current Main integration retains the original selection assertions.
Independent combined source review found no important ownership, queue,
cancellation or shared-preview defect. Final combined release checks remain
separate.
