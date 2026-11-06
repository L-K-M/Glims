# Builds the conformance fixtures with GIMP's own engine, through libgimp.
# Run by scripts/make-fixtures.sh inside gimp-console's Python-Fu batch
# interpreter; GLIMS_FIXTURE_DIR names the output directory.
#
#   composite.xcf  a layer group with a masked layer in multiply mode and a
#                  layer carrying a non-destructive Gaussian blur, a text
#                  layer, and a background
#   composite.png  GIMP's own composite of it: the visible layers merged in
#                  a duplicate, then exported (the reference renders are
#                  compared against)
#   text-units.xcf a 144 dpi image with a text layer sized in points: 24 pt
#                  type with 12 pt line spacing, which is 48 px and 24 px
import os

from gi.repository import Gegl, Gimp, Gio

out = os.environ["GLIMS_FIXTURE_DIR"]
width, height = 320, 240


def fill(drawable, hex_color):
    Gimp.context_set_foreground(Gegl.Color.new(hex_color))
    drawable.edit_fill(Gimp.FillType.FOREGROUND)


image = Gimp.Image.new(width, height, Gimp.ImageBaseType.RGB)

background = Gimp.Layer.new(image, "Background", width, height,
                            Gimp.ImageType.RGB_IMAGE, 100.0, Gimp.LayerMode.NORMAL)
image.insert_layer(background, None, 0)
fill(background, "#d8dee8")

group = Gimp.GroupLayer.new(image, "Shapes")
image.insert_layer(group, None, 0)

red = Gimp.Layer.new(image, "Red square", 160, 120,
                     Gimp.ImageType.RGBA_IMAGE, 80.0, Gimp.LayerMode.MULTIPLY)
image.insert_layer(red, group, 0)
red.set_offsets(40, 40)
fill(red, "#c03030")
mask = red.create_mask(Gimp.AddMaskType.WHITE)
red.add_mask(mask)
image.select_rectangle(Gimp.ChannelOps.REPLACE, 40, 40, 80, 60)
fill(mask, "#000000")
Gimp.Selection.none(image)

blue = Gimp.Layer.new(image, "Blue circle", width, height,
                      Gimp.ImageType.RGBA_IMAGE, 100.0, Gimp.LayerMode.NORMAL)
image.insert_layer(blue, group, 0)
blue.edit_clear()
image.select_ellipse(Gimp.ChannelOps.REPLACE, 150, 70, 120, 120)
fill(blue, "#3060c0")
Gimp.Selection.none(image)
blur = Gimp.DrawableFilter.new(blue, "gegl:gaussian-blur", "Soft edge")
config = blur.get_config()
config.set_property("std-dev-x", 4.0)
config.set_property("std-dev-y", 4.0)
blur.update()
blue.append_filter(blur)

text = Gimp.TextLayer.new(image, "Glims", Gimp.Font.get_by_name("Sans-serif"), 36.0, Gimp.Unit.pixel())
image.insert_layer(text, None, 0)
text.set_offsets(16, 180)

Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image,
               Gio.File.new_for_path(os.path.join(out, "composite.xcf")), None)

merged = image.duplicate()
merged.merge_visible_layers(Gimp.MergeType.CLIP_TO_IMAGE)
Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, merged,
               Gio.File.new_for_path(os.path.join(out, "composite.png")), None)

units = Gimp.Image.new(240, 120, Gimp.ImageBaseType.RGB)
units.set_resolution(144.0, 144.0)
paper = Gimp.Layer.new(units, "Background", 240, 120,
                       Gimp.ImageType.RGB_IMAGE, 100.0, Gimp.LayerMode.NORMAL)
units.insert_layer(paper, None, 0)
fill(paper, "#ffffff")
points = Gimp.TextLayer.new(units, "Glims\nText", Gimp.Font.get_by_name("Sans-serif"), 24.0, Gimp.Unit.point())
units.insert_layer(points, None, 0)
points.set_line_spacing(12.0)
Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, units,
               Gio.File.new_for_path(os.path.join(out, "text-units.xcf")), None)
