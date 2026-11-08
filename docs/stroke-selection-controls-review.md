# Stroke Selection acceptance checks

The form now keeps the complete captured brush and changes only its
exposed tool, size, opacity and color fields. A new pure regression
reproduced loss of pressure sizing, hardness, rate, flow, exposure, tones,
anti-erase and source settings; all ten form tests pass after the fix.

The input-order regression now holds the document's input queue, rather
than acquiring the global busy gate before submitting input. It accepts a
fill followed by an active stroke, then requires Stroke Selection to queue
the stroke end before its own operation. Removing the end-input lines
reproduces native BUSY refusals and missing/wrong undo steps. The fixed
method passes the focused pinned-engine run.

Opening/cancelling compares against the fixture's configured brush, and
the outside pixel oracle lies outside the brush footprint. A disabled
Stroke action now displays its current cached refusal reason. The entire
Stroke/Cancel buttons and color control are asserted visible. All 57
focused pinned checks pass; the final four-engine and integrated runs are
still pending this checkpoint.
