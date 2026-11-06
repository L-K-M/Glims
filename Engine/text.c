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
#include "core/gimpcontainer.h"
#include "core/gimpdatafactory.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"

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

GlimsStatus
glims_text_layer_new (GlimsEngine             *engine,
                      GlimsImageID             id,
                      const char              *string,
                      const GlimsTextSettings *settings,
                      GlimsPoint               position,
                      GlimsItemID             *result,
                      char                   **error)
{
  GlimsStatus            status;
  GimpImage             *image = writable_image (engine, id, &status);
  GimpFont              *font;
  GimpTextJustification  justify;
  GimpText              *text;
  GeglColor             *color;
  GimpLayer             *layer;

  if (! image)
    return status;
  if (! string || ! *string || ! g_utf8_validate (string, -1, NULL) ||
      ! isfinite (position.x) || ! isfinite (position.y))
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
