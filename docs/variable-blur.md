# Variable Blur source mask

Variable Blur now uses the existing captured-source preview contract. Its
modeless source chooser names the blur-mask role; Preview captures the chosen
same-image drawable's pixels and committed effects before opening the native
property form. Radius, linear-mask and quality controls reflect the installed
GEGL properties. Apply to Pixels merges the result as one native Undo step.
Cancel preserves the target and its history. No live auxiliary graph is stored
as an XCF effect.

The facade's existing slot 147 admits only Bump Map and Variable Blur. Positive
explicit target/source IDs, image ownership, pixel-layer admission, locks,
Undo availability, floating-selection and indexed-image guards are retained.
Read-only source content is allowed. The detached snapshot has the existing
512 MiB bound; later source edits or deletion cannot change the preview.

The initial native regression reproduced 13 refusals before admission. The
corrected native implementation passes 149 focused checks per engine, including
three independent raw-GEGL pixel oracles, partial alpha, source lifetime,
Cancel, Apply, exact Undo/Redo, refusal cases and existing Bump Map behavior.
General conformance passes 1,917 checks on 3.2/master and 1,703 on 3.0.8.

The actual-menu regression reproduced the missing chooser before UI wiring.
All 24 UI checks pass on each of four engines: captured document routing while
another image is frontmost, explicit mask choice, parameter edits, native
pixel comparison, one Undo, Cancel/close and source-chooser replacement.
Choosing another source operation invalidates the old request; its retained
Preview action cannot start a stale filter. Repeating the same operation
reuses its chooser. Review, CI and combined release checks remain pending.

Native references are the unmodified engine source in each supported set:
GEGL `operations/common-cxx/variable-blur.c` exposes one external aux mask.
Its internal aux1 and subsequent graph pads are not additional user inputs.
Normal builds expose high-quality; levels/gamma controls exist only when
GEGL was built with MANUAL_CONTROL and are not invented by the frontend.
Other auxiliary operations remain outside this admission, including distinct
multiple-role inputs such as Displace and Oilify.
