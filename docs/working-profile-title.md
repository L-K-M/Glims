# Visible working-profile state

Each document title includes the image's effective working-profile label
beside mode and precision. Assign, Convert, Undo and Redo update it through
the existing document-state cache. It is independent of the window's display
destination and soft-proof settings. An empty cached label displays
“Profile unavailable”. No extra native read or menu-validation call is added,
and progress/error messages keep their existing priority.

The actual-window regression first passed the existing 50 profile checks
and failed exactly five new title checks: built-in label, Assign, Undo,
Redo and independent second-document update. The corrected source passes
all 55 checks on 3.2.8, 3.2.0, 3.0.8 and master, with process exit zero and
desktop release after each. These temporary signed foreground hosts use
immutable external slot165 producers; they are not release bundle checks.
The pinned case's immediate external AX snapshot was incomplete. Its owned
process exited zero; the later three engine snapshots and final unit-run
snapshot show no dialog. The incomplete immediate observation remains a gap.

Three literal title-format tests pass, along with all 1,015 unit tests.
Latest-head hosted CI, completed review and final integration remain pending.
