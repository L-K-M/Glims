# Numeric tool colors

Click the Tools palette's foreground or background swatch to open its owned
color editor. Each RGB row shows Percent (0–100) and Float (0–1) at full
precision. The color well opens the native visual picker. Tool colors remain
opaque sRGB; painting opacity is a separate tool setting.

Numeric drafts accept finite values in range, using a period as the decimal
separator. Invalid drafts leave the color unchanged and stay available for
correction. Escape reverts the current entry; Revert Entries discards pending
entries without changing the last accepted color. Invalid entries must be
corrected or reverted before closing or switching the edited target.

A different foreground/background swatch settles valid old drafts on the old
target before opening a fresh session. Each session owns new controls and a
new well, with identity checks on actions and observers. Detached field/well
callbacks cannot change a later target. Numeric edits and external sampling,
Swap and Reset update the well and readouts without feedback; focused drafts
are retained. Merely focusing an old readout cannot overwrite a newer sample.
Unsupported color-well inputs refuse before RGB component access, restore the
accepted color and show an actionable message. No fallback color is substituted.

This editor does not change image pixels, precision, profiles or Undo. It
edits the existing global tool foreground/background choices. Other document
color forms keep their native wells. Native image sampling is a separate
[change](float-color-sampling.md).

## Verification

All 1,242 unit tests pass on the candidate, including exact fractional and
unchanged-percent round trips, finite/range refusal, opaque target identity,
actual controller draft switching, late old-field/well actions, close/reopen,
active-well synchronization and unsupported pattern-color refusal/recovery.
Two independent SWE-2 source reviews found no important issue after the
initial helper's lifecycle and compile defects were repaired. The current
known-solid ToolState producers remain the initialization invariant; arbitrary
injected NSColor subclasses are not a public input API.

Latest-head CI, final integrated packaging and final on-screen palette
interaction/appearance checks remain pending at this checkpoint. The unit
checks do not establish spoken VoiceOver behavior or physical display accuracy.
