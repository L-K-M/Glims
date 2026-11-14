# Photoshop composite import (candidate)

File ▸ Open Photoshop Composite explicitly loads the merged appearance stored
in a PSD or PSB as a single flattened imported layer. This is useful when a
layered import cannot reproduce an effect such as the Gradient Fill currently
lost by development GIMP 3.3. The file's saved composite may be missing or
stale; individual layers, their editability and layer-specific settings are
not retained. The ordinary Open action remains available for layered import.

The importer checks the PSD/PSB signature and uses GIMP's distinct merged PSD
loader without modifying upstream sources. The result is an unsaved imported
document: Save asks for an XCF, and Revert uses the same composite loader until
the document is saved as XCF. Opening the same composite twice focuses the
existing composite document. The original is not a save destination. Duotone
color-mode data is retained when the loader provides it; Glims still does not
interpret inks or show a Duotone color preview. Older adapters disable the menu
item rather than substituting ordinary Open.

The Photoshop-authored Gradient Fill fixture is visibly opaque through this
route on development GIMP, and its full rendered 4×4 composite matches an
independent ImageIO decode within two 8-bit levels. Native checks run on all
four supported engines. Full editor, real-window, bundle and review
qualification remain in progress.
