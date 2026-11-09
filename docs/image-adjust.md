# Image adjustment menu

Image > Adjust exposes the loaded native Threshold, Invert Perceptual and
Invert Linear controls. They use the existing modeless preview lifecycle:
Cancel restores the input, Apply adds one native Undo step, and committed
effects survive XCF reopening. The existing Filter > Color entries remain.

Native and plug-in entries share the static Adjust submenu. Refreshing
either catalog removes only its own generated content, including nested
plug-in categories, while preserving unrelated commands and submenu identity.
Unavailable operations are omitted from Adjust without lifting config or
auxiliary-input gates elsewhere.

Six new menu tests reproduced four refresh defects in the initial draft.
The corrected source passes 915 unit tests and 27 actual-window checks on
each supported engine. The latter independently check threshold samples,
sRGB encoded inversion, linear-light inversion and unchanged alpha, plus
captured-document preview, Cancel, one Undo/Redo and XCF pixels. Independent
source review found no important issue. A first nested plug-in category may
lack a dividing separator until native refresh; this cosmetic detail is
deferred. Other custom adjustment forms and final integrated release checks
remain separate work.
