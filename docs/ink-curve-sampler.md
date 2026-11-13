# Smooth ink curve sampling

The private Swift sampler converts ordered smooth/corner points to 256 native
ink-intensity samples. It follows the unmodified GIMP `gimpcurve.c`
calculation at `7addd2b77efb798bbdc4d2fb082e786a48478ced`, including rounded
sample positions, coincident-point order, corner tangents, endpoint extension
and clamped cubic segments. Zero points preserve the previous table; one
point makes it constant. Inputs require finite unit coordinates and samples,
nondecreasing x, at most 256 points and exactly 256 previous samples.

The ordinary two smooth identity endpoints return exact `Double(i)/255`,
preserving the scalar ink kernel's identity behavior for extended floats.
This intentional canonical representation differs only in floating rounding
from native spline evaluation. Other sampled values match within `2e-14`.

The independent C oracle constructs real upstream GimpCurve objects without
calling the Swift implementation. All four supported engines produce the
same 21 tables (5,376 sample values each), including zero/one point, smooth and
corner tangents, overlapping rounded endpoint bins, duplicate x, epsilon and
half-bin boundaries, clamping and endpoint gaps. The committed Swift fixture
compares every sample. All 1,633 Swift tests pass on this branch.

Four initial helper test expectations used incorrect rounded-bin arithmetic.
The red run is retained; exact rational values and two added native oracle
cases corrected those assertions without changing production calculation.
Independent source/oracle review found no important implementation issue;
the review initially covered 19 tables, with the two boundary cases added by
the parent afterward. Latest-head CI remains pending.

Build/run the oracle with `scripts/test-ink-curve-sampler.py build` and `run`,
selecting an existing producer via `--producer` and a fresh `--work` directory.
`run` writes `oracles.json` in `--work` and, after a successful native run,
compares it to `Engine/tests/fixtures/ink-curve-sampler.json` with a `2e-14`
tolerance (exact case count/order/names, 256 finite non-bool samples per case).
Explicit comparison is available via
`scripts/test-ink-curve-sampler.py compare <oracles.json>`.
Engine runs use isolated homes. Native oracle build/run was not executed in
this environment for this change.

This calculation alone does not expose Smooth in the ink panel, add a Recorder
command, or establish Photoshop spline equivalence. Those are separate gates.
