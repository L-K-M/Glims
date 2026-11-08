/*
 * A genuine vector layer's native fill/stroke style (GIMP 3.2+):
 * vector_layer_style_get reads the layer's own GimpVectorLayerOptions, and
 * vector_layer_style_set changes the flagged fields as exactly one native
 * undo group around a whole-options snapshot
 * (gimp_image_undo_push_vector_layer with pspec NULL duplicates the options
 * object, app/path/gimpvectorlayerundo.c). Runs on the engine thread.
 *
 * The sequence mirrors the engine's own gimp_vector_layer_set
 * (app/path/gimpvectorlayer.c, 3.2.8+): undo group, freeze notify on the
 * layer and its options, push the snapshot, mutate, thaw, end the group —
 * inlined here so GIMP 3.2.0, which has no helper and no
 * GIMP_UNDO_GROUP_VECTOR, gets the identical semantics with
 * GIMP_UNDO_GROUP_DRAWABLE_MOD, the group its own vector push_undo uses.
 * The notify chain re-renders the layer on options-level properties; the
 * fill/stroke sub-objects do not re-emit the options' notify, so the setter
 * refreshes explicitly afterwards (gimp_vector_layer_refresh, which pushes
 * no undo — its render passes push_undo FALSE throughout).
 *
 * Only the fields XCF persists for a vector layer (PROP_VECTOR_LAYER,
 * app/xcf/xcf-save.c: enable flags, solid custom style, antialias, color,
 * stroke width/cap/join/miter) are exposed. Opacity, paint mode, unit, dash
 * offset, feather and stroke method are not persisted and stay untouched.
 * A native pattern style is reported UNSUPPORTED, never converted: the
 * setter never writes custom-style, so an existing solid style stays solid
 * and a pattern refuses the call before any mutation. The layer's name,
 * auto-rename policy and path association are never touched here.
 *
 * Colors go through the options' own contexts (gimp_context_set_foreground
 * duplicates), never the shared user context; the engine forces a context
 * color's alpha opaque, exactly as its own PDB setters and XCF load do.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include "libgimpbase/gimpbase.h"

#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "core/gimpfilloptions.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpimage-undo-push.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimpstrokeoptions.h"

#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimpvectorlayer.h"
#include "path/gimpvectorlayeroptions.h"

#if GIMP_CHECK_VERSION (3, 2, 8)
#define GLIMS_VECTOR_UNDO_GROUP GIMP_UNDO_GROUP_VECTOR
#else
/* 3.2.0 has no GIMP_UNDO_GROUP_VECTOR; its own vector-layer undo pushes
 * group under GIMP_UNDO_GROUP_DRAWABLE_MOD (gimpvectorlayer.c). */
#define GLIMS_VECTOR_UNDO_GROUP GIMP_UNDO_GROUP_DRAWABLE_MOD
#endif
#endif

#include "gimp-intl.h"

/* GIMP's own stroke width bounds (gimpstrokeoptions.c "width": 0 ... 2000)
 * and miter limit bounds ("miter-limit": 0 ... 100). */
#define MAX_VECTOR_STROKE_WIDTH 2000.0
#define MAX_VECTOR_MITER_LIMIT  100.0

#define GLIMS_VECTOR_STYLE_ALL                                              \
  (GLIMS_VECTOR_STYLE_ENABLE_FILL | GLIMS_VECTOR_STYLE_FILL_COLOR |         \
   GLIMS_VECTOR_STYLE_FILL_ANTIALIAS | GLIMS_VECTOR_STYLE_ENABLE_STROKE |  \
   GLIMS_VECTOR_STYLE_STROKE_COLOR | GLIMS_VECTOR_STYLE_STROKE_ANTIALIAS | \
   GLIMS_VECTOR_STYLE_STROKE_WIDTH | GLIMS_VECTOR_STYLE_STROKE_CAP |       \
   GLIMS_VECTOR_STYLE_STROKE_JOIN | GLIMS_VECTOR_STYLE_STROKE_MITER)

/* The open image behind `id`, ready for an edit: not busy with a plug-in,
 * an open stroke or a filter session. Checked first, before any argument
 * or layer validation, so a live session is never disturbed. */
