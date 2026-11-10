/* Slot168, source-only fixture. Expected content is made by independent
 * literal GimpText/Core calls, never the facade's preparation helper.
 * GIMP3.2.8 7addd2b77efb798bbdc4d2fb082e786a48478ced:
 * tools/gimptexttool.c1655-1728; GIMP3.0.8
 * 6ac8031c9555667e080fef0324fca9f28a02e5ab:1633-1706.
 * This harness links immutable167 objects without any slot168 helper symbol.
 * Missing tail is an explicit RED, never an out-of-table read or fake PASS. */
#include "engine-private.h"
#include <float.h>
#include <limits.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdatafactory.h"
#include "core/gimpdrawable.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimplayer-floating-selection.h"
#include "core/gimplayermask.h"
#include "core/gimpobject.h"
#include "text/gimpfont.h"
#include "text/gimptext.h"
#include "text/gimptextlayer.h"
#include "gimp-intl.h"

int main (int argc, char **argv);
static const GlimsEngineAPI *api;
static gboolean available;
static gint checks, failures;
#define CHECK(c, ...) do { gboolean ok_ = (c); checks++; \
  printf ("%s ", ok_ ? "ok  " : "FAIL"); printf (__VA_ARGS__); printf ("\n"); \
  if (!ok_) failures++; fflush (stdout); } while (0)
#define NEED(c, ...) do { gboolean ok_need_ = (c); CHECK (ok_need_, __VA_ARGS__); \
  if (!ok_need_) goto cleanup; } while (0)
_Static_assert (offsetof (GlimsEngineAPI, text_layer_new_captured) ==
                offsetof (GlimsEngineAPI, image_pick_layer) + sizeof (((GlimsEngineAPI *)0)->image_pick_layer),
                "slot168 must append to the unchanged167 prefix");

typedef struct {
  GlimsImageID image;
  GlimsItemID background, group, layer, mask, channel, floating, text;
  GlimsItemID target;
} Scene;
typedef struct {
  Scene scene;
  GlimsFloatingState expected;
  GlimsTextSettings settings;
  gchar *before;
  gint undo_count;
} Caller;

static gint id_of (gpointer item) { return item ? gimp_item_get_id (GIMP_ITEM (item)) : 0; }
static GimpImage *image_of (GlimsEngine *e, Scene *s) {
  GlimsOpenImage *open = glims_lookup_image (e, s->image); return open ? open->image : NULL;
}
static GimpItem *item_of (GlimsEngine *e, GlimsItemID id) { return gimp_item_get_by_id (e->gimp, id); }

static gint
identity (const Scene *s, gpointer item, gboolean exact)
{
  gint id = id_of (item);
  if (!id || exact) return id;
  if (id == s->background) return 1;
  if (id == s->group) return 2;
  if (id == s->layer) return 3;
  if (id == s->mask) return 4;
  if (id == s->channel) return 5;
  if (id == s->floating) return 6;
  if (id == s->text) return 7;
  return -1; /* Unknown objects must not silently compare equal. */
}

static void
append_buffer (GString *s, GimpDrawable *drawable)
{
  GeglBuffer *buffer = gimp_drawable_get_buffer (drawable); /* Borrowed. */
  const GeglRectangle *extent = gegl_buffer_get_extent (buffer);
  const Babl *format = gegl_buffer_get_format (buffer);
  gsize size = (gsize) extent->width * extent->height * babl_format_get_bytes_per_pixel (format);
  guchar *pixels = g_malloc (size);
  gegl_buffer_get (buffer, extent, 1, format, pixels, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  g_string_append_printf (s, "bytes:%s:%d:%d:%d:%d;", babl_get_name (format), extent->x, extent->y, extent->width, extent->height);
  g_string_append_len (s, (const gchar *) pixels, size); g_free (pixels);
}

static gchar *
drawable_hash (GlimsEngine *e, GlimsItemID id)
{
  GString *bytes = g_string_new (NULL);
  gchar *result;
  append_buffer (bytes, GIMP_DRAWABLE (item_of (e, id)));
  result = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guchar *) bytes->str, bytes->len);
  g_string_free (bytes, TRUE); return result;
}

/* exact=TRUE includes actual IDs and complete history for refusal checks.
 * FALSE normalizes known roles and omits history for cross-image/Undo content
 * comparison; history counts and one-step transitions are checked separately. */
