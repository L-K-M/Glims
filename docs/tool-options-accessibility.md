# Tool Options accessible names

The existing Resample, Font, Align and Fill popups now expose their visible
setting names as accessibility labels. The selection segmented control exposes
Selection mode while retaining New, Add, Subtract and Intersect as its values.
Each existing row containing an NSControl associates that control with its
visible title through accessibilityTitleUIElement. This preserves existing
controls, targets, actions, ordering, fonts and tool state.

The tests-only baseline at 5ea2230 ran both tests and produced ten assertion
failures: missing labels and missing label relationships. Source dd7b34a passes
the same two tests with zero failures. The tests inspect actual AppKit controls
and their public accessibility properties without presenting a window; they do
not claim VoiceOver announcement quality or keyboard interaction acceptance.
Actual Full Keyboard Access/VoiceOver and the final combined app audit remain
separate gates. No native engine or Rigi code changed.

The complete private leased unit run passes 1,014 tests with zero failures
(`tool-options-ax-units.bG1G5j`); its owned test process exits0, final external
AX snapshot reports no dialog, and the desktop releases. Evidence is local
under `/tmp/glims-completion`; this does not replace the actual VoiceOver pass.
