/*
 * Paint strokes with GIMP's paint cores: paintbrush, pencil, airbrush,
 * eraser, smudge, blur and sharpen, dodge and burn, clone and heal. Runs
 * on the engine thread.
 *
 * The call sequence is the one GIMP's own gimp_paint_core_stroke()
 * (app/paint/gimppaintcore-stroke.c) uses, split over begin, continue and
 * end so the app can feed pointer events as they arrive. GIMP's GTK paint
 * tool additionally paints on a worker thread and smooths input; neither is
 * reproduced yet (docs/plan.md).
 */
#include "engine-private.h"
#include "brush-fingerprint.h"
#include "stroke-dynamics-fingerprint.h"
#include "plate-storage.h"
#include "component-paint.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpdrawable.h"
#include "core/gimpdynamics.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-symmetry.h"
#include "core/gimpitem.h"
#include "core/gimplayer.h"
#include "core/gimppaintinfo.h"
#include "core/gimpsymmetry.h"

#include "paint/gimpairbrush.h"
#include "paint/gimppaintcore.h"
#include "paint/gimppaintoptions.h"
#include "paint/gimpsourceoptions.h"

/* Engine names; resolved at run time so a missing one fails visibly. */
#define PRESSURE_SIZE_DYNAMICS  "Pressure Size"

/* The paint info (core and options type) behind each Glims paint tool, as
 * GIMP's tools register them (app/paint/gimp*.c, gimp_*_register). */
static const gchar *const paint_infos[] =
{
  [GLIMS_PAINT_PAINTBRUSH] = "gimp-paintbrush",
  [GLIMS_PAINT_PENCIL]     = "gimp-pencil",
  [GLIMS_PAINT_AIRBRUSH]   = "gimp-airbrush",
  [GLIMS_PAINT_ERASER]     = "gimp-eraser",
  [GLIMS_PAINT_SMUDGE]     = "gimp-smudge",
  [GLIMS_PAINT_BLUR]       = "gimp-convolve",
  [GLIMS_PAINT_SHARPEN]    = "gimp-convolve",
  [GLIMS_PAINT_DODGE]      = "gimp-dodge-burn",
  [GLIMS_PAINT_BURN]       = "gimp-dodge-burn",
  [GLIMS_PAINT_CLONE]      = "gimp-clone",
  [GLIMS_PAINT_HEAL]       = "gimp-heal",
  [GLIMS_PAINT_SPONGE_DESATURATE] = "glims-sponge-desaturate",
  [GLIMS_PAINT_SPONGE_SATURATE]   = "glims-sponge-saturate",
};

typedef enum { GLIMS_STROKE_INPUT_V1, GLIMS_STROKE_INPUT_V2 } GlimsStrokeInputVersion;

typedef struct
{
  GimpImage        *image;
  GimpDrawable     *drawable;
  GList            *drawables;
  GimpPaintCore    *core;
  GimpPaintOptions *options;
  GlimsStrokeInputVersion input_version;
  guint32          last_time_ms; /* V2 only, after an entire accepted packet */
  gboolean         component_stroke;
} GlimsStroke;

/* Live source options may still sample another document on every motion.
 * Check both destination and retained sources on the serialized engine thread. */
gboolean
glims_stroke_references_image (GlimsEngine *engine, GlimsStrokeID id, GimpImage *image)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  if (!stroke) return FALSE;
  if (stroke->image == image) return TRUE;
  if (GIMP_IS_SOURCE_OPTIONS (stroke->options))
    for (GList *iter = GIMP_SOURCE_OPTIONS (stroke->options)->src_drawables; iter; iter = iter->next)
      if (gimp_item_get_image (GIMP_ITEM (iter->data)) == image) return TRUE;
  return FALSE;
}

GlimsStatus
glims_stroke_component_ready (GlimsEngine *engine, GlimsStrokeID id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  GlimsPlateStorage storage;
  if (!stroke || !stroke->component_stroke) return GLIMS_STATUS_UNSUPPORTED;
  GlimsOpenImage *open = glims_lookup_image (engine, gimp_image_get_id (stroke->image));
  if (!open || open->image != stroke->image || !open->component_document ||
      glims_plate_storage_read (stroke->image, &storage) != GLIMS_PLATE_STORAGE_VALID)
    return GLIMS_STATUS_UNSUPPORTED;
  for (guint i = 0; i < storage.map.count; i++)
    if (GIMP_DRAWABLE (storage.planes[i]) == stroke->drawable) return GLIMS_STATUS_OK;
  return GLIMS_STATUS_UNSUPPORTED;
}

/* The paint info (core and options type) behind a Glims paint tool, or
 * NULL when the engine lacks the tool. */
GimpPaintInfo *
glims_paint_info_for_tool (Gimp    *gimp,
                           uint32_t tool)
{
  if (tool == GLIMS_PAINT_SPONGE_DESATURATE || tool == GLIMS_PAINT_SPONGE_SATURATE)
    return glims_sponge_paint_info (gimp, tool == GLIMS_PAINT_SPONGE_SATURATE);
  if (tool >= G_N_ELEMENTS (paint_infos))
    return NULL;

  return GIMP_PAINT_INFO (gimp_container_get_child_by_name (gimp->paint_info_list,
                                                            paint_infos[tool]));
}