static gchar *
state (GlimsEngine *e, Scene *s, gboolean exact)
{
  GimpImage *image = image_of (e, s);
  GlimsImageInfo info = {0};
  GlimsUndoInfo undo = {0};
  GlimsHistoryInfo history = {0};
  GlimsHistoryRow *rows = NULL;
  GList *layers = NULL, *channels = NULL, *it;
  GString *out = g_string_new (NULL);
  gchar *result = NULL;
  guint8 composite[40 * 32 * 4];
  GimpLayer *floating;
  if (!image || api->image_info (e, s->image, &info) != GLIMS_STATUS_OK) goto done;
  g_string_append_printf (out, "image:%d:%d:%d:%d:%s;group:%d;", info.width, info.height,
    info.layer_count, info.dirty, info.precision, gimp_image_get_undo_group_count (image));
  if (exact) {
    if (api->image_undo_info (e, s->image, &undo) != GLIMS_STATUS_OK ||
        api->image_history (e, s->image, NULL, 0, &history) != GLIMS_STATUS_OK) goto done;
    rows = g_new0 (GlimsHistoryRow, history.count);
    if (api->image_history (e, s->image, rows, history.count, &history) != GLIMS_STATUS_OK) goto done;
    g_string_append_printf (out, "undo:%d:%d:%s:%s;history:%" G_GUINT64_FORMAT ":%d:%d;", undo.undo_count,
      undo.redo_count, undo.next_undo, undo.next_redo, (guint64) history.revision, history.count, history.current_position);
    for (gint i = 0; i < history.count; i++) g_string_append_printf (out, "%d:%s;", rows[i].position, rows[i].name);
  }
  floating = gimp_image_get_floating_selection (image);
  g_string_append_printf (out, "floating:%d:%d;", identity (s, floating, exact),
    identity (s, floating ? gimp_layer_get_floating_sel_drawable (floating) : NULL, exact));
  for (it = gimp_image_get_selected_layers (image); it; it = it->next)
    g_string_append_printf (out, "selected:%d;", identity (s, it->data, exact));
  for (it = gimp_image_get_selected_channels (image); it; it = it->next)
    g_string_append_printf (out, "selected-channel:%d;", identity (s, it->data, exact));
  append_buffer (out, GIMP_DRAWABLE (gimp_image_get_mask (image)));
  layers = gimp_image_get_layer_list (image);
  for (it = layers; it; it = it->next) {
    GimpLayer *layer = it->data;
    GimpItem *item = GIMP_ITEM (layer);
    GimpLayerMask *mask = gimp_layer_get_mask (layer);
    GlimsMaskState flags = {0};
    gint x, y;
    gimp_item_get_offset (item, &x, &y);
    g_string_append_printf (out, "layer:%d:%s:%s:%d:%d:%d:%d:%d:%d:%.17g:%d:%d:%d;", identity (s, layer, exact),
      G_OBJECT_TYPE_NAME (layer), gimp_object_get_name (layer), identity (s, gimp_layer_get_parent (layer), exact),
      gimp_item_get_index (item), x, y, gimp_item_get_width (item), gimp_item_get_height (item),
      gimp_layer_get_opacity (layer), gimp_item_get_visible (item), gimp_item_get_lock_content (item), gimp_item_get_lock_position (item));
    if (!GIMP_IS_GROUP_LAYER (layer)) append_buffer (out, GIMP_DRAWABLE (layer));
    if (api->layer_mask (e, s->image, id_of (layer), &flags) != GLIMS_STATUS_OK) goto done;
    g_string_append_printf (out, "mask:%d:%d:%d:%d;", identity (s, mask, exact), flags.enabled, flags.editing, flags.showing);
    if (mask) append_buffer (out, GIMP_DRAWABLE (mask));
    if (GIMP_IS_TEXT_LAYER (layer)) {
      GimpText *text = gimp_text_layer_get_text (GIMP_TEXT_LAYER (layer));
      gdouble rgba[4];
      if (!text) goto done;
      gegl_color_get_pixel (text->color, babl_format ("R'G'B'A double"), rgba);
      g_string_append_printf (out, "text:%s:%s:%.17g:%d:%.17g:%.17g:%d:%.17g:%.17g:%.17g:%.17g;",
        text->text ? text->text : "", gimp_object_get_name (text->font), text->font_size, text->justify,
        text->line_spacing, text->letter_spacing, text->antialias, rgba[0], rgba[1], rgba[2], rgba[3]);
    }
  }
  channels = gimp_image_get_channel_list (image);
  for (it = channels; it; it = it->next) {
    g_string_append_printf (out, "channel:%d:%s;", identity (s, it->data, exact), gimp_object_get_name (it->data));
    append_buffer (out, GIMP_DRAWABLE (it->data));
  }
  if (api->image_render (e, s->image, 1, (GlimsRect) {0, 0, 40, 32}, composite, 40 * 4) != GLIMS_STATUS_OK) goto done;
  g_string_append_len (out, (const gchar *) composite, sizeof composite);
  result = g_compute_checksum_for_data (G_CHECKSUM_SHA256, (const guchar *) out->str, out->len);
done:
  g_free (rows); g_list_free (layers); g_list_free (channels); g_string_free (out, TRUE); return result;
}

