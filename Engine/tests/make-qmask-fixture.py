# Builds the Quick Mask name fixture with GIMP's own engine, through
# libgimp. Run inside gimp-console's Python-Fu batch interpreter with
# GLIMS_FIXTURE_DIR naming the output directory, exactly as
# scripts/make-fixtures.sh runs make-fixtures.py:
#
#   qmask-name.xcf  an image whose channel list holds a channel named
#                   "Qmask" — the name the Quick Mask's channel reserves
#                   (gimpimage-quick-mask.h GIMP_IMAGE_QUICK_MASK_NAME).
#
# GIMP finds the Quick Mask's channel by that name, not by identity: any
# channel added to or renamed to "Qmask" turns the mask on and becomes it
# (core/gimpimage.c gimp_image_channel_add and _channel_name_changed).
# The file is written while the mask is on, like a file saved mid-edit or
# by an older GIMP; XCF stores the channel like any other and no mask
# state, so reopening adopts the channel as the live mask again.
#
# There is no Quick Mask procedure in 3.0's PDB, so the script drives the
# rename itself: with the left rectangle selected, renaming a channel to
# "Qmask" makes the engine duplicate the current selection as the real
# mask channel and uniquify the renamed one to "Qmask #1". The renamed
# channel is then restored to its own name.
import os

from gi.repository import Gimp, Gio

out = os.environ["GLIMS_FIXTURE_DIR"]

image = Gimp.Image.new(48, 36, Gimp.ImageBaseType.RGB)

background = Gimp.Layer.new(image, "Background", 48, 36,
                            Gimp.ImageType.RGB_IMAGE, 100.0, Gimp.LayerMode.NORMAL)
image.insert_layer(background, None, 0)

# Two ordinary saved channels: the left rectangle, then the right one.
image.select_rectangle(Gimp.ChannelOps.REPLACE, 10, 8, 20, 16)
saved = Gimp.Selection.save(image)
saved.set_name("Saved")

image.select_rectangle(Gimp.ChannelOps.REPLACE, 30, 12, 12, 14)
other = Gimp.Selection.save(image)
other.set_name("Other")

# Re-select the left rectangle, then rename "Saved" to the reserved name:
# mid-rename the engine creates the real mask named "Qmask" carrying this
# selection and turns the Quick Mask on; the renamed channel is left as
# "Qmask #1" and takes its own name back on the next line.
image.select_rectangle(Gimp.ChannelOps.REPLACE, 10, 8, 20, 16)
saved.set_name("Qmask")
saved.set_name("Saved")

assert sorted((c.get_name() for c in image.get_channels())) == \
    sorted(("Qmask", "Saved", "Other")), \
    [(c.get_id(), c.get_name()) for c in image.get_channels()]

Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image,
               Gio.File.new_for_path(os.path.join(out, "qmask-name.xcf")), None)
