# Selection-stroke target ownership

`gimp_image_get_selected_layers` returns the item tree's borrowed list on
all four supported engines. Resolving facade target 0 must borrow its first
item without freeing that container. The first default-target regression
crashed with status 139 before the stroke returned; the fixed adapter
preserves the selected-layer flags and closes the image safely.

All four native suites pass after the fix: 1,556 / 1,342 / 1,556 / 1,556
checks on 3.2.8 / 3.0.8 / 3.2.0 / master. This was unmerged code. Other
selection-list call sites were inspected: layer/channel/path lists are
borrowed, while `get_selected_drawables` allocates a caller-owned list.
The separate full-interface history failure has no established connection
to this default-target issue; the interface passes explicit drawable IDs.
