/*
 * Text layers: the fonts the engine knows, and creating, reading and
 * changing text layers, each change one undo step. Runs on the engine
 * thread.
 *
 * GIMP's text tool does the same with the same engine functions
 * (app/tools/gimptexttool.c gimp_text_tool_create_layer and
 * gimp_text_tool_apply; app/text/gimptextlayer.c gimp_text_layer_set).
 * Glims edits plain text with one look per layer; a layer whose text GIMP
 * stored as markup reads back as its plain text and keeps its markup
 * until its text is changed.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include <pango/pango.h>

#include "libgimpbase/gimpbase.h"

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpdatafactory.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimplayer-floating-selection.h"
#include "core/gimplayermask.h"

#include "text/gimpfont.h"
#include "text/gimptext.h"
#include "text/gimptextlayer.h"

#include "gimp-intl.h"

/* The largest size a text setting takes, in pixels; GIMP's own limit for
 * the font size property. */
#define MAX_TEXT_SIZE 8192.0

static GimpImage *
writable_image (GlimsEngine  *engine,
                GlimsImageID  id,
                GlimsStatus  *status)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);

  *status = GLIMS_STATUS_OK;
  if (! open)
    *status = GLIMS_STATUS_NOT_FOUND;
  else if (engine->busy > 0)
    *status = GLIMS_STATUS_BUSY;

  return *status == GLIMS_STATUS_OK ? open->image : NULL;
}

/* The text layer `id` of `image`, or NULL. */
static GimpTextLayer *
find_text_layer (GimpImage   *image,
                 GlimsItemID  id)
{
  GimpItem *item = gimp_item_get_by_id (image->gimp, id);

  if (! item || gimp_item_get_image (item) != image || ! gimp_item_is_attached (item) ||
      ! gimp_item_is_text_layer (item))
    return NULL;

  return GIMP_TEXT_LAYER (item);
}

/* The fonts, loaded: GIMP loads them in the background at start. */
static GimpContainer *
font_container (Gimp *gimp)
{
  gimp_data_factory_data_wait (gimp->font_factory);

  return gimp_data_factory_get_container (gimp->font_factory);
}

static void
add_name (GimpObject *font,
          GPtrArray  *names)
{
  g_ptr_array_add (names, (gpointer) gimp_object_get_name (font));
}

static gint
compare_names (gconstpointer a,
               gconstpointer b)
{
  return g_utf8_collate (*(const gchar **) a, *(const gchar **) b);
}

