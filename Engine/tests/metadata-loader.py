#!/usr/bin/env python3
# Throwaway conformance fixture plug-in for the metadata-preservation tests
# (see docs/metadata-preservation-fixtures.md). engine-tests.c installs this
# file under the test user's plug-ins/<dir>/ before the engine starts, so it
# is discovered by the plug-in scan at engine start, exactly like the
# glims-slow-load fixture.
#
# It registers two procedures:
#
#   file-glims-gmeta-load     a loader for the made-up ".gmeta" extension.
#                             It creates a small image and layer, then seeds
#                             the image's ORIGINAL metadata by invoking the
#                             Core PDB procedure gimp-image-set-metadata with a
#                             RAW metadata-string XML (app/pdb/image-cmds.c,
#                             image_set_metadata_invoker ->
#                             gimp_metadata_deserialize ->
#                             gimp_image_set_metadata). It deliberately never
#                             uses Gimp.Image.set_metadata() or
#                             Gimp.Metadata.serialize(): those serialize the
#                             metadata, and the serializer caps
#                             Xmp.photoshop.DocumentAncestors at 1000 values
#                             (libgimpbase/gimpmetadata.c, gimp_metadata_serialize).
#
#   plug-in-glims-meta-oracle an image procedure that dumps the image's
#                             metadata through the Core PDB procedure
#                             gimp-image-get-metadata (serialized XML, in
#                             which XMP LangAlt qualifiers appear as
#                             lang="..." prefixes per exiv2's LangAltValue)
#                             into <GLIMS_GMETA_DIR>/gmeta-oracle.xml, where
#                             the C test reads it. Never run it on the
#                             ancestors fixture: the serialize path caps
#                             DocumentAncestors, the facade value read does not.
#
# The mode file <GLIMS_GMETA_DIR>/gmeta-mode selects the fixture the loader
# seeds: "qualified" (LangAlt with distinct xml:lang keys plus XmpBag/XmpSeq
# plus EXIF/IPTC) or "ancestors" (exactly 1001 DocumentAncestors values).

import gi
gi.require_version('Gimp', '3.0')
from gi.repository import Gimp
gi.require_version('Gegl', '0.4')
from gi.repository import Gegl
from gi.repository import GObject
from gi.repository import GLib
import os
import sys
from xml.sax.saxutils import escape, quoteattr

ANCESTOR_COUNT = 1001  # the core parser keeps at most 1001 (drops past 1000+1)


def _work_dir():
    return os.environ.get('GLIMS_GMETA_DIR')


def _fail(procedure, message):
    return procedure.new_return_values(Gimp.PDBStatusType.EXECUTION_ERROR,
                                       GLib.Error(message))


def _xml_text(value):
    # GMarkup character data: & < > must be escaped; quotes are legal raw
    # in text content (the core serializer escapes them too, the parser
    # resolves both forms identically).
    return escape(value)


def build_metadata_xml(mode):
    """Builds the raw metadata-string XML for gimp-image-set-metadata.

    Shape (libgimpbase/gimpmetadata.c, gimp_metadata_serialize /
    gimp_metadata_deserialize): a <metadata> root, <namespace> elements
    registering XMP namespace prefixes, and one <tag name="...">value</tag>
    per value. Repeated <tag> elements of one name accumulate through
    gexiv2_metadata_try_set_tag_multiple. For a LangAlt tag (exiv2
    LangAltValue::read) a value of the form lang="fr-FR" text stores the
    alternative under xml:lang="fr-FR"; for Bag/Seq tags each value becomes
    one array item. DocumentAncestors is registered as xmpBag, so 1001
    <tag> elements seed exactly 1001 values (the parser drops values only
    once the tag already holds more than 1000).
    """
    lines = ["<?xml version='1.0' encoding='UTF-8'?>", '<metadata>']
    lines.append('  <namespace prefix="dc" url="http://purl.org/dc/elements/1.1/"></namespace>')
    lines.append('  <namespace prefix="photoshop" url="http://ns.adobe.com/photoshop/1.0/"></namespace>')

    def tag(name, value):
        lines.append('  <tag name=%s>%s</tag>' % (quoteattr(name), _xml_text(value)))

    if mode == 'qualified':
        tag('Exif.Image.Artist', 'Original Artist')
        tag('Iptc.Application2.Keywords', 'iptc-one')
        tag('Iptc.Application2.Keywords', 'iptc-two')
        tag('Xmp.xmp.CreatorTool', 'Glims fixture')
        # LangAlt (dc:title is registered "Lang Alt"): two alternatives with
        # DISTINCT language keys and distinct texts, one with XML-special
        # characters to prove escaping.
        tag('Xmp.dc.title', 'lang="x-default" Default title & <demo>')
        tag('Xmp.dc.title', 'lang="fr-FR" Titre français — café')
        # XmpBag (dc:subject is registered "bag Text") ...
        tag('Xmp.dc.subject', 'alpha')
        tag('Xmp.dc.subject', 'beta')
        tag('Xmp.dc.subject', 'gamma')
        # ... and XmpSeq (dc:creator is registered "seq ProperName").
        tag('Xmp.dc.creator', 'creator-one')
        tag('Xmp.dc.creator', 'creator-two')
    elif mode == 'ancestors':
        tag('Exif.Image.Artist', 'Ancestor Artist')
        tag('Iptc.Application2.Keywords', 'ancestor-keyword')
        for i in range(ANCESTOR_COUNT):
            tag('Xmp.photoshop.DocumentAncestors', 'ancestor-%04d' % i)
    else:
        raise ValueError('unknown .gmeta mode: %r' % mode)

    lines.append('</metadata>')
    return '\n'.join(lines) + '\n'


