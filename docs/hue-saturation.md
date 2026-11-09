# Native Hue/Saturation

The dedicated editor keeps Master and six named hue ranges together with
global overlap. Hue uses degrees; saturation, lightness and overlap use
percentages. Changing the view preserves every other range. Fields and
sliders send complete normalized settings for the captured preview. The
Image Adjust command and existing-effect editing use the same form.

API v1 appends152/153 with21 owned corrections and overlap. Each correction
is finite in[-1,1], overlap in[0,1], all default zero. Reads never change
the native range cursor. Changed writes duplicate the complete native
config privately, preserve its cursor/base fields and replace it once.
Begin/Edit/Commit preserve existing readiness and history guards. The
exact native point-filter declarations are used; no upstream patches,
private layout mirrors, libgimp linkage or compensating unrefs are used.
The documented upstream Undo/XCF config-reference limitation remains.

Native processing uses fixed-sRGB HSL. Master and local values add; overlap
mixes neighbor saturation after each neighbor clamp. Neutral pixels use
Master lightness only. Individual valid Master/local lightness values can
sum outside the nominal HSL range; no invented extra clamp is imposed.

The dedicated native harness passes387 checks per engine, with23 independent
literal oracles including raw HSLA lightness1.3. It covers all22 values,
no-op/invalid/cursor/tail/lifetime cases, new/existing Undo/XCF and readiness
guards. The editor passes21 real-window checks per engine, including
actual Image Adjust routing, seven ranges, overlap, captured documents,
last-field Apply, Cancel, Undo/Redo, XCF and active unsubmitted field text.
Shared field-draft preservation retains text and selection through delayed
replies. All948 unit tests pass after the merged capture-date integration. Native
and Swift source reviews have no important findings.

These are targeted results, not final bundle/CI/merge acceptance. The
separate native XCF wrapper blend/composite AUTO normalization remains
recorded in the completion ledger; it is not loss of the22 typed settings.