GlimsStatus
glims_fonts (GlimsEngine  *engine,
             char        **names)
{
  GimpContainer *fonts;
  GPtrArray     *sorted;
  gchar         *joined;

  if (! names)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  fonts  = font_container (engine->gimp);
  sorted = g_ptr_array_new ();
  gimp_container_foreach (fonts, (GFunc) add_name, sorted);
  g_ptr_array_sort (sorted, compare_names);
  g_ptr_array_add (sorted, NULL);

  joined = g_strjoinv ("\n", (gchar **) sorted->pdata);
  *names = strdup (joined);
  g_free (joined);
  g_ptr_array_free (sorted, TRUE);

  return *names ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static gboolean
justification (uint32_t               justify,
               GimpTextJustification *result)
{
  switch (justify)
    {
    case GLIMS_JUSTIFY_LEFT:   *result = GIMP_TEXT_JUSTIFY_LEFT;   return TRUE;
    case GLIMS_JUSTIFY_RIGHT:  *result = GIMP_TEXT_JUSTIFY_RIGHT;  return TRUE;
    case GLIMS_JUSTIFY_CENTER: *result = GIMP_TEXT_JUSTIFY_CENTER; return TRUE;
    case GLIMS_JUSTIFY_FILL:   *result = GIMP_TEXT_JUSTIFY_FILL;   return TRUE;
    default:                   return FALSE;
    }
}

static uint32_t
glims_justification (GimpTextJustification justify)
{
  switch (justify)
    {
    case GIMP_TEXT_JUSTIFY_RIGHT:  return GLIMS_JUSTIFY_RIGHT;
    case GIMP_TEXT_JUSTIFY_CENTER: return GLIMS_JUSTIFY_CENTER;
    case GIMP_TEXT_JUSTIFY_FILL:   return GLIMS_JUSTIFY_FILL;
    default:                       return GLIMS_JUSTIFY_LEFT;
    }
}

/* Checks `settings` and finds its font; the error says what is wrong. */
static GlimsStatus
resolve_settings (GlimsEngine              *engine,
                  const GlimsTextSettings  *settings,
                  GimpFont                **font,
                  GimpTextJustification    *justify,
                  char                    **error)
{
  const GlimsColor *c;

  if (! settings || settings->struct_size < sizeof (GlimsTextSettings))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  c = &settings->color;
  if (! isfinite (settings->size) || settings->size <= 0 || settings->size > MAX_TEXT_SIZE ||
      ! isfinite (settings->line_spacing) || ! isfinite (settings->letter_spacing) ||
      ! isfinite (c->red) || ! isfinite (c->green) || ! isfinite (c->blue) || ! isfinite (c->alpha) ||
      ! justification (settings->justify, justify) ||
      ! memchr (settings->font, '\0', sizeof settings->font))
    {
      glims_fail (error, NULL, "The text settings are not valid.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  *font = GIMP_FONT (gimp_container_get_child_by_name (font_container (engine->gimp),
                                                       settings->font));
  if (! *font)
    {
      glims_fail (error, NULL, "The font is not installed.");
      return GLIMS_STATUS_NOT_FOUND;
    }

  return GLIMS_STATUS_OK;
}

static GeglColor *
gegl_color_from (const GlimsColor *color)
{
  GeglColor *result = gegl_color_new (NULL);
  gdouble    rgba[4] = { CLAMP (color->red, 0, 1), CLAMP (color->green, 0, 1),
                         CLAMP (color->blue, 0, 1), CLAMP (color->alpha, 0, 1) };

  gegl_color_set_pixel (result, babl_format ("R'G'B'A double"), rgba);

  return result;
}

/* Prepare a rendered, detached layer. Its floating reference is transferred
 * to the caller, as with gimp_text_layer_new itself. No image Undo or anchor. */
static GlimsStatus
prepare_text_layer (GlimsEngine             *engine,
                    GimpImage               *image,
                    const char              *string,
                    const GlimsTextSettings *settings,
                    GimpLayer              **result,
                    char                   **error)
{
  GlimsStatus            status;
  GimpFont              *font;
  GimpTextJustification  justify;
  GimpText              *text;
  GeglColor             *color;
  GimpLayer             *layer;

  *result = NULL;
  if (! string || ! *string || ! g_utf8_validate (string, -1, NULL))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = resolve_settings (engine, settings, &font, &justify, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  color = gegl_color_from (&settings->color);
  text  = g_object_new (GIMP_TYPE_TEXT,
                        "gimp",           engine->gimp,
                        "text",           string,
                        "font",           font,
                        "font-size",      settings->size,
                        "font-size-unit", gimp_unit_pixel (),
                        "color",          color,
                        "justify",        justify,
                        "line-spacing",   settings->line_spacing,
                        "letter-spacing", settings->letter_spacing,
                        "antialias",      (gboolean) settings->antialias,
                        "box-mode",       GIMP_TEXT_BOX_DYNAMIC,
                        NULL);
  g_object_unref (color);

  layer = gimp_text_layer_new (image, text);
  g_object_unref (text);
  if (! layer)
    return glims_fail (error, NULL, "The text could not be laid out.");

  *result = layer;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_text_layer_new (GlimsEngine             *engine,
                      GlimsImageID             id,
                      const char              *string,
                      const GlimsTextSettings *settings,
                      GlimsPoint               position,
                      GlimsItemID             *result,
                      char                   **error)
{
  GlimsStatus status;
  GimpImage *image = writable_image (engine, id, &status);
  GimpLayer *layer = NULL;

  if (! image) return status;
  if (! isfinite (position.x) || ! isfinite (position.y))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  status = prepare_text_layer (engine, image, string, settings, &layer, error);
  if (status != GLIMS_STATUS_OK) return status;

  gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_TEXT, _("Add Text Layer"));
  gimp_item_set_offset (GIMP_ITEM (layer), (gint) floor (position.x + 0.5),
                        (gint) floor (position.y + 0.5));
  gimp_image_add_layer (image, layer, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE);
  gimp_image_undo_group_end (image);
  gimp_image_flush (image);

  if (result)
    *result = gimp_item_get_id (GIMP_ITEM (layer));

  return GLIMS_STATUS_OK;
}

static GlimsStatus
captured_text_error (GlimsStatus status, char **error, const char *message)
{
  glims_fail (error, NULL, message);
  return status;
}

/* Core group sizing adds item offsets to drawable rectangles, unions them,
 * then subtracts origins (gimpgrouplayer.c2091-2121 in the pinned3.2.8).
 * Keep every coordinate and union span representable before that gint math.
 * This is a conservative domain check, not an insertion-parent prediction. */
static gboolean
extend_text_extent (gint64 bounds[4], gint64 x, gint64 y, gint64 width, gint64 height)
{
  gint64 right = x + width, bottom = y + height;
  if (width < 0 || height < 0 || x < G_MININT || y < G_MININT || right > G_MAXINT || bottom > G_MAXINT)
    return FALSE;
  bounds[0] = MIN (bounds[0], x); bounds[1] = MIN (bounds[1], y);
  bounds[2] = MAX (bounds[2], right); bounds[3] = MAX (bounds[3], bottom);
  return bounds[2] - bounds[0] <= G_MAXINT && bounds[3] - bounds[1] <= G_MAXINT;
}

static gboolean
include_drawable_extent (gint64 bounds[4], GimpDrawable *drawable, gint64 x, gint64 y)
{
  GeglRectangle box = gimp_drawable_get_bounding_box (drawable);
  return extend_text_extent (bounds, x, y, gimp_item_get_width (GIMP_ITEM (drawable)), gimp_item_get_height (GIMP_ITEM (drawable))) &&
         extend_text_extent (bounds, x + box.x, y + box.y, box.width, box.height);
}

static GlimsStatus
captured_text_extent_ready (GimpImage *image, GimpLayer *layer, gint x, gint y, char **error)
{
  gint64 bounds[4] = {0, 0, gimp_image_get_width (image), gimp_image_get_height (image)};
  GList *layers = gimp_image_get_layer_list (image);
  GList *channels = gimp_image_get_channel_list (image);
  GList *it;
  gboolean valid = include_drawable_extent (bounds, GIMP_DRAWABLE (layer), x, y);
  for (it = layers; valid && it; it = it->next) {
    GimpLayer *existing = it->data;
    GimpLayerMask *mask = gimp_layer_get_mask (existing);
    gint off_x, off_y;
    gimp_item_get_offset (GIMP_ITEM (existing), &off_x, &off_y);
    valid = include_drawable_extent (bounds, GIMP_DRAWABLE (existing), off_x, off_y);
    if (valid && mask) {
      gimp_item_get_offset (GIMP_ITEM (mask), &off_x, &off_y);
      valid = include_drawable_extent (bounds, GIMP_DRAWABLE (mask), off_x, off_y);
    }
  }
  for (it = channels; valid && it; it = it->next) {
    gint off_x, off_y;
    gimp_item_get_offset (GIMP_ITEM (it->data), &off_x, &off_y);
    valid = include_drawable_extent (bounds, GIMP_DRAWABLE (it->data), off_x, off_y);
  }
  g_list_free (layers); g_list_free (channels);
  return valid ? GLIMS_STATUS_OK : captured_text_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
    "The text extent and existing drawable bounds exceed the supported coordinate range; no text was added.");
}

/* Identity and write/Undo admission facts that can be rechecked while our
 * own balanced busy fence is held. The public entry checks busy separately. */
static GlimsStatus
captured_text_ready (GlimsEngine *engine, GlimsOpenImage *open,
                     const GlimsFloatingState *expected,
                     GimpLayer **floating, GimpDrawable **target, char **error)
{
  GlimsFloatingState fresh = { .struct_size = sizeof fresh };
  GlimsStatus status = glims_image_floating_selection (engine, gimp_image_get_id (open->image), &fresh);
  *floating = NULL;
  *target = NULL;
  if (status != GLIMS_STATUS_OK) return status;
  if (fresh.active != expected->active || fresh.floating != expected->floating ||
      fresh.target != expected->target || fresh.target_kind != expected->target_kind)
    return captured_text_error (GLIMS_STATUS_NOT_FOUND, error,
      "The captured floating selection or its attachment changed; no text was added.");
  if (g_hash_table_size (engine->strokes) > 0 || glims_filters_active_for_image (engine, open->image) ||
      !gimp_image_undo_is_enabled (open->image) || gimp_image_get_undo_group_count (open->image))
    return captured_text_error (GLIMS_STATUS_BUSY, error,
      "Finish the current edit and enable Undo before creating text.");
  if (!expected->active) return GLIMS_STATUS_OK;
  *floating = gimp_image_get_floating_selection (open->image);
  *target = *floating ? gimp_layer_get_floating_sel_drawable (*floating) : NULL;
  if (!*floating || !*target || !GIMP_IS_DRAWABLE (*target) ||
      gimp_item_get_image (GIMP_ITEM (*floating)) != open->image ||
      gimp_item_get_image (GIMP_ITEM (*target)) != open->image ||
      !gimp_item_is_attached (GIMP_ITEM (*floating)) || !gimp_item_is_attached (GIMP_ITEM (*target)))
    return captured_text_error (GLIMS_STATUS_NOT_FOUND, error,
      "The captured floating selection no longer has its attached target; no text was added.");
  if ((expected->target_kind == GLIMS_FLOATING_TARGET_LAYER && !GIMP_IS_LAYER (*target)) ||
      (expected->target_kind == GLIMS_FLOATING_TARGET_LAYER_MASK && !GIMP_IS_LAYER_MASK (*target)) ||
      (expected->target_kind == GLIMS_FLOATING_TARGET_CHANNEL &&
       (!GIMP_IS_CHANNEL (*target) || GIMP_IS_LAYER_MASK (*target) ||
        gimp_item_get_container (GIMP_ITEM (*target)) != gimp_image_get_channels (open->image))))
    return captured_text_error (GLIMS_STATUS_NOT_FOUND, error,
      "The captured attachment is no longer a layer, its mask or a saved channel of this image.");
  /* Fresh owned state already confirms float/target IDs and native class
   * mapping through floating.c, including mask-before-channel semantics. */
  return glims_check_item_locks (GIMP_ITEM (*target), GLIMS_LOCK_PIXELS, error);
}

/* Compound creation, following native Text's prepare -> outer Text Undo ->
 * anchor -> ACTIVE_PARENT insertion order. GIMP3.2.8 7addd2b77efb798bbdc4d2fb082e786a48478ced
 * tools/gimptexttool.c1655-1728; GIMP3.0.8 6ac8031c9555667e080fef0324fca9f28a02e5ab:1633-1706. */
GlimsStatus
glims_text_layer_new_captured (GlimsEngine *engine, GlimsImageID id,
                               const GlimsFloatingState *expected,
                               const char *string, const GlimsTextSettings *settings,
                               GlimsPoint position, GlimsItemID *out, char **error)
{
  GlimsFloatingState captured;
  GlimsOpenImage *open;
  GimpImage *image;
  GimpLayer *floating = NULL, *fresh_floating = NULL, *layer = NULL;
  GimpDrawable *target = NULL, *fresh_target = NULL;
  GlimsStatus status;
  gdouble x, y;
  gboolean group_open = FALSE, mutation_started = FALSE;

  if (error) *error = NULL;
  if (out) *out = 0;
  if (!out || !expected || expected->struct_size < sizeof captured)
    return captured_text_error (GLIMS_STATUS_INVALID_ARGUMENT, error,
      "A complete captured floating state and text layer result are required.");
  captured = *expected; /* Copy only the known sized prefix, never a future tail. */
  if ((captured.active && (captured.floating <= 0 || captured.target <= 0 ||
       (captured.target_kind != GLIMS_FLOATING_TARGET_LAYER &&
        captured.target_kind != GLIMS_FLOATING_TARGET_LAYER_MASK && captured.target_kind != GLIMS_FLOATING_TARGET_CHANNEL))) ||
      (!captured.active && (captured.floating != 0 || captured.target != 0 || captured.target_kind != 0)))
    return captured_text_error (GLIMS_STATUS_INVALID_ARGUMENT, error, "The captured floating state is inconsistent.");
  if (!engine) return GLIMS_STATUS_NOT_RUNNING;
  if (!isfinite (position.x) || !isfinite (position.y)) return GLIMS_STATUS_INVALID_ARGUMENT;
  x = floor (position.x + 0.5); y = floor (position.y + 0.5);
  if (!isfinite (x) || !isfinite (y) || x < G_MININT || x > G_MAXINT || y < G_MININT || y > G_MAXINT)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  open = glims_lookup_image (engine, id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = captured_text_ready (engine, open, &captured, &floating, &target, error);
  if (status != GLIMS_STATUS_OK) return status;

  image = g_object_ref (open->image);
  if (floating) g_object_ref (floating);
  if (target) g_object_ref (target);
  engine->busy++;
  status = prepare_text_layer (engine, image, string, settings, &layer, error);
  if (status != GLIMS_STATUS_OK) goto done;
  /* Own a nonfloating reference independent of the item stack's sink. */
  g_object_ref_sink (layer);
  status = captured_text_extent_ready (image, layer, (gint) x, (gint) y, error);
  if (status != GLIMS_STATUS_OK) goto done;
  status = captured_text_ready (engine, open, &captured, &fresh_floating, &fresh_target, error);
  if (status != GLIMS_STATUS_OK) goto done;
  if (fresh_floating != floating || fresh_target != target) {
    status = captured_text_error (GLIMS_STATUS_NOT_FOUND, error, "The captured text target changed during preparation; no text was added.");
    goto done;
  }
  if (engine->busy != 1) {
    status = captured_text_error (GLIMS_STATUS_BUSY, error, "Finish the current engine operation before creating text.");
    goto done;
  }
  /* Group start itself may mark dirty before a rare failure. Undo grouping
   * is not rollback; ordinary frozen/open-group cases were refused above. */
  mutation_started = TRUE;
  if (!gimp_image_undo_group_start (image, GIMP_UNDO_GROUP_TEXT, _("Add Text Layer"))) {
    status = captured_text_error (GLIMS_STATUS_FAILED, error,
      "The text Undo group could not start. The image may have changed; inspect it and Undo if available.");
    goto done;
  }
  group_open = TRUE;
  if (floating) floating_sel_anchor (floating); /* Void Core merge; no pixel-success guarantee. */
  if (gimp_image_get_floating_selection (image)) {
    status = captured_text_error (GLIMS_STATUS_FAILED, error,
      "The floating selection did not resolve. The image may have changed; inspect it and use Undo if needed.");
    goto done;
  }
  gimp_item_set_offset (GIMP_ITEM (layer), (gint) x, (gint) y);
  if (!gimp_image_add_layer (image, layer, GIMP_IMAGE_ACTIVE_PARENT, -1, TRUE)) {
    status = captured_text_error (GLIMS_STATUS_FAILED, error,
      "The text could not be inserted. The image may already have changed; inspect it and use Undo if needed.");
    goto done;
  }
  if (!gimp_image_undo_group_end (image) || gimp_image_get_undo_group_count (image) != 0) {
    status = captured_text_error (GLIMS_STATUS_FAILED, error,
      "The text Undo group could not close. The image may already have changed; inspect it and use Undo if needed.");
    goto done;
  }
  group_open = FALSE;
  if (gimp_item_get_id (GIMP_ITEM (layer)) <= 0) {
    status = captured_text_error (GLIMS_STATUS_FAILED, error,
      "The inserted text has no valid item ID. The image may have changed; inspect it and use Undo if needed.");
    goto done;
  }
  *out = gimp_item_get_id (GIMP_ITEM (layer));
  status = GLIMS_STATUS_OK;
done:
  if (group_open && gimp_image_get_undo_group_count (image) > 0)
    gimp_image_undo_group_end (image); /* Best effort, only our successfully opened group. */
  if (mutation_started) gimp_image_flush (image);
  if (layer) g_object_unref (layer);
  if (target) g_object_unref (target);
  if (floating) g_object_unref (floating);
  g_object_unref (image);
  engine->busy--;
  return status;
}

GlimsStatus
glims_text_layer_get (GlimsEngine       *engine,
                      GlimsImageID       id,
                      GlimsItemID        layer_id,
                      char             **string,
                      GlimsTextSettings *settings)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpTextLayer  *layer;
  GimpText       *text;
  gchar          *plain = NULL;
  gdouble         rgba[4] = { 0, 0, 0, 1 };

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (settings && settings->struct_size < sizeof (GlimsTextSettings))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = find_text_layer (open->image, layer_id);
  text  = layer ? gimp_text_layer_get_text (layer) : NULL;
  if (! text)
    return GLIMS_STATUS_NOT_FOUND;

  if (string)
    {
      if (text->markup)
        pango_parse_markup (text->markup, -1, 0, NULL, &plain, NULL, NULL);
      *string = strdup (plain ? plain : (text->text ? text->text : ""));
      g_free (plain);
    }

  if (settings)
    {
      gdouble xres, yres;

      memset (settings->font, 0, sizeof settings->font);
      if (text->font)
        g_strlcpy (settings->font, gimp_object_get_name (text->font), sizeof settings->font);

      gimp_image_get_resolution (open->image, &xres, &yres);
      settings->size = text->unit == gimp_unit_pixel ()
        ? text->font_size
        : gimp_units_to_pixels (text->font_size, text->unit, yres);

      if (text->color)
        gegl_color_get_pixel (text->color, babl_format ("R'G'B'A double"), rgba);
      settings->color          = (GlimsColor) { rgba[0], rgba[1], rgba[2], rgba[3] };
      settings->justify        = glims_justification (text->justify);
      /* Line spacing is kept in the text's unit, like the size; letter
       * spacing is always pixels (app/text/gimptextlayout.c). */
      settings->line_spacing   = text->unit == gimp_unit_pixel ()
        ? text->line_spacing
        : gimp_units_to_pixels (text->line_spacing, text->unit, yres);
      settings->letter_spacing = text->letter_spacing;
      settings->antialias      = text->antialias ? true : false;
    }

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_text_layer_set (GlimsEngine             *engine,
                      GlimsImageID             id,
                      GlimsItemID              layer_id,
                      const char              *string,
                      const GlimsTextSettings *settings,
                      char                   **error)
{
  GlimsStatus            status;
  GimpImage             *image = writable_image (engine, id, &status);
  GimpTextLayer         *layer;
  GimpFont              *font = NULL;
  GimpTextJustification  justify = GIMP_TEXT_JUSTIFY_LEFT;
  GeglColor             *color;
  GimpText              *current;
  gdouble                indent = 0.0;

  if (! image)
    return status;
  if (string && (! *string || ! g_utf8_validate (string, -1, NULL)))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  layer = find_text_layer (image, layer_id);
  if (! layer)
    return GLIMS_STATUS_NOT_FOUND;
  if (! string && ! settings)
    return GLIMS_STATUS_OK;
  status = glims_check_item_locks (GIMP_ITEM (layer), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;

  /* Settings arrive in pixels and move the text to pixels; the first-line
   * indent, which the facade does not carry, is kept in the text's unit
   * too (app/text/gimptextlayout.c), so it moves to pixels with them. */
  current = gimp_text_layer_get_text (layer);
  if (current)
    {
      gdouble xres, yres;

      gimp_image_get_resolution (image, &xres, &yres);
      indent = current->unit == gimp_unit_pixel ()
        ? current->indent
        : gimp_units_to_pixels (current->indent, current->unit, xres);
    }

  if (settings)
    {
      status = resolve_settings (engine, settings, &font, &justify, error);
      if (status != GLIMS_STATUS_OK)
        return status;
    }

  /* One call, so one undo step: gimp_text_layer_set opens the group, and
   * setting "text" drops any markup the layer had. */
  if (string && settings)
    {
      color = gegl_color_from (&settings->color);
      gimp_text_layer_set (layer, _("Edit Text"),
                           "text",           string,
                           "font",           font,
                           "font-size",      settings->size,
                           "font-size-unit", gimp_unit_pixel (),
                           "color",          color,
                           "justify",        justify,
                           "line-spacing",   settings->line_spacing,
                           "letter-spacing", settings->letter_spacing,
                           "antialias",      (gboolean) settings->antialias,
                           "indent",         indent,
                           NULL);
      g_object_unref (color);
    }
  else if (settings)
    {
      color = gegl_color_from (&settings->color);
      gimp_text_layer_set (layer, _("Edit Text"),
                           "font",           font,
                           "font-size",      settings->size,
                           "font-size-unit", gimp_unit_pixel (),
                           "color",          color,
                           "justify",        justify,
                           "line-spacing",   settings->line_spacing,
                           "letter-spacing", settings->letter_spacing,
                           "antialias",      (gboolean) settings->antialias,
                           "indent",         indent,
                           NULL);
      g_object_unref (color);
    }
  else
    {
      gimp_text_layer_set (layer, _("Edit Text"), "text", string, NULL);
    }

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}
