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