static gboolean
matches (GlimsEngine *e, Scene *s, gboolean exact, const gchar *expected)
{
  gchar *fresh = state (e, s, exact);
  gboolean equal = expected && fresh && !strcmp (expected, fresh);
  g_free (fresh); return equal;
}

static gboolean
make_scene (GlimsEngine *e, Scene *s, guint kind)
{
  GimpImage *image;
  GimpLayer *group, *layer;
  GList *list;
  guint8 pixels[24 * 20 * 4], pasted[6 * 6 * 4];
  GlimsSelectOptions options = { .struct_size = sizeof options, .operation = GLIMS_SELECT_REPLACE };
  if (api->image_new (e, 40, 32, &s->image, NULL) != GLIMS_STATUS_OK) return FALSE;
  image = image_of (e, s);
  list = gimp_image_get_layer_list (image); s->background = list ? id_of (list->data) : 0; g_list_free (list);
  group = gimp_group_layer_new (image);
  if (!group || !gimp_image_add_layer (image, group, NULL, 0, FALSE)) { if (group) g_object_unref (group); return FALSE; }
  s->group = id_of (group);
  layer = gimp_layer_new (image, 24, 20, gimp_image_get_layer_format (image, TRUE), "Asymmetric target", 1, GIMP_LAYER_MODE_NORMAL);
  if (!layer) return FALSE;
  gimp_item_set_offset (GIMP_ITEM (layer), 3, 4);
  if (!gimp_image_add_layer (image, layer, group, 0, FALSE)) { g_object_unref (layer); return FALSE; }
  s->layer = id_of (layer); s->target = s->layer;
  for (guint i = 0; i < 24 * 20; i++) {
    pixels[4*i] = 20 + (i*13)%210; pixels[4*i+1] = 30 + (i*7)%200;
    pixels[4*i+2] = 40 + (i*19)%190; pixels[4*i+3] = 90 + (i*11)%166;
  }
  gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (layer)), GEGL_RECTANGLE (0,0,24,20), 0,
                   babl_format ("R'G'B'A u8"), pixels, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (GIMP_DRAWABLE (layer), 0, 0, 24, 20);
  if (kind == 2) {
    guint8 values[24 * 20];
    if (api->layer_mask_add (e, s->image, s->layer, GLIMS_MASK_WHITE, FALSE, &s->mask, NULL) != GLIMS_STATUS_OK) return FALSE;
    for (guint i = 0; i < G_N_ELEMENTS (values); i++) values[i] = 30 + (i*17)%210;
    values[0] = 0; /* Literal control independent of the channel format's TRC. */
    gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (item_of (e, s->mask))), GEGL_RECTANGLE (0,0,24,20), 0,
                     babl_format ("Y u8"), values, GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update (GIMP_DRAWABLE (item_of (e, s->mask)), 0, 0, 24, 20);
    s->target = s->mask;
  }
  if (kind == 3) {
    GeglColor *color = gegl_color_new ("rgba(0.1,0.4,0.8,0.5)");
    GimpChannel *channel = gimp_channel_new (image, 40, 32, "Saved contrast channel", color);
    guint8 values[40 * 32];
    g_object_unref (color);
    if (!channel || !gimp_image_add_channel (image, channel, NULL, 0, FALSE)) { if (channel) g_object_unref (channel); return FALSE; }
    s->channel = id_of (channel); s->target = s->channel;
    gimp_item_set_visible (GIMP_ITEM (channel), FALSE, FALSE);
    for (guint i = 0; i < G_N_ELEMENTS (values); i++) values[i] = 20 + (i*23)%220;
    values[0] = 255;
    gegl_buffer_set (gimp_drawable_get_buffer (GIMP_DRAWABLE (channel)), GEGL_RECTANGLE (0,0,40,32), 0,
                     babl_format ("Y u8"), values, GEGL_AUTO_ROWSTRIDE);
    gimp_drawable_update (GIMP_DRAWABLE (channel), 0, 0, 40, 32);
  }
  if (kind) {
    if (api->select_shape (e, s->image, GLIMS_SHAPE_RECTANGLE, (GlimsPoint[]) {{8,9},{14,15}}, 2, &options) != GLIMS_STATUS_OK) return FALSE;
    for (guint i = 0; i < 36; i++) {
      pasted[4*i] = 210-(i*3)%160; pasted[4*i+1] = 15+(i*5)%180;
      pasted[4*i+2] = 40+(i*7)%190; pasted[4*i+3] = i%5 ? 180 : 0;
    }
    if (api->image_paste_into (e, s->image, s->target, (GlimsRect) {8,9,6,6}, pasted, sizeof pasted, &s->floating, NULL) != GLIMS_STATUS_OK) return FALSE;
  }
  gimp_image_flush (image); return TRUE;
}