void
glims_strokes_free (gpointer data)
{
  GlimsStroke *stroke = data;

  /* A stroke the app never ended is cancelled, leaving no undo step. */
  if (stroke->core && stroke->drawables)
    {
      gimp_paint_core_cancel (stroke->core, stroke->drawables);
      gimp_paint_core_cleanup (stroke->core);
    }

  if (stroke->core)
    g_signal_handlers_disconnect_matched (stroke->core, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, stroke);
  g_clear_object (&stroke->core);
  g_clear_object (&stroke->options);
  g_list_free (stroke->drawables);
  g_clear_object (&stroke->drawable);
  g_clear_object (&stroke->image);
  g_free (stroke);
}

static GimpCoords
to_coords (const GlimsStrokePoint *point)
{
  GimpCoords coords = GIMP_COORDS_DEFAULT_VALUES;

  coords.x        = point->x;
  coords.y        = point->y;
  coords.pressure = CLAMP (point->pressure, GIMP_COORDS_MIN_PRESSURE, GIMP_COORDS_MAX_PRESSURE);
  coords.xtilt    = CLAMP (point->xtilt, GIMP_COORDS_MIN_TILT, GIMP_COORDS_MAX_TILT);
  coords.ytilt    = CLAMP (point->ytilt, GIMP_COORDS_MIN_TILT, GIMP_COORDS_MAX_TILT);

  return coords;
}

/* Runs on the engine worker. Caller memory may have an arbitrary alignment
 * and stride; only the known prefixes are read into aligned owned storage.
 * No Core call or stroke-state write occurs until this whole copy validates. */
