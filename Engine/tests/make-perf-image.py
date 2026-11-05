# Builds the performance-pass image with GIMP's own engine: 6000 x 4000
# (24 MP), a background and 19 layers in ten blend modes at varied opacity,
# each with filled rectangles and ellipses. Run by build-adapter.sh --perf in
# gimp-console's Python-Fu batch interpreter; GLIMS_PERF_IMAGE names the file.
import os
import random

from gi.repository import Gegl, Gimp, Gio

out = os.environ["GLIMS_PERF_IMAGE"]
width, height = 6000, 4000
rng = random.Random(20261105)
modes = [Gimp.LayerMode.NORMAL, Gimp.LayerMode.MULTIPLY, Gimp.LayerMode.SCREEN,
         Gimp.LayerMode.OVERLAY, Gimp.LayerMode.SOFTLIGHT, Gimp.LayerMode.ADDITION,
         Gimp.LayerMode.DARKEN_ONLY, Gimp.LayerMode.LIGHTEN_ONLY,
         Gimp.LayerMode.HARDLIGHT, Gimp.LayerMode.DIFFERENCE]


def fill(drawable):
    color = Gegl.Color.new("#%02x%02x%02x" % (rng.randrange(256), rng.randrange(256), rng.randrange(256)))
    Gimp.context_set_foreground(color)
    drawable.edit_fill(Gimp.FillType.FOREGROUND)


image = Gimp.Image.new(width, height, Gimp.ImageBaseType.RGB)
background = Gimp.Layer.new(image, "Background", width, height,
                            Gimp.ImageType.RGB_IMAGE, 100.0, Gimp.LayerMode.NORMAL)
image.insert_layer(background, None, 0)
fill(background)

for index in range(19):
    layer = Gimp.Layer.new(image, "Layer %d" % (index + 1), width, height,
                           Gimp.ImageType.RGBA_IMAGE, rng.uniform(40.0, 100.0), modes[index % len(modes)])
    image.insert_layer(layer, None, 0)
    layer.edit_clear()
    for shape in range(12):
        w, h = rng.randrange(400, 2400), rng.randrange(300, 1800)
        x, y = rng.randrange(0, width - w), rng.randrange(0, height - h)
        if shape % 2:
            image.select_ellipse(Gimp.ChannelOps.REPLACE, x, y, w, h)
        else:
            image.select_rectangle(Gimp.ChannelOps.REPLACE, x, y, w, h)
        fill(layer)
    Gimp.Selection.none(image)

Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, image, Gio.File.new_for_path(out), None)