/* Explicit direct Core expectation: no production text preparation, resolve
 * helper, captured endpoint, or explicit facade Anchor participates. */
static gboolean
direct_text (GlimsEngine *e, Scene *s, const GlimsTextSettings *settings)
{
  GimpImage *image = image_of (e, s);
  GimpContainer *fonts = gimp_data_factory_get_container (e->gimp->font_factory);
  GimpFont *font = GIMP_FONT (gimp_container_get_child_by_name (fonts, settings->font));
  GeglColor *color = gegl_color_new (NULL);
  const gdouble rgba[4] = {0.2,0.4,0.8,0.75};
  GimpText *text;
  GimpLayer *layer;
  gboolean added, ended;
  if (!font) { g_object_unref (color); return FALSE; }
  gegl_color_set_pixel (color, babl_format ("R'G'B'A double"), rgba);
  text = g_object_new (GIMP_TYPE_TEXT, "gimp", e->gimp, "text", "Captured A\nText", "font", font,
    "font-size", 18.0, "font-size-unit", gimp_unit_pixel (), "color", color,
    "justify", GIMP_TEXT_JUSTIFY_CENTER, "line-spacing", 2.0, "letter-spacing", 0.5,
    "antialias", TRUE, "box-mode", GIMP_TEXT_BOX_DYNAMIC, NULL);
  g_object_unref (color); layer = gimp_text_layer_new (image, text); g_object_unref (text);
  if (!layer) return FALSE;
  if (!gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_TEXT, _("Add Text Layer"))) { g_object_unref (layer); return FALSE; }
  if (gimp_image_get_floating_selection (image)) floating_sel_anchor (gimp_image_get_floating_selection (image));
  /* Existing facade policy, independently literal expected integer offsets. */
  gimp_item_set_offset (GIMP_ITEM (layer), 13, -3);
  added = gimp_image_add_layer (image, layer, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE);
  ended = gimp_image_undo_group_end (image);
  if (added) s->text = id_of (layer); else g_object_unref (layer);
  gimp_image_flush (image); return added && ended;
}

static void
close_scene (GlimsEngine *e, Scene *s)
{
  if (s->image) { CHECK (api->image_close (e, s->image) == GLIMS_STATUS_OK, "close owned text scene"); s->image = 0; }
}

static void
refuse (GlimsEngine *e, Scene *s, const GlimsFloatingState *expected, const char *text,
        const GlimsTextSettings *settings, GlimsPoint point, GlimsStatus wanted, const char *label)
{
  gchar *before = state (e, s, TRUE);
  GlimsItemID out = -777;
  char *error = NULL;
  GlimsStatus status = api->text_layer_new_captured (e, s->image, expected, text, settings, point, &out, &error);
  CHECK (status == wanted && out == 0, "preflight/refusal resets output: %s (status%d)", label, status);
  CHECK (matches (e, s, TRUE, before), "refusal preserves full state/history: %s", label);
  if (error) api->free_string (error);
  g_free (before);
}