static GlimsStatus
read_stroke_packet_v2 (const GlimsStrokePacketV2  *input,
                       gboolean                    beginning,
                       guint32                     previous_time,
                       GlimsStrokeSampleV2       **samples_out,
                       gsize                      *count_out,
                       char                      **error)
{
  enum { MAX_SAMPLES = 4096, MAX_BYTES = 1024 * 1024 };
  GlimsStrokePacketV2 packet;
  guint32 prefix_size;
  *samples_out = NULL;
  *count_out = 0;
  if (!input) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&prefix_size, input, sizeof prefix_size);
  if (prefix_size < sizeof packet) return GLIMS_STATUS_INVALID_ARGUMENT;
  memcpy (&packet, input, sizeof packet);
  if (packet.sample_stride < sizeof (GlimsStrokeSampleV2) || packet.count > MAX_SAMPLES ||
      packet.count > G_MAXSIZE / packet.sample_stride ||
      packet.byte_count != packet.count * packet.sample_stride || packet.byte_count > MAX_BYTES ||
      (beginning && packet.count != 1))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (!packet.count)
    return packet.samples ? GLIMS_STATUS_INVALID_ARGUMENT : GLIMS_STATUS_OK;
  if (!packet.samples || (uintptr_t) packet.samples > UINTPTR_MAX - packet.byte_count)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  GlimsStrokeSampleV2 *samples = g_try_new (GlimsStrokeSampleV2, packet.count);
  if (!samples) return glims_fail (error, NULL, "The stroke samples could not be copied.");
  const guint8 *bytes = packet.samples;
  const guint32 known_flags = GLIMS_STROKE_SAMPLE_HAS_ROTATION |
                              GLIMS_STROKE_SAMPLE_HAS_TANGENTIAL_PRESSURE;
  gboolean have_previous = !beginning;
  for (gsize i = 0; i < packet.count; i++)
    {
      GlimsStrokeSampleV2 *sample = &samples[i];
      memcpy (&prefix_size, bytes + i * packet.sample_stride, sizeof prefix_size);
      if (prefix_size < sizeof *sample || prefix_size > packet.sample_stride)
        {
          g_free (samples);
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      memcpy (sample, bytes + i * packet.sample_stride, sizeof *sample);
      if ((sample->flags & ~known_flags) || sample->reserved ||
          !isfinite (sample->x) || fabs (sample->x) > 524288 ||
          !isfinite (sample->y) || fabs (sample->y) > 524288 ||
          !isfinite (sample->pressure) || sample->pressure < 0 || sample->pressure > 1 ||
          !isfinite (sample->xtilt) || fabs (sample->xtilt) > 1 ||
          !isfinite (sample->ytilt) || fabs (sample->ytilt) > 1 ||
          !isfinite (sample->rotation_turns) || sample->rotation_turns < 0 || sample->rotation_turns >= 1 ||
          !isfinite (sample->tangential_pressure) || fabs (sample->tangential_pressure) > 1 ||
          (!(sample->flags & GLIMS_STROKE_SAMPLE_HAS_ROTATION) && sample->rotation_turns != 0) ||
          (!(sample->flags & GLIMS_STROKE_SAMPLE_HAS_TANGENTIAL_PRESSURE) && sample->tangential_pressure != 0) ||
          (have_previous && (guint32) (sample->time_ms - previous_time) > 0x7fffffffu))
        {
          g_free (samples);
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      previous_time = sample->time_ms;
      have_previous = TRUE;
    }
  *samples_out = samples;
  *count_out = packet.count;
  return GLIMS_STATUS_OK;
}

static GimpCoords
to_coords_v2 (const GlimsStrokeSampleV2 *sample)
{
  GimpCoords coords = GIMP_COORDS_DEFAULT_VALUES;
  coords.x = sample->x;
  coords.y = sample->y;
  coords.pressure = sample->pressure;
  coords.xtilt = sample->xtilt;
  coords.ytilt = sample->ytilt;
  if (sample->flags & GLIMS_STROKE_SAMPLE_HAS_ROTATION)
    coords.rotation = sample->rotation_turns;
  if (sample->flags & GLIMS_STROKE_SAMPLE_HAS_TANGENTIAL_PRESSURE)
    coords.wheel = (sample->tangential_pressure + 1) / 2;
  return coords;
}

/* Sets a numeric option within its own range; negative means "keep the
 * engine's default". */
static void
set_number (GObject     *options,
            const gchar *property,
            gdouble      value)
{
  GParamSpec *pspec = g_object_class_find_property (G_OBJECT_GET_CLASS (options), property);

  if (value < 0.0 || ! G_IS_PARAM_SPEC_DOUBLE (pspec))
    return;

  g_object_set (options, property,
                CLAMP (value, G_PARAM_SPEC_DOUBLE (pspec)->minimum, G_PARAM_SPEC_DOUBLE (pspec)->maximum),
                NULL);
}

/* The tool's own options, as GIMP's tool options dialogs set them. */
/* Saturation has no meaning on a scalar mask/channel or indexed pixels. */
GlimsStatus
glims_check_sponge_target (GimpDrawable *drawable,
                           const GlimsBrushSettings *brush, char **error)
{
  if (brush->tool != GLIMS_PAINT_SPONGE_DESATURATE &&
      brush->tool != GLIMS_PAINT_SPONGE_SATURATE)
    return GLIMS_STATUS_OK;
  if (!gimp_drawable_is_rgb (drawable))
    {
      if (error) *error = g_strdup ("Sponge requires RGB pixels. Masks, channels, grayscale and indexed pixels are not supported.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  return GLIMS_STATUS_OK;
}

void
glims_set_tool_options (GimpPaintOptions         *options,
                        const GlimsBrushSettings *brush,
                        GimpDrawable             *source)
{
  GObject *object = G_OBJECT (options);

  set_number (object, "brush-hardness", brush->hardness);

  switch (brush->tool)
    {
    case GLIMS_PAINT_AIRBRUSH:
    case GLIMS_PAINT_SMUDGE:
      set_number (object, "rate", brush->rate);
      set_number (object, "flow", brush->flow);
      break;

    case GLIMS_PAINT_BLUR:
    case GLIMS_PAINT_SHARPEN:
      g_object_set (object, "type",
                    brush->tool == GLIMS_PAINT_BLUR ? GIMP_CONVOLVE_BLUR : GIMP_CONVOLVE_SHARPEN,
                    NULL);
      set_number (object, "rate", brush->rate);
      break;

    case GLIMS_PAINT_DODGE:
    case GLIMS_PAINT_BURN:
      g_object_set (object,
                    "type", brush->tool == GLIMS_PAINT_DODGE ? GIMP_DODGE_BURN_TYPE_DODGE
                                                             : GIMP_DODGE_BURN_TYPE_BURN,
                    "mode", brush->tones == GLIMS_TONES_SHADOWS    ? GIMP_TRANSFER_SHADOWS :
                            brush->tones == GLIMS_TONES_HIGHLIGHTS ? GIMP_TRANSFER_HIGHLIGHTS :
                                                                     GIMP_TRANSFER_MIDTONES,
                    NULL);
      set_number (object, "exposure", brush->exposure);
      break;

    case GLIMS_PAINT_ERASER:
      g_object_set (object, "anti-erase", brush->anti_erase ? TRUE : FALSE, NULL);
      break;

    case GLIMS_PAINT_CLONE:
    case GLIMS_PAINT_HEAL:
      {
        GList *sources = g_list_prepend (NULL, source);

        /* "None" alignment: the stroke's first point copies the source
         * point and the source moves with the stroke, as in GIMP's clone
         * tool after a Ctrl-click (app/paint/gimpsourcecore.c). The app
         * keeps any alignment between strokes by choosing the point. */
        g_object_set (object,
                      "src-drawables", sources,
                      "src-x",         (gint) floor (brush->source_x),
                      "src-y",         (gint) floor (brush->source_y),
                      "align-mode",    GIMP_SOURCE_ALIGN_NO,
                      NULL);
        g_list_free (sources);
      }
      break;

    default:
      break;
    }
}

/* `brush_resource` is the stroke's own selected brush, or NULL to inherit
 * the user context's current brush as stroke_begin() always did. */
GimpPaintOptions *
glims_make_paint_options (Gimp                     *gimp,
                          GimpPaintInfo            *info,
                          const GlimsBrushSettings *brush,
                          GimpBrush                *brush_resource)
{
  GimpPaintOptions *options;
  GimpContext      *context;
  GeglColor        *color;
  GimpObject       *dynamics = NULL;

  options = GIMP_PAINT_OPTIONS (gimp_config_duplicate (GIMP_CONFIG (info->paint_options)));
  context = GIMP_CONTEXT (options);

  /* Inherit the paint-relevant settings (brush, gradient, ...) from the user
   * context, as the engine's own stroke procedures do, then pin what the
   * app chose. */
  gimp_context_define_properties (context, GIMP_CONTEXT_PROP_MASK_PAINT, FALSE);
  gimp_context_set_parent (context, gimp_get_user_context (gimp));

  if (brush_resource)
    {
      /* Define the property locally BEFORE assigning it: for an undefined
       * property gimp_context_set_brush() walks up to the parent — here
       * the shared user context, which must never be mutated — and the
       * local definition also shields this stroke from later parent
       * changes. Set on the stroke's own context, the brush is held
       * strongly (g_set_object) for the whole stroke. */
      gimp_context_define_property (context, GIMP_CONTEXT_PROP_BRUSH, TRUE);
      gimp_context_set_brush (context, brush_resource);
    }

  color = gegl_color_new (NULL);
  gegl_color_set_rgba_with_space (color, brush->red, brush->green, brush->blue, 1.0, NULL);
  gimp_context_define_property (context, GIMP_CONTEXT_PROP_FOREGROUND, TRUE);
  gimp_context_set_foreground (context, color);
  g_object_unref (color);

  gimp_context_define_property (context, GIMP_CONTEXT_PROP_OPACITY, TRUE);
  gimp_context_set_opacity (context, CLAMP (brush->opacity, 0.0, 1.0));

  g_object_set (options, "brush-size", brush->size, NULL);

  if (brush->pressure_size)
    dynamics = gimp_container_get_child_by_name (gimp_data_factory_get_container (gimp->dynamics_factory),
                                                 PRESSURE_SIZE_DYNAMICS);
  if (dynamics)
    {
      gimp_context_define_property (context, GIMP_CONTEXT_PROP_DYNAMICS, TRUE);
      gimp_context_set_dynamics (context, GIMP_DYNAMICS (dynamics));
    }
  gimp_paint_options_enable_dynamics (options, dynamics != NULL);
  if (brush->tool == GLIMS_PAINT_SPONGE_DESATURATE || brush->tool == GLIMS_PAINT_SPONGE_SATURATE)
    g_object_set (options, "use-applicator", TRUE, NULL);

  return options;
}

/* The airbrush keeps painting while the pointer rests: its core emits
 * "stamp" from a timer on the engine's main loop, and GIMP's tool answers
 * by painting again at the last point (app/tools/gimpairbrushtool.c). */
static void
airbrush_stamp (GimpAirbrush *airbrush,
                GlimsStroke  *stroke)
{
  gimp_airbrush_stamp (airbrush);
  gimp_image_flush (stroke->image);
}

/* The caller's settings, with the fields its struct_size lacks filled with
 * defaults (an older caller paints with the paintbrush). */
gboolean
glims_read_brush (const GlimsBrushSettings *brush,
                  GlimsBrushSettings       *settings)
{
  if (! brush || brush->struct_size < offsetof (GlimsBrushSettings, tool))
    return FALSE;

  memset (settings, 0, sizeof (*settings));
  memcpy (settings, brush, MIN (brush->struct_size, sizeof (*settings)));

  if (brush->struct_size < sizeof (*settings))
    {
      settings->tool     = GLIMS_PAINT_PAINTBRUSH;
      settings->hardness = -1.0;
      settings->rate     = -1.0;
      settings->flow     = -1.0;
      settings->exposure = -1.0;
    }
  settings->struct_size = sizeof (*settings);

  return settings->tool < G_N_ELEMENTS (paint_infos);
}

static void
drop_stroke_facts (GlimsStrokeCaptureFacts *facts)
{
  g_clear_pointer (&facts->brush_name, g_free);
  g_clear_pointer (&facts->brush_collection, g_free);
  g_clear_pointer (&facts->fingerprint, g_free);
}

static gboolean
recordable_first_point (const GlimsStrokePoint *point)
{
  return point && isfinite (point->x) && fabs (point->x) <= 524288 &&
    isfinite (point->y) && fabs (point->y) <= 524288 &&
    isfinite (point->pressure) && point->pressure >= 0 && point->pressure <= 1 &&
    isfinite (point->xtilt) && fabs (point->xtilt) <= 1 &&
    isfinite (point->ytilt) && fabs (point->ytilt) <= 1;
}

/* Gate the initial deterministic subset. Keep the actual native options
 * rather than assuming that an inherited preset name identifies them. */
static gboolean
capture_stroke_facts (GlimsEngine               *engine,
                      GimpImage                 *image,
                      GimpDrawable              *drawable,
                      const GlimsBrushSettings  *brush,
                      const GlimsStrokePoint    *first,
                      GimpPaintOptions          *options,
                      GlimsStrokeCaptureFacts   *facts)
{
  GimpContext *context = GIMP_CONTEXT (options);
  GimpLayerMode paint_mode = gimp_context_get_paint_mode (context);
  GimpSymmetry *symmetry = gimp_image_get_active_symmetry (image);
  if ((brush->tool != GLIMS_PAINT_PAINTBRUSH &&
       brush->tool != GLIMS_PAINT_PENCIL && brush->tool != GLIMS_PAINT_ERASER) ||
      !recordable_first_point (first) ||
      G_OBJECT_TYPE (drawable) != GIMP_TYPE_LAYER ||
      !gimp_drawable_is_rgb (drawable) || !gimp_drawable_has_alpha (drawable) ||
      gimp_drawable_get_active_mask (drawable) != GIMP_COMPONENT_MASK_ALL ||
      gimp_image_get_floating_selection (image) ||
      !symmetry || G_OBJECT_TYPE (symmetry) != GIMP_TYPE_SYMMETRY ||
      (paint_mode != GIMP_LAYER_MODE_NORMAL && paint_mode != GIMP_LAYER_MODE_NORMAL_LEGACY) ||
      options->expand_use || options->jitter_options->use_jitter ||
      options->smoothing_options->use_smoothing ||
      (options->application_mode != GIMP_PAINT_CONSTANT &&
       options->application_mode != GIMP_PAINT_INCREMENTAL))
    return FALSE;

  g_autofree gchar *dynamics = NULL;
  if (gimp_paint_options_are_dynamics_enabled (options))
    {
      dynamics = glims_stroke_dynamics_fingerprint (TRUE,
                                                   gimp_context_get_dynamics (context));
      if (!dynamics) return FALSE;
    }

  const gdouble values[] = { brush->red, brush->green, brush->blue,
    gimp_context_get_opacity (context), options->brush_size, options->brush_angle,
    options->brush_aspect_ratio, options->brush_spacing, options->brush_hardness,
    options->brush_force };
  for (gsize i = 0; i < G_N_ELEMENTS (values); i++)
    if (!isfinite (values[i]) || (i < 3 && (values[i] < 0 || values[i] > 1)))
      return FALSE;

  GimpBrush *actual = gimp_context_get_brush (context);
  if (!actual) return FALSE;
  gint id = gimp_data_get_id (GIMP_DATA (actual));
  GimpBrush *member = NULL;
  if (id <= 0 || glims_lookup_brush (engine, (GlimsResourceID) id, &member) != GLIMS_STATUS_OK ||
      member != actual)
    return FALSE;
  g_autofree gchar *content = glims_brush_fingerprint (actual);
  if (!content ||
      glims_resource_identifiers (engine, (GlimsResourceID) id, &facts->brush_name,
                                  &facts->brush_collection, &facts->brush_internal,
                                  NULL) != GLIMS_STATUS_OK)
    return FALSE;

  static const gchar domain[] = "glims-stroke-configuration-v1";
  g_autoptr(GChecksum) hash = g_checksum_new (G_CHECKSUM_SHA256);
  g_checksum_update (hash, (const guchar *) domain, sizeof domain);
  g_checksum_update (hash, (const guchar *) content, strlen (content) + 1);
  const guint8 flags[] = { brush->tool == GLIMS_PAINT_ERASER,
    brush->tool == GLIMS_PAINT_ERASER && brush->anti_erase, options->hard != FALSE,
    options->use_applicator != FALSE, options->brush_lock_to_view != FALSE,
    paint_mode == GIMP_LAYER_MODE_NORMAL_LEGACY,
    options->application_mode == GIMP_PAINT_INCREMENTAL };
  g_checksum_update (hash, flags, sizeof flags);
  for (gsize i = 0; i < G_N_ELEMENTS (values); i++)
    {
      gchar number[G_ASCII_DTOSTR_BUF_SIZE];
      g_ascii_dtostr (number, sizeof number, values[i] == 0 ? 0 : values[i]);
      g_checksum_update (hash, (const guchar *) number, strlen (number) + 1);
    }
  /* Keep existing disabled-dynamics recordings byte-compatible. Enabled
   * recordings additionally bind to the actual bounded native config. */
  if (dynamics)
    {
      static const gchar dynamics_domain[] = "glims-stroke-pressure-size-v1";
      g_checksum_update (hash, (const guchar *) dynamics_domain, sizeof dynamics_domain);
      g_checksum_update (hash, (const guchar *) dynamics, strlen (dynamics) + 1);
    }
  /* Keep existing Pencil/Eraser digests unchanged. The added tool must
   * remain distinct even when its effective options match Pencil. */
  if (brush->tool == GLIMS_PAINT_PAINTBRUSH)
    {
      static const gchar paintbrush_domain[] = "glims-stroke-paintbrush-v1";
      const guint8 tool = GLIMS_PAINT_PAINTBRUSH;
      g_checksum_update (hash, (const guchar *) paintbrush_domain, sizeof paintbrush_domain);
      g_checksum_update (hash, &tool, sizeof tool);
    }
  facts->fingerprint = g_strdup (g_checksum_get_string (hash));

  /* Context already owns the values it inherited. Define them locally
   * without running setters that could alter the configured brush links. */
  gimp_context_define_property (context, GIMP_CONTEXT_PROP_BRUSH, TRUE);
  gimp_context_define_property (context, GIMP_CONTEXT_PROP_PAINT_MODE, TRUE);
  return TRUE;
}

/* The one paint-begin path behind stroke_begin and
 * stroke_begin_with_brush_resource: `brush_resource` is the stroke's own
 * selected brush, or NULL to inherit the user context's brush. */
static GlimsStatus
stroke_begin_common (GlimsEngine              *engine,
                     GlimsImageID              image_id,
                     GlimsItemID               layer_id,
                     const GlimsBrushSettings *brush,
                     GimpBrush                *brush_resource,
                     const GlimsStrokePoint   *first,
                     const GimpCoords         *first_coords_v2,
                     GlimsStrokeID            *out,
                     const char               *expected_fingerprint,
                     GlimsStrokeCaptureFacts  *facts,
                     char                    **error)
{
  GlimsOpenImage     *open = glims_lookup_image (engine, image_id);
  GlimsBrushSettings  settings;
  GimpDrawable       *drawable;
  GimpDrawable       *source = NULL;
  GimpPaintInfo      *info;
  GlimsStroke        *stroke;
  GimpCoords          coords;
  GError             *gerror = NULL;
  gint                id;
  GlimsStatus         status;
  uint32_t            locks = GLIMS_LOCK_PIXELS;
  GType               component_type = 0;

  if (out)
    *out = 0;  /* a refused call leaves no stroke id behind */
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! glims_read_brush (brush, &settings) || ! first || ! out || ! (settings.size > 0.0))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  brush = &settings;
  if (engine->busy > 0)
    return GLIMS_STATUS_BUSY;

  drawable = glims_lookup_drawable (open, layer_id);
  if (! drawable)
    return GLIMS_STATUS_NOT_FOUND;
  if (GIMP_IS_GROUP_LAYER (drawable))
    {
      if (error)
        *error = strdup ("Groups cannot be painted on.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (open->component_document)
    {
      GlimsPlateStorage storage;
      gboolean target_valid = FALSE;
      component_type = glims_component_paint_type (brush->tool);
      if (!component_type ||
          glims_plate_storage_read (open->image, &storage) != GLIMS_PLATE_STORAGE_VALID)
        return GLIMS_STATUS_UNSUPPORTED;
      for (guint i = 0; i < storage.map.count; i++)
        if (GIMP_DRAWABLE (storage.planes[i]) == drawable) target_valid = TRUE;
      if (!target_valid) return GLIMS_STATUS_UNSUPPORTED;
      if (!recordable_first_point (first) || !isfinite (brush->size) || brush->size > 10000 ||
          !isfinite (brush->opacity) || brush->opacity < 0 || brush->opacity > 1 ||
          !isfinite (brush->red) || brush->red < 0 || brush->red > 1 ||
          !isfinite (brush->green) || brush->green < 0 || brush->green > 1 ||
          !isfinite (brush->blue) || brush->blue < 0 || brush->blue > 1)
        return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  status = glims_check_sponge_target (drawable, brush, error);
  if (status != GLIMS_STATUS_OK) return status;

  if (brush->tool == GLIMS_PAINT_ERASER && gimp_drawable_has_alpha (drawable))
    locks |= GLIMS_LOCK_ALPHA;
  status = glims_check_item_locks (GIMP_ITEM (drawable), locks, error);
  if (status != GLIMS_STATUS_OK) return status;

  if (brush->tool == GLIMS_PAINT_CLONE || brush->tool == GLIMS_PAINT_HEAL)
    {
      GimpItem *item = gimp_item_get_by_id (engine->gimp, brush->source_drawable);

      if (! GIMP_IS_DRAWABLE (item) || GIMP_IS_GROUP_LAYER (item) || ! gimp_item_is_attached (item))
        return glims_fail (error, NULL, "Choose a source point on a layer first.");
      source = GIMP_DRAWABLE (item);
    }

  info = glims_paint_info_for_tool (engine->gimp, brush->tool);
  if (! info)
    return glims_fail (error, NULL, "The engine lacks this paint tool.");

  stroke = g_new0 (GlimsStroke, 1);
  stroke->image     = g_object_ref (open->image);
  stroke->drawable  = g_object_ref (drawable);
  stroke->options   = glims_make_paint_options (engine->gimp, info, brush, brush_resource);
  stroke->core      = g_object_new (component_type ? component_type : info->paint_type, "undo-desc",
                        brush->tool == GLIMS_PAINT_SPONGE_SATURATE ? "Sponge Saturate" :
                        brush->tool == GLIMS_PAINT_SPONGE_DESATURATE ? "Sponge Desaturate" : info->blurb, NULL);
  stroke->input_version = first_coords_v2 ? GLIMS_STROKE_INPUT_V2 : GLIMS_STROKE_INPUT_V1;
  stroke->last_time_ms = first->time_ms;
  glims_set_tool_options (stroke->options, brush, source);
  stroke->component_stroke = open->component_document;
  if (stroke->component_stroke)
    {
      /* A numeric gray foreground is a direct ink intensity, so 50% gray
       * remains 0.5 in every storage precision. Colored foregrounds use
       * their Rec.709 luma in the same normalized display-RGB coordinates. */
      gfloat intensity = 0.2126 * brush->red + 0.7152 * brush->green + 0.0722 * brush->blue;
      GeglColor *color = gegl_color_new (NULL);
      gegl_color_set_pixel (color, babl_format ("Y float"), &intensity);
      gimp_context_set_foreground (GIMP_CONTEXT (stroke->options), color);
      g_object_unref (color);
    }


  GlimsStrokeCaptureFacts captured = { .struct_size = sizeof captured };
  if (facts && !capture_stroke_facts (engine, open->image, drawable, brush, first, stroke->options, &captured))
    drop_stroke_facts (&captured);
  if (expected_fingerprint && g_strcmp0 (expected_fingerprint, captured.fingerprint))
    {
      drop_stroke_facts (&captured);
      glims_strokes_free (stroke);
      return glims_fail (error, NULL, "The recorded brush or paint configuration changed.");
    }

  if (GIMP_IS_AIRBRUSH (stroke->core))
    g_signal_connect (stroke->core, "stamp", G_CALLBACK (airbrush_stamp), stroke);

  coords = first_coords_v2 ? *first_coords_v2 : to_coords (first);
  stroke->drawables = g_list_prepend (NULL, drawable);

  if (! gimp_paint_core_start (stroke->core, stroke->drawables, stroke->options, &coords, &gerror))
    {
      g_list_free (stroke->drawables);
      stroke->drawables = NULL;
      glims_strokes_free (stroke);
      drop_stroke_facts (&captured);
      return glims_fail (error, gerror, "The stroke could not start.");
    }

  stroke->core->last_coords = coords;
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_INIT, first->time_ms);
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_MOTION, first->time_ms);
  gimp_image_flush (open->image);

  id = glims_next_session_id (engine);
  g_hash_table_insert (engine->strokes, GINT_TO_POINTER (id), stroke);
  *out = id;
  if (facts && captured.fingerprint)
    {
      facts->brush_internal = captured.brush_internal;
      facts->brush_name = captured.brush_name;
      facts->brush_collection = captured.brush_collection;
      facts->fingerprint = captured.fingerprint;
    }

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_stroke_begin (GlimsEngine              *engine,
                    GlimsImageID              image_id,
                    GlimsItemID               layer_id,
                    const GlimsBrushSettings *brush,
                    const GlimsStrokePoint   *first,
                    GlimsStrokeID            *out,
                    char                    **error)
{
  return stroke_begin_common (engine, image_id, layer_id, brush, NULL, first, NULL, out, NULL, NULL, error);
}

GlimsStatus
glims_stroke_begin_with_brush_resource (GlimsEngine              *engine,
                                        GlimsImageID              image_id,
                                        GlimsItemID               layer_id,
                                        GlimsResourceID           brush_id,
                                        const GlimsBrushSettings *brush,
                                        const GlimsStrokePoint   *first,
                                        GlimsStrokeID            *out,
                                        char                    **error)
{
  GimpBrush   *resource = NULL;
  GlimsStatus  status;

  if (! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *out = 0;

  /* Resolved once, here at begin, on the engine thread: the stroke keeps
   * exactly this brush for its whole life, whatever the caller's settings
   * or the shared user context become later. */
  status = glims_lookup_brush (engine, brush_id, &resource);
  if (status != GLIMS_STATUS_OK)
    {
      if (error)
        *error = strdup (status == GLIMS_STATUS_INVALID_ARGUMENT
                         ? "This handle cannot name a brush."
                         : "This brush is no longer in the engine's brush factory.");
      return status;
    }

  return stroke_begin_common (engine, image_id, layer_id, brush, resource, first, NULL, out, NULL, NULL, error);
}

GlimsStatus
glims_stroke_begin_with_capture_facts (GlimsEngine               *engine,
                                       GlimsImageID               image_id,
                                       GlimsItemID                layer_id,
                                       GlimsResourceID            brush_id,
                                       const GlimsBrushSettings  *brush,
                                       const GlimsStrokePoint    *first,
                                       const char                *expected_fingerprint,
                                       GlimsStrokeID             *out,
                                       GlimsStrokeCaptureFacts   *facts,
                                       char                     **error)
{
  GimpBrush *resource = NULL;
  if (expected_fingerprint)
    {
      if (!brush_id || strnlen (expected_fingerprint, 65) != 64)
        return GLIMS_STATUS_INVALID_ARGUMENT;
      for (gsize i = 0; i < 64; i++)
        if (!g_ascii_isdigit (expected_fingerprint[i]) &&
            (expected_fingerprint[i] < 'a' || expected_fingerprint[i] > 'f'))
          return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (brush_id)
    {
      GlimsStatus status = glims_lookup_brush (engine, brush_id, &resource);
      if (status != GLIMS_STATUS_OK)
        return status;
    }
  return stroke_begin_common (engine, image_id, layer_id, brush, resource, first, NULL, out,
                              expected_fingerprint, facts, error);
}

GlimsStatus
glims_stroke_begin_v2 (GlimsEngine                *engine,
                       GlimsImageID                image,
                       GlimsItemID                 drawable,
                       GlimsResourceID             brush_id,
                       const GlimsBrushSettings   *brush,
                       const GlimsStrokePacketV2  *packet,
                       GlimsStrokeID              *out,
                       char                      **error)
{
  GlimsStrokeSampleV2 *samples = NULL;
  gsize count;
  if (out) *out = 0;
  if (!out) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsStatus status = read_stroke_packet_v2 (packet, TRUE, 0, &samples, &count, error);
  if (status != GLIMS_STATUS_OK) return status;

  GimpBrush *resource = NULL;
  if (brush_id)
    status = glims_lookup_brush (engine, brush_id, &resource);
  else
    resource = gimp_context_get_brush (gimp_get_user_context (engine->gimp));
  if (status != GLIMS_STATUS_OK || !resource)
    {
      g_free (samples);
      if (status != GLIMS_STATUS_OK) return status;
      return glims_fail (error, NULL, "Choose an available brush before painting.");
    }
  /* Zero chooses the actual inherited brush at press; options then own it
   * locally just like an explicit resource. V1's inheritance is unchanged. */
  g_object_ref (resource);
  const GlimsStrokeSampleV2 *p = samples;
  GlimsStrokePoint first = {p->x, p->y, p->pressure, p->xtilt, p->ytilt, p->time_ms};
  GimpCoords coords = to_coords_v2 (p);
  status = stroke_begin_common (engine, image, drawable, brush, resource, &first, &coords,
                                out, NULL, NULL, error);
  g_object_unref (resource);
  g_free (samples);
  return status;
}

GlimsStatus
glims_stroke_continue (GlimsEngine            *engine,
                       GlimsStrokeID           id,
                       const GlimsStrokePoint *points,
                       size_t                  count)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  size_t       i;

  if (! stroke)
    return GLIMS_STATUS_NOT_FOUND;
  if (stroke->input_version != GLIMS_STROKE_INPUT_V1)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (count > 0 && ! points)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  if (stroke->component_stroke)
    {
      if (count > 65536) return GLIMS_STATUS_INVALID_ARGUMENT;
      for (i = 0; i < count; i++)
        if (!recordable_first_point (&points[i])) return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  for (i = 0; i < count; i++)
    {
      GimpCoords coords = to_coords (&points[i]);

      gimp_paint_core_interpolate (stroke->core, stroke->drawables, stroke->options,
                                   &coords, points[i].time_ms);
    }

  gimp_image_flush (stroke->image);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_stroke_continue_v2 (GlimsEngine               *engine,
                          GlimsStrokeID              id,
                          const GlimsStrokePacketV2 *packet,
                          char                     **error)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  GlimsStrokeSampleV2 *samples = NULL;
  gsize count;
  if (!stroke) return GLIMS_STATUS_NOT_FOUND;
  if (stroke->input_version != GLIMS_STROKE_INPUT_V2) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsStatus status = read_stroke_packet_v2 (packet, FALSE, stroke->last_time_ms, &samples, &count, error);
  if (status != GLIMS_STATUS_OK || !count) return status;
  for (gsize i = 0; i < count; i++)
    {
      GimpCoords coords = to_coords_v2 (&samples[i]);
      gimp_paint_core_interpolate (stroke->core, stroke->drawables, stroke->options,
                                   &coords, samples[i].time_ms);
    }
  stroke->last_time_ms = samples[count - 1].time_ms;
  g_free (samples);
  gimp_image_flush (stroke->image);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_stroke_end (GlimsEngine   *engine,
                  GlimsStrokeID  id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));

  if (! stroke)
    return GLIMS_STATUS_NOT_FOUND;

  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_FINISH, 0);
  gimp_paint_core_finish (stroke->core, stroke->drawables, TRUE);
  gimp_paint_core_cleanup (stroke->core);
  gimp_image_flush (stroke->image);

  /* Finished: nothing for the free function to cancel. */
  g_list_free (stroke->drawables);
  stroke->drawables = NULL;
  g_hash_table_remove (engine->strokes, GINT_TO_POINTER (id));

  return GLIMS_STATUS_OK;
}