static GlimsOpenImage *
editable_open_image (GlimsEngine  *engine,
                     GlimsImageID  id,
                     GlimsStatus  *status,
                     char        **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);

  *status = GLIMS_STATUS_OK;
  if (! open)
    *status = GLIMS_STATUS_NOT_FOUND;
  else if (engine->busy > 0)
    *status = GLIMS_STATUS_BUSY;
  else
    *status = glims_edit_ready (engine, open, error);

  return *status == GLIMS_STATUS_OK ? open : NULL;
}

#if GIMP_CHECK_VERSION (3, 2, 0)

/* The layer `id` of `image` while it is a genuine vector layer — not
 * rasterized, which gimp_item_is_vector_layer reports false for — or
 * NULL. A deleted item keeps its id while the undo stack holds it. */
static GimpVectorLayer *
find_vector_layer (GimpImage   *image,
                   GlimsItemID  id)
{
  GimpItem *item = gimp_item_get_by_id (image->gimp, id);

  if (! GIMP_IS_LAYER (item) || gimp_item_get_image (item) != image ||
      ! gimp_item_is_attached (item) || ! gimp_item_is_vector_layer (item))
    return NULL;

  return GIMP_VECTOR_LAYER (item);
}

static GimpCapStyle
cap_of (uint32_t cap)        /* a GlimsVectorCapStyle */
{
  switch (cap)
    {
    case GLIMS_VECTOR_CAP_ROUND:  return GIMP_CAP_ROUND;
    case GLIMS_VECTOR_CAP_SQUARE: return GIMP_CAP_SQUARE;
    default:                      return GIMP_CAP_BUTT;
    }
}

static GimpJoinStyle
join_of (uint32_t join)      /* a GlimsVectorJoinStyle */
{
  switch (join)
    {
    case GLIMS_VECTOR_JOIN_ROUND: return GIMP_JOIN_ROUND;
    case GLIMS_VECTOR_JOIN_BEVEL: return GIMP_JOIN_BEVEL;
    default:                      return GIMP_JOIN_MITER;
    }
}

static uint32_t
cap_of_glims (GimpCapStyle cap)
{
  switch (cap)
    {
    case GIMP_CAP_ROUND:  return GLIMS_VECTOR_CAP_ROUND;
    case GIMP_CAP_SQUARE: return GLIMS_VECTOR_CAP_SQUARE;
    default:              return GLIMS_VECTOR_CAP_BUTT;
    }
}

static uint32_t
join_of_glims (GimpJoinStyle join)
{
  switch (join)
    {
    case GIMP_JOIN_ROUND: return GLIMS_VECTOR_JOIN_ROUND;
    case GIMP_JOIN_BEVEL: return GLIMS_VECTOR_JOIN_BEVEL;
    default:              return GLIMS_VECTOR_JOIN_MITER;
    }
}

/* A native pattern fill or stroke is not convertible in this slice:
 * report it rather than rewriting it. */