def load_gmeta(procedure, run_mode, file, metadata, flags, config, data):
    work = _work_dir()
    if not work:
        return _fail(procedure, 'GLIMS_GMETA_DIR is not set')
    try:
        with open(os.path.join(work, 'gmeta-mode'), 'r', encoding='utf-8') as f:
            mode = f.read().strip()
    except OSError as e:
        return _fail(procedure, 'cannot read the .gmeta mode file: %s' % e)
    try:
        xml = build_metadata_xml(mode)
    except ValueError as e:
        return _fail(procedure, str(e))

    image = Gimp.Image.new(64, 48, Gimp.ImageBaseType.RGB)
    layer = Gimp.Layer.new(image, 'gmeta', 64, 48, Gimp.ImageType.RGBA_IMAGE,
                           100.0, Gimp.LayerMode.NORMAL)
    image.insert_layer(layer, None, 0)
    Gimp.context_set_foreground(Gegl.Color.new('#336699'))
    layer.edit_fill(Gimp.FillType.FOREGROUND)

    # Seed the ORIGINAL metadata through the Core PDB raw-XML setter: the
    # config takes the image and the raw metadata-string only.
    set_proc = Gimp.get_pdb().lookup_procedure('gimp-image-set-metadata')
    pdb_config = set_proc.create_config()
    pdb_config.set_property('image', image)
    pdb_config.set_property('metadata-string', xml)
    result = set_proc.run(pdb_config)
    if result.index(0) != Gimp.PDBStatusType.SUCCESS:
        return _fail(procedure, 'gimp-image-set-metadata failed for mode %r' % mode)

    return Gimp.ValueArray.new_from_values([
        GObject.Value(Gimp.PDBStatusType, Gimp.PDBStatusType.SUCCESS),
        GObject.Value(Gimp.Image, image),
    ])


def oracle_gmeta(procedure, run_mode, image, drawables, config, data):
    """Dumps the image's serialized metadata XML for the C test to assert on."""
    work = _work_dir()
    if not work:
        return _fail(procedure, 'GLIMS_GMETA_DIR is not set')
    get_proc = Gimp.get_pdb().lookup_procedure('gimp-image-get-metadata')
    pdb_config = get_proc.create_config()
    pdb_config.set_property('image', image)
    result = get_proc.run(pdb_config)
    if result.index(0) != Gimp.PDBStatusType.SUCCESS:
        return _fail(procedure, 'gimp-image-get-metadata failed')
    metadata_string = result.index(1)
    try:
        with open(os.path.join(work, 'gmeta-oracle.xml'), 'w', encoding='utf-8') as f:
            f.write(metadata_string if metadata_string else '')
    except OSError as e:
        return _fail(procedure, 'cannot write the oracle file: %s' % e)
    return procedure.new_return_values(Gimp.PDBStatusType.SUCCESS, GLib.Error())


class GlimsMetadataLoader(Gimp.PlugIn):
    def do_query_procedures(self):
        return ['file-glims-gmeta-load', 'plug-in-glims-meta-oracle']

    def do_create_procedure(self, name):
        Gegl.init(None)
        if name == 'file-glims-gmeta-load':
            procedure = Gimp.LoadProcedure.new(self, name,
                                               Gimp.PDBProcType.PLUGIN,
                                               load_gmeta, None)
            procedure.set_menu_label('Glims metadata fixture')
            procedure.set_documentation('load a .gmeta test fixture',
                                        'loads a .gmeta test fixture', name)
            procedure.set_mime_types('image/x-glims-gmeta')
            procedure.set_extensions('gmeta')
        else:
            procedure = Gimp.ImageProcedure.new(self, name,
                                                Gimp.PDBProcType.PLUGIN,
                                                oracle_gmeta, None)
            procedure.set_image_types('*')
            procedure.set_menu_label('Glims metadata oracle')
            procedure.set_documentation('dump the image metadata XML',
                                        'dumps the image metadata XML', name)
            procedure.add_menu_path('<Image>/Filters/Glims Meta Oracle')
        return procedure


Gimp.main(GlimsMetadataLoader.__gtype__, sys.argv)
