# Physical Lab Curves controls

Image > Adjust > Curves opens the sampled-curve panel for the selected Lab axis.
Lightness uses physical values from 0 to 100; a* and b* use -128 to 127. The
Freehand sample index remains 0–255, while its output and the Smooth point X/Y
fields show physical values. The graph and native transport retain normalized
double samples. Merely visiting a rounded numeric field does not rewrite them.

The panel shares its graph, draft validation and interaction handling with ink
Curves. Typed initializers keep physical Lab and ink settings separate. Existing
ink numeric formatting and controls remain covered by the original tests.
Malformed drafts block Apply even when an older valid preview is visible.

The window captures the selected axis before showing the panel. Preview jobs
read the immutable native baseline, return independently owned copies, render
through the normal display transform and close those copies asynchronously.
Cancel and document close invalidate pending replies and wait for native
snapshot cleanup. A successful Apply creates one Undo step; the native
transaction verifies the source and captured target again before publication.

Recorder currently stores an explicit unsupported-step result for Lab Curves,
as for the existing physical Lab Fill route. It does not silently record an ink
operation or claim that the Lab step can be replayed. Lab action recording is
subsequent work.

Local verification: all 1,682 Swift tests pass. The pinned-engine GUI fixture
passes 251 checks covering all three axes at U8/U16/float precision, actual
Freehand graph input, an independent physical Fill display oracle, invalid
live numeric drafts, Apply/Cancel, exact rendered Undo/Redo, and cancellation
or close during pending begin/render. Captured panels show their controls
within bounds. The full four-engine Lab/ink UI matrix and independent reviews
are tracked in the PR. Standalone release qualification remains separate.