static GlimsStatus
exercise (GlimsEngine *e, gpointer data)
{
  Caller *caller = data;
  GlimsTextSettings settings = { .struct_size = sizeof settings, .size = 18,
    .color = {0.2,0.4,0.8,0.75}, .justify = GLIMS_JUSTIFY_CENTER, .line_spacing = 2, .letter_spacing = 0.5, .antialias = true };
  Scene actual = {0}, reference = {0}, rejected = {0};
  gchar *font_names = NULL, *original = NULL, *post = NULL, *ref_original = NULL, *target_before = NULL;
  GlimsStatus result = GLIMS_STATUS_FAILED;
  NEED (api->fonts (e, &font_names) == GLIMS_STATUS_OK && font_names && *font_names, "installed font catalogue is required, never skipped");
  {
    gchar *end = strchr (font_names, '\n');
    gsize length = end ? (gsize) (end-font_names) : strlen (font_names);
    NEED (length > 0 && length < sizeof settings.font, "literal installed font fits owned settings");
    memcpy (settings.font, font_names, length); settings.font[length] = 0;
  }
  for (guint kind = 0; kind < 4; kind++) {
    GlimsFloatingState expected = { .struct_size = sizeof expected };
    GlimsUndoInfo before = {0}, ref_before = {0}, after = {0}, ref_after = {0};
    NEED (make_scene (e, &actual, kind) && make_scene (e, &reference, kind), "independently seed paired literal scene kind%u", kind);
    NEED (api->image_floating_selection (e, actual.image, &expected) == GLIMS_STATUS_OK &&
      expected.active == (kind != 0) && expected.floating == actual.floating && (!kind || expected.target == actual.target),
      "captured expectation reports the literal owner/attachment kind%u", kind);
    {
      guint8 pixel[4] = {0};
      gegl_buffer_get (gimp_drawable_get_buffer (GIMP_DRAWABLE (item_of (e, actual.target))), GEGL_RECTANGLE (0,0,1,1), 1,
        babl_format (kind == 2 || kind == 3 ? "Y u8" : "R'G'B'A u8"), pixel, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
      CHECK (expected.target_kind == kind &&
        (kind == 2 ? pixel[0] == 0 : kind == 3 ? pixel[0] == 255 :
         pixel[0] == 20 && pixel[1] == 30 && pixel[2] == 40 && pixel[3] == 90),
        "literal target kind and independent source pixel seed kind%u", kind);
    }
    original = state (e, &actual, FALSE); ref_original = state (e, &reference, FALSE);
    CHECK (original && ref_original && !strcmp (original, ref_original), "independent seeds have identical normalized content kind%u", kind);
    api->image_undo_info (e, actual.image, &before); api->image_undo_info (e, reference.image, &ref_before);
    target_before = drawable_hash (e, reference.target);
    NEED (direct_text (e, &reference, &settings), "independent direct native text/anchor/ACTIVE_PARENT path kind%u", kind);
    api->image_undo_info (e, reference.image, &ref_after);
    post = state (e, &reference, FALSE);
    CHECK (post && reference.text > 0 && !gimp_image_get_floating_selection (image_of (e, &reference)) &&
      ref_after.undo_count == ref_before.undo_count + 1, "direct native reference is one outer Text Undo with float resolved kind%u", kind);
    {
      gchar *target_after = drawable_hash (e, reference.target);
      CHECK (target_before && target_after && (kind ? strcmp (target_before, target_after) != 0 : !strcmp (target_before, target_after)),
        "direct native anchor changes attachment bytes only when a float exists kind%u", kind);
      g_free (target_after);
    }
    CHECK (api->image_undo (e, reference.image) == GLIMS_STATUS_OK, "direct reference Undo kind%u", kind);
    CHECK (matches (e, &reference, FALSE, ref_original), "native reference Undo restores float/source/selection/tree kind%u", kind);
    CHECK (api->image_redo (e, reference.image) == GLIMS_STATUS_OK, "direct reference Redo kind%u", kind);
    CHECK (matches (e, &reference, FALSE, post), "direct reference Redo restores exact text result kind%u", kind);
    g_clear_pointer (&ref_original, g_free); g_clear_pointer (&target_before, g_free);
    if (available) {
      char *error = NULL;
      GlimsStatus status = api->text_layer_new_captured (e, actual.image, &expected, "Captured A\nText", &settings,
                                                        (GlimsPoint) {12.6,-2.6}, &actual.text, &error);
      CHECK (status == GLIMS_STATUS_OK && actual.text > 0, "slot168 succeeds with owned new text id kind%u (%s)", kind, error ? error : "");
      if (error) api->free_string (error);
      CHECK (matches (e, &actual, FALSE, post), "all source/text/mask/channel/tree/composite match independent Core kind%u", kind);
      api->image_undo_info (e, actual.image, &after);
      CHECK (after.undo_count == before.undo_count + 1 && !strcmp (after.next_undo, ref_after.next_undo), "one Text Undo equals direct native history kind%u", kind);
      CHECK (api->image_undo (e, actual.image) == GLIMS_STATUS_OK, "slot168 Undo kind%u", kind);
      CHECK (matches (e, &actual, FALSE, original), "one Undo restores original float/source/selection kind%u", kind);
      CHECK (api->image_redo (e, actual.image) == GLIMS_STATUS_OK, "slot168 Redo kind%u", kind);
      CHECK (matches (e, &actual, FALSE, post), "Redo exactly matches independent native result kind%u", kind);
    } else printf ("NOTE slot168 absent: facade mutation/Undo cases NOT RUN for kind%u\n", kind);
    g_clear_pointer (&original, g_free); g_clear_pointer (&post, g_free);
    close_scene (e, &actual); close_scene (e, &reference);
  }
  if (available) {
    GlimsFloatingState expected = { .struct_size = sizeof expected }, bad;
    GlimsTextSettings invalid;
    GlimsItemID out;
    gchar *before;
    char *error = NULL;
    NEED (make_scene (e, &rejected, 1) && api->image_floating_selection (e, rejected.image, &expected) == GLIMS_STATUS_OK,
      "seed the retained active float for ordinary refusal oracles");
    refuse (e, &rejected, NULL, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "missing expectation");
    bad = expected; bad.struct_size = 4;
    refuse (e, &rejected, &bad, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "short expected prefix");
    bad = expected; bad.target_kind = 99;
    refuse (e, &rejected, &bad, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "unknown owned target kind");
    bad = expected; bad.active = false;
    refuse (e, &rejected, &bad, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "inconsistent inactive expectation");
    bad = (GlimsFloatingState) { .struct_size = sizeof bad };
    refuse (e, &rejected, &bad, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_NOT_FOUND, "intervening float after inactive capture");
    bad = expected; bad.floating = G_MAXINT;
    refuse (e, &rejected, &bad, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_NOT_FOUND, "stale floating identity");
    bad = expected; bad.target = rejected.background;
    refuse (e, &rejected, &bad, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_NOT_FOUND, "changed captured attachment");
    bad = expected; bad.target_kind = GLIMS_FLOATING_TARGET_CHANNEL;
    refuse (e, &rejected, &bad, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_NOT_FOUND, "changed attachment kind");
    refuse (e, &rejected, &expected, "", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "empty text never anchors");
    refuse (e, &rejected, &expected, NULL, &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "missing text never anchors");
    refuse (e, &rejected, &expected, "\xff", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "invalid UTF8");
    refuse (e, &rejected, &expected, "x", NULL, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "missing settings");
    invalid = settings; invalid.size = -1;
    refuse (e, &rejected, &expected, "x", &invalid, (GlimsPoint) {0,0}, GLIMS_STATUS_INVALID_ARGUMENT, "invalid settings preflight");
    invalid = settings; g_strlcpy (invalid.font, "No Such Installed Font - slot168 fixture", sizeof invalid.font);
    refuse (e, &rejected, &expected, "x", &invalid, (GlimsPoint) {0,0}, GLIMS_STATUS_NOT_FOUND, "unknown font, not a claimed layout-NULL case");
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {NAN,0}, GLIMS_STATUS_INVALID_ARGUMENT, "nonfinite coordinate");
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {DBL_MAX,0}, GLIMS_STATUS_INVALID_ARGUMENT, "rounded coordinate out of gint range");
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {G_MAXINT,0}, GLIMS_STATUS_INVALID_ARGUMENT, "rendered right edge overflows despite valid offset");
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {0,G_MAXINT}, GLIMS_STATUS_INVALID_ARGUMENT, "rendered bottom edge overflows despite valid offset");
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {G_MININT,0}, GLIMS_STATUS_INVALID_ARGUMENT, "negative origin makes native union width unrepresentable");
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {0,G_MININT}, GLIMS_STATUS_INVALID_ARGUMENT, "negative origin makes native union height unrepresentable");
    gimp_item_set_lock_content (item_of (e, rejected.group), TRUE, FALSE);
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_LOCKED, "attachment inherited pixel lock");
    gimp_item_set_lock_content (item_of (e, rejected.group), FALSE, FALSE);
    e->busy++;
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_BUSY, "busy/reentrant admission");
    e->busy--;
    {
      GlimsStrokeID stroke = 0;
      GlimsBrushSettings brush = { .struct_size = sizeof brush, .size = 3, .opacity = 0,
        .tool = GLIMS_PAINT_PENCIL, .hardness = 1, .rate = -1, .flow = -1, .exposure = -1 };
      GlimsStrokePoint first = { .x = 9, .y = 10, .pressure = 1, .time_ms = 100 };
      CHECK (api->stroke_begin (e, rejected.image, rejected.floating, &brush, &first, &stroke, NULL) == GLIMS_STATUS_OK && stroke,
        "open a real native stroke for text readiness admission");
      if (stroke) {
        refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint){0,0}, GLIMS_STATUS_BUSY, "active native stroke");
        CHECK (api->stroke_end (e, stroke) == GLIMS_STATUS_OK, "end the accepted readiness stroke");
      }
    }
    {
      GlimsFilterID filter = 0;
      CHECK (api->filter_begin (e, rejected.image, rejected.floating, "gegl:gaussian-blur", &filter, NULL) == GLIMS_STATUS_OK && filter,
        "open a real generic native preview for text readiness admission");
      if (filter) {
        refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint){0,0}, GLIMS_STATUS_BUSY, "active native preview");
        CHECK (api->filter_abort (e, filter) == GLIMS_STATUS_OK, "abort readiness preview without committing it");
      }
    }
    gimp_image_undo_freeze (image_of (e, &rejected));
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_BUSY, "frozen Undo");
    gimp_image_undo_thaw (image_of (e, &rejected));
    NEED (gimp_image_undo_group_start (image_of (e, &rejected), GIMP_UNDO_GROUP_TEXT, "Existing outer group"), "open a legitimate competing native Undo group");
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint) {0,0}, GLIMS_STATUS_BUSY, "existing outer Undo group");
    CHECK (gimp_image_undo_group_end (image_of (e, &rejected)), "close competing group without disturbing a rejected operation");
    before = state (e, &rejected, TRUE);
    CHECK (api->text_layer_new_captured (e, rejected.image, &expected, "x", &settings, (GlimsPoint){0,0}, NULL, &error) == GLIMS_STATUS_INVALID_ARGUMENT,
      "mandatory output is checked without mutation");
    CHECK (matches (e, &rejected, TRUE, before), "missing output leaves complete state unchanged");
    g_free (before); if (error) { api->free_string (error); error = NULL; }
    before = state (e, &rejected, TRUE); out = -777;
    CHECK (api->text_layer_new_captured (e, G_MAXINT, &expected, "x", &settings, (GlimsPoint){0,0}, &out, &error) == GLIMS_STATUS_NOT_FOUND && out == 0,
      "unknown image resets output and never targets another open scene");
    CHECK (matches (e, &rejected, TRUE, before), "unknown image leaves A unchanged");
    g_free (before); if (error) { api->free_string (error); error = NULL; }
    CHECK (api->floating_command (e, rejected.image, expected.floating, GLIMS_FLOATING_TO_LAYER, NULL, &error) == GLIMS_STATUS_OK,
      "detach captured floating ID through legitimate existing native action");
    if (error) { api->free_string (error); error = NULL; }
    refuse (e, &rejected, &expected, "x", &settings, (GlimsPoint){0,0}, GLIMS_STATUS_NOT_FOUND, "same item ID is now ordinary, never anchor fallback");
    NEED (make_scene (e, &caller->scene, 1), "create image retained for external caller transport proof");
    NEED (api->image_floating_selection (e, caller->scene.image, &caller->expected) == GLIMS_STATUS_OK, "capture external caller expectation");
    before = state (e, &caller->scene, TRUE);
    refuse (e, &rejected, &caller->expected, "x", &settings, (GlimsPoint){0,0}, GLIMS_STATUS_NOT_FOUND, "another image's captured float never retargets A");
    CHECK (matches (e, &caller->scene, TRUE, before), "foreign expected state leaves owning image B unchanged");
    g_free (before);
    close_scene (e, &rejected);
    {
      GlimsFloatingState none = { .struct_size = sizeof none };
      gint x, y;
      NEED (make_scene (e, &rejected, 0), "seed ordinary off-canvas creation control");
      before = state (e, &rejected, FALSE);
      CHECK (api->text_layer_new_captured (e, rejected.image, &none, "Captured A\nText", &settings,
        (GlimsPoint){-1000.6,-2000.6}, &rejected.text, NULL) == GLIMS_STATUS_OK && rejected.text > 0,
        "safe ordinary off-canvas text remains accepted without clamping");
      if (rejected.text > 0) {
        gimp_item_get_offset (item_of (e, rejected.text), &x, &y);
        CHECK (x == -1001 && y == -2001, "off-canvas negative fractions preserve existing floor-plus-half policy");
      } else CHECK (FALSE, "off-canvas negative fractions have a real text item");
      CHECK (api->image_undo (e, rejected.image) == GLIMS_STATUS_OK && matches (e, &rejected, FALSE, before),
        "off-canvas creation one Undo restores complete original content");
      g_free (before); close_scene (e, &rejected);
    }
    caller->settings = settings; caller->before = state (e, &caller->scene, FALSE);
    {
      GlimsUndoInfo undo = {0}; api->image_undo_info (e, caller->scene.image, &undo); caller->undo_count = undo.undo_count;
    }
    CHECK (e->busy == 0 && gimp_image_get_undo_group_count (image_of (e, &caller->scene)) == 0,
      "all successful/refusal paths release fences and outer groups");
  } else printf ("NOTE slot168 absent: all facade refusal/transport cases NOT RUN; missing168 check is RED\n");
  result = GLIMS_STATUS_OK;
