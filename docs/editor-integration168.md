# Editor integration 168

This candidate combines the reviewed Spring tool keys, live hints, Tool/color
menus, owned document screen modes, tablet eraser proximity, native layer
picking, captured Recorder layer properties and floating Text creation.
It remains part of the unfinished full-editor implementation.

## Source composition

The base is Main40ba9ea, including the merged tablet eraser change. The
candidate includes Spring35fa405 (production72c82fd and actual fixturea367090),
Hintsfcfaa58, Tool menusda686b9, Screen4f7537c, native picking0cb4ddf,
Recorderfc25f06 and Text35c752f. Their individual reports retain original
failures, corrections and verification limits.

The manual resolutions preserve both tool-state owners and mouse-up callbacks.
EngineCanvasView has one first-responder resignation override with one super
call, followed by both Spring cancellation and hint modifier reset. Window
close retains batch Restore alert cleanup, Spring cleanup and screen-mode
restoration. Text promotes held ownership before its editor takes focus.
All focused smoke dispatches and real-host allowlist entries are retained.

The first combined build caught a hint/tablet type mismatch: idle hints have
modifier flags, whereas hardware eraser selection requires a real device
pointer event. Commit4ce4065 uses the existing keyboard policy for idle hints;
an accepted drag retains its captured tool, including a hardware eraser.
The next combined build passes. This compile correction does not claim an
observed behavioral failure. Independent merge-resolution review is running.

Production C/private/public headers are byte-identical to Text35c752f. The
newer independently reviewed native picking harness from0cb4ddf is retained.
The combined app uses Rigi13ec06a, whose tree matches the reviewed merged
Rigi#20 result. No upstream engine source changes are made.

## Verification status

Combined runtime verification is in progress using a frozen signed host at
4ce4065 and immutable external Native168 adapters. Separate feature runs
are not relabelled as combined evidence. Exact source/binary/adapter hashes
are recorded in /tmp/glims-completion/integration168-4ce4065-host/source.json.

Current CI and completed publication feedback, combined engine checks,
self-contained bundle checks, physical input, complete accessibility and
public distribution gates remain separate work. Recorder file persistence,
Move pick gestures, Displace sources and richer tablet input are not included
in this candidate.
