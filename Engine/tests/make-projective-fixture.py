# Run only by scripts/make-projective-fixture.sh in isolated gimp-console.
# Public libgimp filters are unclipped. An 8px sibling's offset shadow creates
# a 600008x8 raw group projection, while a white 8x8 group mask hides it.
import os
from gi.repository import Gegl, Gimp, Gio

image = Gimp.Image.new(8, 8, Gimp.ImageBaseType.RGB)
group = Gimp.GroupLayer.new(image, "Masked parent")
image.insert_layer(group, None, 0)
layers = []
for name, color in [("Moving", "#ffffff"), ("Offset effect", "#ff0000")]:
    layer = Gimp.Layer.new(image, name, 8, 8, Gimp.ImageType.RGBA_IMAGE,
                           100.0, Gimp.LayerMode.NORMAL)
    image.insert_layer(layer, group, len(layers))
    Gimp.context_set_foreground(Gegl.Color.new(color))
    layer.edit_fill(Gimp.FillType.FOREGROUND)
    layers.append(layer)
effect = Gimp.DrawableFilter.new(layers[1], "gegl:dropshadow", "Unclipped offset")
config = effect.get_config()
config.set_property("x", 600000.0)
config.set_property("y", 0.0)
config.set_property("radius", 0.0)
config.set_property("grow-radius", 0.0)
effect.update()
layers[1].append_filter(effect)
group.add_mask(group.create_mask(Gimp.AddMaskType.WHITE))
image.set_selected_layers([layers[0]])
assert group.get_width() == 8 and group.get_height() == 8
assert Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image,
                     Gio.File.new_for_path(os.path.join(os.environ["GLIMS_FIXTURE_DIR"],
                                                        "projective-parent-effect.xcf")), None)
