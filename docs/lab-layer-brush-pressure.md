# Layered Lab brush pressure

This private foundation provides a stroke-local, linear pressure-to-size
configuration for the four-plane Lab brush. It uses a new dynamics object,
not a mutable installed preset, and enables only the size output. It does not
expose pressure through the engine API or the application yet.

The native fixture exercises quarter and full pressure in both orders and
zero followed by full pressure. It compares the footprint across all four
planes and verifies cancellation restores plane bytes and Undo/Redo depth.
It also checks that the user context's dynamics object is not replaced. The
fixture passes 78 checks on each of GIMP 3.0.8, 3.2.0, 3.2.8 and master.
The runs use synthetic coordinates, not a physical tablet; interpolation,
public API compatibility, actual input delivery and the UI still need their
own acceptance checks before this is a user-facing capability.

The pressure API candidate appends a separate optional engine entry for the
same captured target and V2 sample contract. The original entry keeps its
fixed-size behavior even at zero pressure; storage flags remain unchanged so
older clients do not reject the image. The pinned-engine public fixture
checks unaligned and invalid requests, stale identity, busy admission, a
zero-pressure start followed by a full-pressure continuation, cancellation,
commit and grouped Undo/Redo. Other engine runs and review remain pending.

The application candidate enables “Pen pressure sets size” for layered Lab
when the engine exposes the optional pressure entry. A disabled setting uses
the original fixed-size entry. Older engines keep the pressure checkbox
disabled and use the fixed-size entry even if a saved brush preset enables
pressure. Flat Lab remains fixed-size. A real-window fixture checks the
checkbox and synthetic pressure samples; physical tablet delivery remains to
be qualified.