static GlimsStatus
check_solid_style (GimpVectorLayerOptions *options,
                   char                  **error)
{
  if (gimp_fill_options_get_custom_style (options->fill_options) != GIMP_CUSTOM_STYLE_SOLID_COLOR ||
      gimp_fill_options_get_custom_style (GIMP_FILL_OPTIONS (options->stroke_options)) != GIMP_CUSTOM_STYLE_SOLID_COLOR)
    {
      if (error)
        *error = strdup ("This vector layer uses a pattern fill or stroke. Solid-color style controls cannot edit it.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  return GLIMS_STATUS_OK;
}

/* Fills `style` from the options. The context colors are borrowed
 * (gimp_context_get_foreground returns the context's own object); they are
 * read, never unref'd, and nothing is allocated. */
static void
read_style (GimpVectorLayerOptions *options,
            GlimsVectorStyle       *style)
{
  GeglColor *color;
  gboolean   b;
  gdouble    r = 0.0, g = 0.0, bl = 0.0, a = 0.0;

  memset (style, 0, sizeof *style);
  style->struct_size = sizeof *style;

  g_object_get (options, "enable-fill", &b, NULL);
  style->enable_fill = b ? true : false;
  color = gimp_context_get_foreground (GIMP_CONTEXT (options->fill_options));
  if (color)
    gegl_color_get_rgba_with_space (color, &r, &g, &bl, &a, NULL);
  style->fill_color     = (GlimsColor) { CLAMP (r, 0.0, 1.0), CLAMP (g, 0.0, 1.0),
                                         CLAMP (bl, 0.0, 1.0), 1.0 };
  style->fill_antialias = gimp_fill_options_get_antialias (options->fill_options) ? true : false;

  g_object_get (options, "enable-stroke", &b, NULL);
  style->enable_stroke = b ? true : false;
  r = g = bl = a = 0.0;
  color = gimp_context_get_foreground (GIMP_CONTEXT (options->stroke_options));
  if (color)
    gegl_color_get_rgba_with_space (color, &r, &g, &bl, &a, NULL);
  style->stroke_color       = (GlimsColor) { CLAMP (r, 0.0, 1.0), CLAMP (g, 0.0, 1.0),
                                             CLAMP (bl, 0.0, 1.0), 1.0 };
  style->stroke_antialias   = gimp_fill_options_get_antialias (GIMP_FILL_OPTIONS (options->stroke_options)) ? true : false;
  style->stroke_width       = gimp_stroke_options_get_width (options->stroke_options);
  style->stroke_cap         = cap_of_glims (gimp_stroke_options_get_cap_style (options->stroke_options));
  style->stroke_join        = join_of_glims (gimp_stroke_options_get_join_style (options->stroke_options));
  style->stroke_miter_limit = gimp_stroke_options_get_miter_limit (options->stroke_options);
}

/* The engine's own context color write: duplicate into the options'
 * context, alpha forced opaque by the engine itself; our copy is unref'd. */
static void
set_context_color (GimpContext      *context,
                   const GlimsColor *c)
{
  GeglColor *color = gegl_color_new (NULL);

  gegl_color_set_rgba_with_space (color, CLAMP (c->red, 0.0, 1.0), CLAMP (c->green, 0.0, 1.0),
                                  CLAMP (c->blue, 0.0, 1.0), CLAMP (c->alpha, 0.0, 1.0), NULL);
  gimp_context_set_foreground (context, color);
  g_object_unref (color);
}

static gboolean
valid_color (const GlimsColor *c)
{
  return isfinite (c->red) && isfinite (c->green) && isfinite (c->blue) && isfinite (c->alpha);
}

static gboolean
color_equals (const GlimsColor *a,
              const GlimsColor *b)
{
  /* The native opaque context round-trips RGB through float color spaces.
   * Its sub-micro-unit rounding must not create history for an unchanged
   * control value (including an exact 1 returning slightly above 1). */
  const gdouble epsilon = 1e-6;
  return fabs (a->red - b->red) <= epsilon && fabs (a->green - b->green) <= epsilon &&
         fabs (a->blue - b->blue) <= epsilon && a->alpha == b->alpha;
}

/* Validates every flagged field of `change` (clamping finite out-of-range
 * color components, as the other color setters do) before anything is
 * looked up or mutated. */
static GlimsStatus
validate_change (const GlimsVectorStyleChange *change,
                 GlimsVectorStyleChange       *normalized,
                 char                        **error)
{
  uint32_t p = change->properties;

  *normalized = *change;

  if (p & ~GLIMS_VECTOR_STYLE_ALL)
    {
      glims_fail (error, NULL, "The vector style change names an unknown field.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((p & GLIMS_VECTOR_STYLE_FILL_COLOR) && ! valid_color (&change->fill_color))
    {
      glims_fail (error, NULL, "The fill color is not finite.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((p & GLIMS_VECTOR_STYLE_STROKE_COLOR) && ! valid_color (&change->stroke_color))
    {
      glims_fail (error, NULL, "The stroke color is not finite.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((p & GLIMS_VECTOR_STYLE_STROKE_WIDTH) &&
      (! isfinite (change->stroke_width) || change->stroke_width <= 0.0 ||
       change->stroke_width > MAX_VECTOR_STROKE_WIDTH))
    {
      glims_fail (error, NULL, "The stroke width is outside 0 ... 2000 pixels.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((p & GLIMS_VECTOR_STYLE_STROKE_MITER) &&
      (! isfinite (change->stroke_miter_limit) || change->stroke_miter_limit < 0.0 ||
       change->stroke_miter_limit > MAX_VECTOR_MITER_LIMIT))
    {
      glims_fail (error, NULL, "The miter limit is outside 0 ... 100.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((p & GLIMS_VECTOR_STYLE_STROKE_CAP) &&
      (change->stroke_cap < GLIMS_VECTOR_CAP_BUTT || change->stroke_cap > GLIMS_VECTOR_CAP_SQUARE))
    {
      glims_fail (error, NULL, "The cap style is unknown.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if ((p & GLIMS_VECTOR_STYLE_STROKE_JOIN) &&
      (change->stroke_join < GLIMS_VECTOR_JOIN_MITER || change->stroke_join > GLIMS_VECTOR_JOIN_BEVEL))
    {
      glims_fail (error, NULL, "The join style is unknown.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* Only flagged fields are input. Native context colors are opaque, so
   * normalize alpha before comparing the effective color for a no-op. */
  if (p & GLIMS_VECTOR_STYLE_FILL_COLOR)
    normalized->fill_color = (GlimsColor) { CLAMP (change->fill_color.red, 0.0, 1.0),
                                           CLAMP (change->fill_color.green, 0.0, 1.0),
                                           CLAMP (change->fill_color.blue, 0.0, 1.0), 1.0 };
  if (p & GLIMS_VECTOR_STYLE_STROKE_COLOR)
    normalized->stroke_color = (GlimsColor) { CLAMP (change->stroke_color.red, 0.0, 1.0),
                                             CLAMP (change->stroke_color.green, 0.0, 1.0),
                                             CLAMP (change->stroke_color.blue, 0.0, 1.0), 1.0 };

  return GLIMS_STATUS_OK;
}

#endif /* GIMP_CHECK_VERSION (3, 2, 0) */

GlimsStatus
glims_vector_layer_style_get (GlimsEngine      *engine,
                              GlimsImageID      id,
                              GlimsItemID       layer_id,
                              GlimsVectorStyle *style,
                              char            **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, id);

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! style || style->struct_size < sizeof (GlimsVectorStyle))
    return GLIMS_STATUS_INVALID_ARGUMENT;

#if GIMP_CHECK_VERSION (3, 2, 0)
  {
    GimpVectorLayer        *layer = find_vector_layer (open->image, layer_id);
    GimpVectorLayerOptions *options;
    GlimsStatus             status;

    if (! layer)
      return GLIMS_STATUS_NOT_FOUND;

    options = gimp_vector_layer_get_options (layer);
    if (! options)
      return glims_fail (error, NULL, "The vector layer has no options.");

    status = check_solid_style (options, error);
    if (status != GLIMS_STATUS_OK)
      return status;

    read_style (options, style);

    return GLIMS_STATUS_OK;
  }
#else
  /* Vector layers arrived in GIMP 3.2. */
  if (error)
    *error = strdup ("This engine has no vector layers; they arrived in GIMP 3.2.");
  return GLIMS_STATUS_UNSUPPORTED;
#endif
}

GlimsStatus
glims_vector_layer_style_set (GlimsEngine                   *engine,
                              GlimsImageID                   id,
                              GlimsItemID                    layer_id,
                              const GlimsVectorStyleChange  *change,
                              char                         **error)
{
  GlimsStatus     status;
  GlimsOpenImage *open = editable_open_image (engine, id, &status, error);

  /* Busy (a plug-in, an open stroke or a filter preview) is checked
   * first, before argument validation, so a live session is refused
   * untouched. */
  if (! open)
    return status;
  if (! change || change->struct_size < sizeof (GlimsVectorStyleChange))
    return GLIMS_STATUS_INVALID_ARGUMENT;

#if ! GIMP_CHECK_VERSION (3, 2, 0)
  /* Vector layers arrived in GIMP 3.2; nothing is mutated. */
  if (error)
    *error = strdup ("This engine has no vector layers; they arrived in GIMP 3.2.");
  return GLIMS_STATUS_UNSUPPORTED;
#else
  {
    GlimsVectorStyleChange   c;
    GimpVectorLayer         *layer;
    GimpVectorLayerOptions  *options;
    GimpImage               *image;
    GlimsVectorStyle         current;
    uint32_t                 p;
    gboolean                 differs = FALSE;
    const gchar             *desc = _("Change Vector Layer Style");

    status = validate_change (change, &c, error);
    if (status != GLIMS_STATUS_OK)
      return status;

    layer = find_vector_layer (open->image, layer_id);
    if (! layer)
      return GLIMS_STATUS_NOT_FOUND;

    /* Pixel lock of the layer or inherited from a group around it. */
    status = glims_check_item_locks (GIMP_ITEM (layer), GLIMS_LOCK_PIXELS, error);
    if (status != GLIMS_STATUS_OK)
      return status;

    options = gimp_vector_layer_get_options (layer);
    if (! options)
      return glims_fail (error, NULL, "The vector layer has no options.");

    status = check_solid_style (options, error);
    if (status != GLIMS_STATUS_OK)
      return status;

    /* A change that would alter nothing is a no-op: no undo step. */
    read_style (options, &current);
    p = c.properties;
    if ((p & GLIMS_VECTOR_STYLE_ENABLE_FILL) && c.enable_fill != current.enable_fill)
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_FILL_COLOR) && ! color_equals (&c.fill_color, &current.fill_color))
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_FILL_ANTIALIAS) && c.fill_antialias != current.fill_antialias)
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_ENABLE_STROKE) && c.enable_stroke != current.enable_stroke)
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_STROKE_COLOR) && ! color_equals (&c.stroke_color, &current.stroke_color))
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_STROKE_ANTIALIAS) && c.stroke_antialias != current.stroke_antialias)
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_STROKE_WIDTH) && c.stroke_width != current.stroke_width)
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_STROKE_CAP) && c.stroke_cap != current.stroke_cap)
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_STROKE_JOIN) && c.stroke_join != current.stroke_join)
      differs = TRUE;
    if ((p & GLIMS_VECTOR_STYLE_STROKE_MITER) && c.stroke_miter_limit != current.stroke_miter_limit)
      differs = TRUE;
    if (! differs)
      return GLIMS_STATUS_OK;

    image = open->image;

    /* Exactly one native undo step: a group around the whole-options
     * snapshot, as gimp_vector_layer_set does on 3.2.8+ (app/path/
     * gimpvectorlayer.c); 3.2.0 gets the same sequence with
     * GIMP_UNDO_GROUP_DRAWABLE_MOD. The name, the auto-rename policy and
     * the path association are not touched. */
    gimp_image_undo_group_start (image, GLIMS_VECTOR_UNDO_GROUP, desc);

    g_object_freeze_notify (G_OBJECT (layer));
    g_object_freeze_notify (G_OBJECT (options));

    gimp_image_undo_push_vector_layer (image, desc, layer, NULL);

    if (p & GLIMS_VECTOR_STYLE_ENABLE_FILL)
      g_object_set (options, "enable-fill", c.enable_fill, NULL);
    if (p & GLIMS_VECTOR_STYLE_FILL_COLOR)
      set_context_color (GIMP_CONTEXT (options->fill_options), &c.fill_color);
    if (p & GLIMS_VECTOR_STYLE_FILL_ANTIALIAS)
      gimp_fill_options_set_antialias (options->fill_options, c.fill_antialias);

    if (p & GLIMS_VECTOR_STYLE_ENABLE_STROKE)
      g_object_set (options, "enable-stroke", c.enable_stroke, NULL);
    if (p & GLIMS_VECTOR_STYLE_STROKE_COLOR)
      set_context_color (GIMP_CONTEXT (options->stroke_options), &c.stroke_color);
    if (p & GLIMS_VECTOR_STYLE_STROKE_ANTIALIAS)
      gimp_fill_options_set_antialias (GIMP_FILL_OPTIONS (options->stroke_options), c.stroke_antialias);
    if (p & GLIMS_VECTOR_STYLE_STROKE_WIDTH)
      g_object_set (options->stroke_options, "width", c.stroke_width, NULL);
    if (p & GLIMS_VECTOR_STYLE_STROKE_CAP)
      g_object_set (options->stroke_options, "cap-style", cap_of (c.stroke_cap), NULL);
    if (p & GLIMS_VECTOR_STYLE_STROKE_JOIN)
      g_object_set (options->stroke_options, "join-style", join_of (c.stroke_join), NULL);
    if (p & GLIMS_VECTOR_STYLE_STROKE_MITER)
      g_object_set (options->stroke_options, "miter-limit", c.stroke_miter_limit, NULL);

    g_object_thaw_notify (G_OBJECT (options));
    g_object_thaw_notify (G_OBJECT (layer));

    gimp_image_undo_group_end (image);

    /* Sub-object changes do not re-emit the options' notify, so re-render
     * explicitly (pushes no undo); then flush, the adapter convention. */
    gimp_vector_layer_refresh (layer);
    gimp_image_flush (image);

    return GLIMS_STATUS_OK;
  }
#endif
}
