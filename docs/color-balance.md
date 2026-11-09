# Native Color Balance

The exact native Color Balance operation has a modeless editor with three
percentage pairs, Shadows/Midtones/Highlights views and Preserve Lightness.
The range popup changes the view only; every write carries all nine
corrections and the preserve flag. Apply commits the final field edit,
Cancel restores the original, and existing effects reopen with their full
settings. Controls remain attached to the captured document and preview.

API v1 appends slots150/151 with sized owned settings. Every correction is
finite and in[-1,1]; the native preserve field accepts only0/1. Invalid
settings fail before mutation. Changed values privately duplicate the
complete native config, preserve its view cursor and inherited properties,
and replace it once. Defaults are installed before first native Apply.
Begin/Edit/Commit use the same readiness and native Undo guards as
Brightness/Contrast. Config ownership uses real Core declarations and
ordinary references; the documented native Undo/XCF extra-reference issue
remains upstream and is not compensated with extra unrefs.

The operation uses nonlinear sRGB float channels, with tonal masks based on
the original HSL lightness. Tests use independent arithmetic and literal
patch oracles, including alpha, clipping, preserve ON/OFF, transitions and
sequential range changes. The dedicated harness passes250 checks on each supported engine and covers immutable
settings, sized public marshalling, refusal paths, lifetime before native
Undo, new/existing Apply/Cancel/Undo/Redo and XCF configuration persistence.

A controlled UI test first reproduced a hidden rejected correction being
resubmitted after an older acknowledgement. A second ordering reproduced
the same problem before that acknowledgement arrived. The editor now
removes a refused write immediately as the base for future edits, retaining
older pending intent and respecting newer already-admitted writes. Both
regressions and the real controls pass21 checks on every supported engine.

## Known native XCF limitation

The expanded fixture deliberately assigns nondefault native-only blend and
composite settings to an existing effect. All four upstream XCF loaders
read their stored values and then explicitly replace them with AUTO. The
original strict comparisons failed twice per engine and are retained in
the runtime evidence. GlimsEffectChange does not expose these settings.
Live edit/Undo tests keep strict comparisons; the XCF check explicitly
expects native AUTO normalization while requiring all nine Color Balance
values, preserve flag, inherited base fields, opacity, order, enabled state
and pixels to survive. Full native blend/composite file preservation is
separate remaining work, not implied by these passing config checks.

After Image Adjust integration, all923 unit tests pass. On every engine the
shared Brightness/Contrast15, Bump Map20 and Image Adjust27 real-window
checks also pass. Final bundle checks, CI and merge remain release gates.


Shared field-draft preservation now retains actual field-editor text and
selection during delayed native-error presentation, including valid text
that has not sent its action. The expanded21-check editor suite passes on
every supported engine; its native250-check matrix remains unchanged.