cleanup:
  if (font_names) api->free_string (font_names);
  g_free (original); g_free (post);
  g_free (ref_original); g_free (target_before);
  close_scene (e, &actual); close_scene (e, &reference); close_scene (e, &rejected);
  return result;
}

static GlimsStatus
finish (GlimsEngine *e, gpointer data)
{
  Caller *caller = data;
  if (caller->scene.image) {
    GlimsUndoInfo undo = {0};
    GlimsFloatingState now = { .struct_size = sizeof now };
    api->image_undo_info (e, caller->scene.image, &undo);
    CHECK (api->image_floating_selection (e, caller->scene.image, &now) == GLIMS_STATUS_OK && !now.active &&
      caller->scene.text > 0 && undo.undo_count == caller->undo_count+1, "external transport creates and anchors exactly once");
    CHECK (api->image_undo (e, caller->scene.image) == GLIMS_STATUS_OK && matches (e, &caller->scene, FALSE, caller->before),
      "external transport one Undo restores captured source/float content");
    close_scene (e, &caller->scene);
  }
  g_clear_pointer (&caller->before, g_free); return GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngine *engine = NULL;
  Caller caller = {0};
  GlimsEngineConfig config = { .struct_size = sizeof config };
  char *error = NULL;
  gchar *user, *cache;
  GlimsStatus status;
  if (argc != 2) return 2;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  CHECK (api && api->struct_size >= offsetof (GlimsEngineAPI, image_pick_layer)+sizeof api->image_pick_layer,
    "immutable producer exposes the required167 prefix");
  if (failures) return 2;
  available = api->struct_size >= offsetof (GlimsEngineAPI, text_layer_new_captured)+sizeof api->text_layer_new_captured && api->text_layer_new_captured;
  CHECK (available, "slot168 is present (old167 baseline admission RED)");
  user = g_build_filename (argv[1], "user", NULL); cache = g_build_filename (argv[1], "cache", NULL);
  config.user_directory = user; config.cache_directory = cache;
  status = api->start (&config, &engine, &error);
  CHECK (status == GLIMS_STATUS_OK && engine, "start isolated native engine");
  if (engine && status == GLIMS_STATUS_OK) {
    CHECK (glims_engine_call (engine, exercise, &caller) == GLIMS_STATUS_OK, "independent native fixtures complete on engine worker");
    if (available && caller.scene.image) {
      GlimsItemID out = -777;
      char *untouched_error = (char *) (uintptr_t) 1;
      CHECK (api->text_layer_new_captured (NULL, caller.scene.image, &caller.expected, "x", &caller.settings,
          (GlimsPoint){0,0}, &out, &untouched_error) == GLIMS_STATUS_NOT_RUNNING && out == 0 && untouched_error == NULL,
        "null engine dispatch resets mandatory output and error before admission");
      CHECK (api->text_layer_new_captured (engine, caller.scene.image, &caller.expected, "Captured A\nText", &caller.settings,
          (GlimsPoint){12.6,-2.6}, &caller.scene.text, &error) == GLIMS_STATUS_OK && caller.scene.text > 0,
        "public caller transport queues explicit image/expectation/text payload");
    }
    CHECK (glims_engine_call (engine, finish, &caller) == GLIMS_STATUS_OK, "owned caller image cleanup completes before stop");
    api->stop (engine);
  }
  if (error) { fprintf (stderr, "%s\n", error); api->free_string (error); }
  g_free (user); g_free (cache);
  printf ("%s: %d checks, %d failures\n", failures ? "FAILED" : "PASSED", checks, failures);
  return failures ? 1 : 0;
}
