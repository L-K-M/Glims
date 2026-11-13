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
#include "lab-brush-core.h"
#include "lab-layer-brush-core.h"
#include "lab-layer-brush-facts.h"
#include "lab-layer-storage.h"
#include "lab-transform.h"
#include "lab-fill.h"

#include <math.h>
#include <stddef.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpchannel.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpdrawable.h"
#include "core/gimpdynamics.h"
#include "core/gimpgrouplayer.h"
#include "core/gimpimage.h"
#include "core/gimpimage-symmetry.h"
#include "core/gimpimage-undo.h"
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
  gboolean         lab_stroke;
  gboolean         lab_layer_stroke;
  gboolean         lab_layer_dispatching;
  gboolean         lab_layer_require_empty_selection;
  GimpLayer        *lab_layer_root;
  guint8           lab_layer_uuid[16];
  GlimsLabBrushSettings lab;
  guint32          lab_storage;
  gboolean         ink_capture_stroke;
  GlimsInkStrokeTarget ink_target;
  guint32          ink_storage;
} GlimsStroke;

gboolean
glims_stroke_is_lab (GlimsEngine *engine, GlimsStrokeID id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  return stroke && (stroke->lab_stroke || stroke->lab_layer_stroke);
}

gboolean
glims_typed_strokes_for_image (GlimsEngine *engine, GimpImage *image,
                              GlimsTypedStrokeAction action)
{
  GHashTableIter iter;
  gpointer value;
  gboolean found = FALSE;
  g_hash_table_iter_init (&iter, engine->strokes);
  while (g_hash_table_iter_next (&iter, NULL, &value))
    {
      GlimsStroke *stroke = value;
      if ((stroke->lab_stroke || stroke->lab_layer_stroke || stroke->ink_capture_stroke) && stroke->image == image)
        {
          found = TRUE;
          if (action == GLIMS_TYPED_STROKES_CANCEL)
            {
              if (stroke->lab_layer_stroke) stroke->lab_layer_dispatching = TRUE;
              g_hash_table_iter_remove (&iter);
            }
        }
    }
  return found;
}

gboolean
glims_stroke_is_ink (GlimsEngine *engine, GlimsStrokeID id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  return stroke && stroke->ink_capture_stroke;
}

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
      !glims_plate_storage_read_open (open, &storage))
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
      /* Native cancel returns before thawing an untouched drawable. */
      if ((stroke->lab_stroke || stroke->lab_layer_stroke || stroke->ink_capture_stroke) &&
          (stroke->core->x1 == stroke->core->x2 || stroke->core->y1 == stroke->core->y2))
        gimp_paint_core_finish (stroke->core, stroke->drawables, FALSE);
      else
        gimp_paint_core_cancel (stroke->core, stroke->drawables);
      gimp_paint_core_cleanup (stroke->core);
    }

  /* GIMP 7addd2b77's finish releases this reference, but cancel/cleanup and
   * finalization do not. Cancelled strokes must not retain the selection. */
  if (stroke->core)
    g_clear_object (&stroke->core->mask_buffer);

  if (stroke->core)
    g_signal_handlers_disconnect_matched (stroke->core, G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, stroke);
  g_clear_object (&stroke->core);
  g_clear_object (&stroke->options);
  g_list_free (stroke->drawables);
  g_clear_object (&stroke->drawable);
  g_clear_object (&stroke->lab_layer_root);
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

static gboolean valid_lab_expected_fingerprint (const gchar *fingerprint);

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
                      const GlimsInkStrokeTarget *ink,
                      GlimsStrokeCaptureFacts   *facts)
{
  GimpContext *context = GIMP_CONTEXT (options);
  GimpLayerMode paint_mode = gimp_context_get_paint_mode (context);
  GimpSymmetry *symmetry = gimp_image_get_active_symmetry (image);
  if ((brush->tool != GLIMS_PAINT_PAINTBRUSH &&
       brush->tool != GLIMS_PAINT_PENCIL && brush->tool != GLIMS_PAINT_ERASER) ||
      !recordable_first_point (first) ||
      (ink ? (brush->tool == GLIMS_PAINT_ERASER || !GIMP_IS_CHANNEL (drawable)) :
             (G_OBJECT_TYPE (drawable) != GIMP_TYPE_LAYER ||
              !gimp_drawable_is_rgb (drawable) || !gimp_drawable_has_alpha (drawable) ||
              gimp_drawable_get_active_mask (drawable) != GIMP_COMPONENT_MASK_ALL)) ||
      gimp_image_get_floating_selection (image) ||
      !symmetry || G_OBJECT_TYPE (symmetry) != GIMP_TYPE_SYMMETRY ||
      (!ink && paint_mode != GIMP_LAYER_MODE_NORMAL && paint_mode != GIMP_LAYER_MODE_NORMAL_LEGACY) ||
      options->expand_use || options->jitter_options->use_jitter ||
      options->smoothing_options->use_smoothing ||
      (!ink && options->application_mode != GIMP_PAINT_CONSTANT &&
       options->application_mode != GIMP_PAINT_INCREMENTAL))
    return FALSE;

  g_autofree gchar *dynamics = NULL;
  if (gimp_paint_options_are_dynamics_enabled (options))
    {
      dynamics = glims_stroke_dynamics_fingerprint (TRUE,
                                                   gimp_context_get_dynamics (context));
      if (!dynamics) return FALSE;
    }

  /* Component painting uses this raw binary32 intensity, not three RGB
   * samples. Preserve the legacy RGB fingerprint bytes exactly. */
  gfloat ink_intensity = .2126 * brush->red + .7152 * brush->green + .0722 * brush->blue;
  const gdouble values[] = { ink ? ink_intensity : brush->red,
    ink ? 0 : brush->green, ink ? 0 : brush->blue,
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

  const gchar *domain = ink ? "glims-ink-stroke-configuration-v1" : "glims-stroke-configuration-v1";
  g_autoptr(GChecksum) hash = g_checksum_new (G_CHECKSUM_SHA256);
  g_checksum_update (hash, (const guchar *) domain, strlen (domain) + 1);
  if (ink)
    {
      const guint8 identity[] = { ink->color_mode, ink->role };
      g_checksum_update (hash, identity, sizeof identity);
    }
  g_checksum_update (hash, (const guchar *) content, strlen (content) + 1);
  const guint8 flags[] = { brush->tool == GLIMS_PAINT_ERASER,
    brush->tool == GLIMS_PAINT_ERASER && brush->anti_erase, options->hard != FALSE,
    options->use_applicator != FALSE, options->brush_lock_to_view != FALSE,
    !ink && paint_mode == GIMP_LAYER_MODE_NORMAL_LEGACY,
    !ink && options->application_mode == GIMP_PAINT_INCREMENTAL };
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

/* The selected authoritative plane is checked again before every accepted
 * continuation and End. UUIDs are meaningful only inside this owning image. */
static GlimsStatus
ink_stroke_target_ready (GlimsEngine *engine, GlimsImageID image,
                         const GlimsInkStrokeTarget *target,
                         GimpDrawable *expected_drawable, gint expected_storage,
                         guint32 *storage_kind, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, image);
  GlimsPlateStorage storage;
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (!glims_plate_storage_read_open (open, &storage) ||
      (storage.map.mode != GLIMS_PLATE_MODE_CMYK && storage.map.mode != GLIMS_PLATE_MODE_MULTICHANNEL))
    return GLIMS_STATUS_UNSUPPORTED;
  guint32 mode = storage.map.mode == GLIMS_PLATE_MODE_CMYK
                ? GLIMS_COLOR_MODE_CMYK : GLIMS_COLOR_MODE_MULTICHANNEL;
  if (target->channel <= 0 || target->color_mode != mode ||
      (expected_storage >= 0 && storage.map.storage != (guint32) expected_storage))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GimpDrawable *drawable = NULL;
  for (guint i = 0; i < storage.map.count; i++)
    if (gimp_item_get_id (GIMP_ITEM (storage.planes[i])) == target->channel)
      {
        guint32 role = mode == GLIMS_COLOR_MODE_CMYK ? GLIMS_INK_ROLE_CYAN + i : GLIMS_INK_ROLE_UNSPECIFIED;
        if (target->role != role || memcmp (target->uuid, storage.map.entries[i].uuid, 16))
          return GLIMS_STATUS_INVALID_ARGUMENT;
        drawable = GIMP_DRAWABLE (storage.planes[i]);
        break;
      }
  GList *selected = gimp_image_get_selected_channels (open->image);
  if (!drawable || (expected_drawable && drawable != expected_drawable) ||
      !selected || selected->next || selected->data != drawable)
    {
      if (error) *error = g_strdup ("The selected ink channel changed. The stroke was cancelled.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (!gimp_image_undo_is_enabled (open->image) || gimp_image_get_undo_group_count (open->image))
    return GLIMS_STATUS_BUSY;
  GlimsStatus status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status == GLIMS_STATUS_OK && storage_kind) *storage_kind = storage.map.storage;
  return status;
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
                     const GlimsInkStrokeTarget *ink_target,
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
  guint32 ink_storage = 0;
  if (ink_target)
    {
      status = ink_stroke_target_ready (engine, image_id, ink_target, NULL, -1, &ink_storage, error);
      if (status != GLIMS_STATUS_OK) return status;
    }

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
  if (ink_target)
    {
      stroke->ink_capture_stroke = TRUE;
      stroke->ink_target = *ink_target;
      stroke->ink_storage = ink_storage;
    }
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
  if (facts && !capture_stroke_facts (engine, open->image, drawable, brush, first, stroke->options, ink_target, &captured))
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
  return stroke_begin_common (engine, image_id, layer_id, brush, NULL, first, NULL, out, NULL, NULL, NULL, error);
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

  return stroke_begin_common (engine, image_id, layer_id, brush, resource, first, NULL, out, NULL, NULL, NULL, error);
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
                              expected_fingerprint, facts, NULL, error);
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
                                out, NULL, NULL, NULL, error);
  g_object_unref (resource);
  g_free (samples);
  return status;
}

static GlimsStatus
lab_stroke_target_ready (GlimsEngine *engine, GlimsStroke *stroke, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, gimp_image_get_id (stroke->image));
  GlimsPlateStorage storage;
  if (!open || open->image != stroke->image ||
      !glims_plate_storage_read_open (open, &storage) ||
      storage.map.mode != GLIMS_PLATE_MODE_LAB || storage.map.count != 3 ||
      storage.map.storage != stroke->lab_storage || stroke->lab.role > GLIMS_LAB_AXIS_B ||
      GIMP_DRAWABLE (storage.planes[stroke->lab.role]) != stroke->drawable ||
      memcmp (storage.map.entries[stroke->lab.role].uuid, stroke->lab.uuid, 16))
    {
      if (error) *error = g_strdup ("The Lab brush target changed. The stroke was cancelled.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  GList *selected = gimp_image_get_selected_channels (stroke->image);
  if (!selected || selected->next || selected->data != stroke->drawable)
    {
      if (error) *error = g_strdup ("The selected Lab axis changed. The stroke was cancelled.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (!gimp_image_undo_is_enabled (stroke->image) || gimp_image_get_undo_group_count (stroke->image))
    return GLIMS_STATUS_BUSY;
  return glims_check_item_locks (GIMP_ITEM (stroke->drawable), GLIMS_LOCK_PIXELS, error);
}

GlimsStatus
glims_stroke_cancel_lab (GlimsEngine *engine, GlimsStrokeID id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  if (!stroke) return GLIMS_STATUS_NOT_FOUND;
  if (!stroke->lab_stroke) return GLIMS_STATUS_UNSUPPORTED;
  GimpImage *image = g_object_ref (stroke->image);
  g_hash_table_remove (engine->strokes, GINT_TO_POINTER (id));
  gimp_image_flush (image);
  g_object_unref (image);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
lab_layer_stroke_target_ready (GlimsEngine *engine, GlimsStroke *stroke, char **error)
{
  GlimsOpenImage *open = glims_lookup_image (engine, gimp_image_get_id (stroke->image));
  g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
  if (!storage) return GLIMS_STATUS_FAILED;
  if (!open || open->image != stroke->image ||
      open->component_layout != GLIMS_COMPONENT_LAYOUT_LAYERED_LAB ||
      glims_lab_layer_storage_read (stroke->image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    goto changed;
  guint index = 0;
  for (; index < storage->map.count; index++)
    if (storage->layers[index].group == stroke->lab_layer_root) break;
  if (index == storage->map.count || storage->layers[index].map_index >= storage->map.count ||
      memcmp (storage->map.entries[storage->layers[index].map_index].group, stroke->lab_layer_uuid, 16))
    goto changed;
  GList *selected = gimp_image_get_selected_layers (stroke->image);
  if (!selected || selected->next || selected->data != stroke->lab_layer_root) goto changed;
  if (stroke->lab_layer_require_empty_selection &&
      (!gimp_image_get_mask (stroke->image) || !gimp_channel_is_empty (gimp_image_get_mask (stroke->image))))
    {
      if (error) *error = g_strdup ("The selection changed. The Lab brush stroke was cancelled.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  GList *plane = stroke->drawables;
  for (guint i = 0; i < 4; i++, plane = plane ? plane->next : NULL)
    if (!plane || plane->data != storage->layers[index].planes[i]) goto changed;
  if (plane) goto changed;
  if (engine->busy || engine->progress || glims_filters_active_for_image (engine, stroke->image) ||
      !gimp_image_undo_is_enabled (stroke->image) || gimp_image_get_undo_group_count (stroke->image))
    {
      if (error) *error = g_strdup ("Finish the current operation before painting this layer.");
      return GLIMS_STATUS_BUSY;
    }
  return GLIMS_STATUS_OK;
changed:
  if (error) *error = g_strdup ("The Lab brush target changed. The stroke was cancelled.");
  return GLIMS_STATUS_INVALID_ARGUMENT;
}

static void
emit_lab_layer_brush_damage (GlimsEngine *engine, GlimsStroke *stroke)
{
  GeglRectangle damage;
  if (glims_lab_layer_brush_core_take_damage (stroke->core, &damage))
    glims_emit (engine, GLIMS_EVENT_PROJECTION_CHANGED, stroke->image, &damage, NULL);
}

GlimsStatus
glims_stroke_cancel_lab_layer (GlimsEngine *engine, GlimsStrokeID id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  if (!stroke) return GLIMS_STATUS_NOT_FOUND;
  if (!stroke->lab_layer_stroke) return GLIMS_STATUS_UNSUPPORTED;
  if (stroke->lab_layer_dispatching) return GLIMS_STATUS_BUSY;
  GimpImage *image = g_object_ref (stroke->image);
  GeglRectangle damage = { stroke->core->x1, stroke->core->y1,
                           stroke->core->x2 - stroke->core->x1,
                           stroke->core->y2 - stroke->core->y1 };
  stroke->lab_layer_dispatching = TRUE;
  engine->busy++;
  g_hash_table_remove (engine->strokes, GINT_TO_POINTER (id));
  gimp_image_flush (image);
  if (damage.width > 0 && damage.height > 0)
    glims_emit (engine, GLIMS_EVENT_PROJECTION_CHANGED, image, &damage, NULL);
  engine->busy--;
  g_object_unref (image);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_stroke_begin_lab_layer (GlimsEngine *engine, GlimsImageID image_id,
                              GlimsResourceID brush_id, const GlimsLabLayerBrushSettings *settings,
                              const GlimsStrokePacketV2 *packet, GlimsStrokeID *out,
                              gboolean pressure_size, gboolean require_empty_selection,
                              const char *expected_fingerprint, GlimsStrokeCaptureFacts *facts, char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if ((facts && facts->struct_size < sizeof *facts) || (expected_fingerprint && !facts) ||
      (expected_fingerprint && (!brush_id || !valid_lab_expected_fingerprint (expected_fingerprint))))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (!settings || !out || settings->struct_size < sizeof *settings) return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsLabLayerBrushSettings request = *settings;
  const double components[] = { request.color.red, request.color.green, request.color.blue,
                                request.color.alpha, request.opacity, request.hardness };
  guint8 zero_uuid[16] = { 0 };
  if (request.root <= 0 || !memcmp (request.uuid, zero_uuid, sizeof zero_uuid) ||
      !isfinite (request.size) || request.size < 1 || request.size > 10000)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  for (guint i = 0; i < G_N_ELEMENTS (components); i++)
    if (!isfinite (components[i]) || components[i] < 0 || components[i] > 1)
      return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, image_id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (engine->progress || !gimp_image_undo_is_enabled (open->image) ||
      gimp_image_get_undo_group_count (open->image)) return GLIMS_STATUS_BUSY;
  if (open->component_layout != GLIMS_COMPONENT_LAYOUT_LAYERED_LAB) return GLIMS_STATUS_UNSUPPORTED;
  g_autofree GlimsLabLayerStorage *storage = g_try_new0 (GlimsLabLayerStorage, 1);
  if (!storage) return GLIMS_STATUS_FAILED;
  if (glims_lab_layer_storage_read (open->image, storage) != GLIMS_LAB_LAYER_STORAGE_VALID)
    return GLIMS_STATUS_UNSUPPORTED;
  guint index = 0;
  for (; index < storage->map.count; index++)
    if (gimp_item_get_id (GIMP_ITEM (storage->layers[index].group)) == request.root) break;
  if (index == storage->map.count) return GLIMS_STATUS_NOT_FOUND;
  guint map_index = storage->layers[index].map_index;
  if (map_index >= storage->map.count || memcmp (storage->map.entries[map_index].group, request.uuid, 16))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GimpLayer *root = storage->layers[index].group;
  GList *selected = gimp_image_get_selected_layers (open->image);
  if (!selected || selected->next || selected->data != root) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (require_empty_selection &&
      (!gimp_image_get_mask (open->image) || !gimp_channel_is_empty (gimp_image_get_mask (open->image))))
    return glims_fail (error, NULL, "Deselect the image before recording or replaying this Lab brush.");
  GimpSymmetry *symmetry = gimp_image_get_active_symmetry (open->image);
  if (!symmetry || G_OBJECT_TYPE (symmetry) != GIMP_TYPE_SYMMETRY) return GLIMS_STATUS_UNSUPPORTED;

  const double encoded[] = { request.color.red, request.color.green, request.color.blue };
  float linear[3], lab[3];
  for (guint i = 0; i < 3; i++)
    linear[i] = (float) (encoded[i] <= 0.04045 ? encoded[i] / 12.92 : pow ((encoded[i] + 0.055) / 1.055, 2.4));
  GlimsLabTransform *transform = glims_lab_transform_new ();
  if (!transform) return GLIMS_STATUS_FAILED;
  gboolean converted = glims_lab_transform_from_linear_rgb (transform, linear, 1, lab);
  glims_lab_transform_free (transform);
  if (!converted) return GLIMS_STATUS_FAILED;

  GlimsStrokeSampleV2 *samples = NULL;
  gsize count = 0;
  status = read_stroke_packet_v2 (packet, TRUE, 0, &samples, &count, error);
  if (status != GLIMS_STATUS_OK) return status;
  GimpBrush *brush = NULL;
  if (brush_id) status = glims_lookup_brush (engine, brush_id, &brush);
  else brush = gimp_context_get_brush (gimp_get_user_context (engine->gimp));
  GimpPaintInfo *info = glims_paint_info_for_tool (engine->gimp, GLIMS_PAINT_PAINTBRUSH);
  if (status != GLIMS_STATUS_OK || !brush || !info)
    {
      g_free (samples);
      return status != GLIMS_STATUS_OK ? status :
        glims_fail (error, NULL, "Choose an available mask brush before painting.");
    }
  GlimsBrushSettings geometry = { .struct_size = sizeof geometry,
    .size = request.size, .opacity = request.opacity, .tool = GLIMS_PAINT_PAINTBRUSH,
    .hardness = request.hardness, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStroke *stroke = g_new0 (GlimsStroke, 1);
  stroke->image = g_object_ref (open->image);
  stroke->drawable = g_object_ref (GIMP_DRAWABLE (storage->layers[index].planes[0]));
  stroke->lab_layer_root = g_object_ref (root);
  memcpy (stroke->lab_layer_uuid, request.uuid, 16);
  stroke->lab_layer_stroke = TRUE;
  stroke->lab_layer_require_empty_selection = require_empty_selection;
  stroke->component_stroke = TRUE;
  stroke->input_version = GLIMS_STROKE_INPUT_V2;
  stroke->last_time_ms = samples[0].time_ms;
  stroke->options = glims_make_paint_options (engine->gimp, info, &geometry, brush);
  g_object_set (stroke->options, "use-applicator", FALSE,
    "brush-spacing", .15, "brush-angle", 0.0, "brush-aspect-ratio", 0.0,
    "brush-hardness", request.hardness, "brush-force", .5,
    "brush-lock-to-view", FALSE, "application-mode", GIMP_PAINT_CONSTANT,
    "expand-use", FALSE, NULL);
  stroke->options->jitter_options->use_jitter = FALSE;
  stroke->options->smoothing_options->use_smoothing = FALSE;
  if (pressure_size && !glims_lab_layer_brush_enable_pressure_size (stroke->options))
    {
      g_free (samples);
      glims_strokes_free (stroke);
      return glims_fail (error, NULL, "The Lab brush pressure settings could not be created.");
    }
  if (!pressure_size) gimp_paint_options_enable_dynamics (stroke->options, FALSE);
  gimp_context_define_property (GIMP_CONTEXT (stroke->options), GIMP_CONTEXT_PROP_PAINT_MODE, TRUE);
  gimp_context_set_paint_mode (GIMP_CONTEXT (stroke->options), GIMP_LAYER_MODE_NORMAL);
  GlimsStrokeCaptureFacts captured = { .struct_size = sizeof captured };
  if (facts && !glims_lab_layer_brush_capture_facts (engine, open->image, stroke->options,
                                                     &request, &captured))
    drop_stroke_facts (&captured);
  g_autofree gchar *captured_name = captured.brush_name;
  g_autofree gchar *captured_collection = captured.brush_collection;
  g_autofree gchar *captured_fingerprint = captured.fingerprint;
  if (expected_fingerprint && g_strcmp0 (expected_fingerprint, captured.fingerprint))
    {
      g_free (samples);
      glims_strokes_free (stroke);
      return glims_fail (error, NULL, "The recorded Lab layer brush or configuration changed.");
    }
  stroke->core = glims_lab_layer_brush_core_new (CLAMP ((double)lab[0], 0, 100),
    CLAMP ((double)lab[1], -128, 127), CLAMP ((double)lab[2], -128, 127),
    request.opacity * request.color.alpha);
  if (!stroke->core) { g_free (samples); glims_strokes_free (stroke); return GLIMS_STATUS_FAILED; }
  for (guint i = 0; i < 4; i++) stroke->drawables = g_list_append (stroke->drawables, storage->layers[index].planes[i]);
  GimpCoords coords = to_coords_v2 (&samples[0]);
  g_free (samples);
  GError *native_error = NULL;
  /* Native painting emits synchronous signals. Prevent reentrant close or
   * mutation while a stroke is not yet registered, then revalidate the
   * selected root before publishing the new handle. */
  engine->busy++;
  if (!gimp_paint_core_start (stroke->core, stroke->drawables, stroke->options, &coords, &native_error))
    {
      g_list_free (stroke->drawables); stroke->drawables = NULL;
      gimp_paint_core_cleanup (stroke->core);
      glims_strokes_free (stroke);
      engine->busy--;
      return glims_fail (error, native_error, "The Lab layer brush could not start.");
    }
  if (require_empty_selection &&
      (!gimp_image_get_mask (open->image) || !gimp_channel_is_empty (gimp_image_get_mask (open->image))))
    {
      glims_strokes_free (stroke);
      gimp_image_flush (open->image);
      engine->busy--;
      return glims_fail (error, NULL, "The selection changed before the Lab brush began.");
    }
  stroke->core->last_coords = coords;
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options, GIMP_PAINT_STATE_INIT, stroke->last_time_ms);
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options, GIMP_PAINT_STATE_MOTION, stroke->last_time_ms);
  engine->busy--;
  const char *failure = glims_lab_layer_brush_core_error (stroke->core);
  if (failure)
    {
      if (error) *error = g_strdup (failure);
      engine->busy++;
      glims_strokes_free (stroke);
      gimp_image_flush (open->image);
      engine->busy--;
      return GLIMS_STATUS_FAILED;
    }
  status = lab_layer_stroke_target_ready (engine, stroke, error);
  if (status != GLIMS_STATUS_OK)
    {
      engine->busy++;
      glims_strokes_free (stroke);
      gimp_image_flush (open->image);
      engine->busy--;
      return status;
    }
  gint id = glims_next_session_id (engine);
  g_hash_table_insert (engine->strokes, GINT_TO_POINTER (id), stroke);
  stroke->lab_layer_dispatching = TRUE;
  engine->busy++;
  gimp_image_flush (open->image);
  emit_lab_layer_brush_damage (engine, stroke);
  engine->busy--;
  stroke->lab_layer_dispatching = FALSE;
  status = lab_layer_stroke_target_ready (engine, stroke, error);
  if (status != GLIMS_STATUS_OK)
    { glims_stroke_cancel_lab_layer (engine, id); return status; }
  *out = id;
  if (facts)
    {
      captured.struct_size = facts->struct_size;
      *facts = captured;
      g_steal_pointer (&captured_name);
      g_steal_pointer (&captured_collection);
      g_steal_pointer (&captured_fingerprint);
    }
  return GLIMS_STATUS_OK;
}

static gboolean
clear_lab_stroke_facts (GlimsStrokeCaptureFacts *facts)
{
  if (!facts)
    return FALSE;
  size_t size = facts->struct_size;
  if (size >= offsetof (GlimsStrokeCaptureFacts, brush_internal) + sizeof facts->brush_internal)
    facts->brush_internal = FALSE;
  if (size >= offsetof (GlimsStrokeCaptureFacts, brush_name) + sizeof facts->brush_name)
    facts->brush_name = NULL;
  if (size >= offsetof (GlimsStrokeCaptureFacts, brush_collection) + sizeof facts->brush_collection)
    facts->brush_collection = NULL;
  if (size < offsetof (GlimsStrokeCaptureFacts, fingerprint) + sizeof facts->fingerprint)
    return FALSE;
  facts->fingerprint = NULL;
  return TRUE;
}

static gboolean
valid_lab_expected_fingerprint (const gchar *fingerprint)
{
  if (strnlen (fingerprint, 65) != 64)
    return FALSE;
  for (gsize i = 0; i < 64; i++)
    if (!g_ascii_isxdigit (fingerprint[i]) || g_ascii_isupper (fingerprint[i]))
      return FALSE;
  return TRUE;
}

static void
hash_lab_double (GChecksum *hash, gdouble value)
{
  gchar number[G_ASCII_DTOSTR_BUF_SIZE];
  /* Preserve physical signed zero in the captured configuration. */
  g_ascii_dtostr (number, sizeof number, value);
  g_checksum_update (hash, (const guchar *) number, strlen (number) + 1);
}

static gboolean
capture_lab_stroke_facts (GlimsEngine            *engine,
                          GimpImage              *image,
                          GimpPaintOptions       *options,
                          const GlimsLabBrushSettings *lab,
                          guint32                 storage,
                          GlimsStrokeCaptureFacts *facts)
{
  GimpContext *context = GIMP_CONTEXT (options);
  GimpLayerMode paint_mode = gimp_context_get_paint_mode (context);
  GimpSymmetry *symmetry = gimp_image_get_active_symmetry (image);
  if (!symmetry || G_OBJECT_TYPE (symmetry) != GIMP_TYPE_SYMMETRY ||
      paint_mode != GIMP_LAYER_MODE_NORMAL ||
      options->expand_use || options->jitter_options->use_jitter ||
      options->smoothing_options->use_smoothing ||
      options->application_mode != GIMP_PAINT_CONSTANT ||
      options->use_applicator || options->brush_lock_to_view ||
      gimp_paint_options_are_dynamics_enabled (options))
    return FALSE;

  GimpBrush *brush = gimp_context_get_brush (context);
  if (!brush)
    return FALSE;
  gint id = gimp_data_get_id (GIMP_DATA (brush));
  GimpBrush *member = NULL;
  if (id <= 0 ||
      glims_lookup_brush (engine, (GlimsResourceID) id, &member) != GLIMS_STATUS_OK ||
      member != brush)
    return FALSE;
  g_autofree gchar *content = glims_brush_fingerprint (brush);
  if (!content ||
      glims_resource_identifiers (engine, (GlimsResourceID) id, &facts->brush_name,
                                  &facts->brush_collection, &facts->brush_internal,
                                  NULL) != GLIMS_STATUS_OK)
    return FALSE;

  static const gchar domain[] = "glims-lab-stroke-configuration-v1";
  g_autoptr(GChecksum) hash = g_checksum_new (G_CHECKSUM_SHA256);
  g_checksum_update (hash, (const guchar *) domain, sizeof domain);
  g_checksum_update (hash, (const guchar *) content, strlen (content) + 1);
  const gdouble values[] = {
    options->brush_size, gimp_context_get_opacity (context),
    options->brush_hardness, options->brush_spacing,
    options->brush_angle, options->brush_aspect_ratio,
    options->brush_force, lab->value, lab->opacity
  };
  for (gsize i = 0; i < G_N_ELEMENTS (values); i++)
    {
      if (!isfinite (values[i]))
        return FALSE;
      hash_lab_double (hash, values[i]);
    }
  const guint8 flags[] = {
    options->hard != FALSE, options->use_applicator != FALSE,
    options->brush_lock_to_view != FALSE, options->expand_use != FALSE,
    paint_mode == GIMP_LAYER_MODE_NORMAL_LEGACY,
    options->application_mode != GIMP_PAINT_CONSTANT
  };
  g_checksum_update (hash, flags, sizeof flags);
  const guint8 lab_fields[] = { (guint8) lab->role, (guint8) storage };
  g_checksum_update (hash, lab_fields, sizeof lab_fields);

  facts->fingerprint = g_strdup (g_checksum_get_string (hash));
  gimp_context_define_property (context, GIMP_CONTEXT_PROP_BRUSH, TRUE);
  gimp_context_define_property (context, GIMP_CONTEXT_PROP_PAINT_MODE, TRUE);
  return TRUE;
}

static GlimsStatus
stroke_begin_lab_common (GlimsEngine *engine, GlimsImageID image_id,
                         GlimsResourceID brush_id, const GlimsLabBrushSettings *settings,
                         const GlimsStrokePacketV2 *packet,
                         const char *expected_fingerprint,
                         GlimsStrokeID *out, GlimsStrokeCaptureFacts *facts, char **error)
{
  gboolean facts_ready = clear_lab_stroke_facts (facts);
  GlimsStrokeCaptureFacts captured = { .struct_size = sizeof captured };

  if (out) *out = 0;
  if (error) *error = NULL;
  if ((facts && !facts_ready) || (expected_fingerprint && !facts))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (expected_fingerprint && (!brush_id || !valid_lab_expected_fingerprint (expected_fingerprint)))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (!out || !settings || settings->struct_size < sizeof *settings)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  const GlimsLabBrushSettings lab = *settings;
  if (lab.axis <= 0 || lab.role > GLIMS_LAB_AXIS_B ||
      !isfinite (lab.value) || !isfinite (lab.opacity) || lab.opacity < 0 || lab.opacity > 1 ||
      !isfinite (lab.size) || lab.size < 1 || lab.size > 10000 ||
      !isfinite (lab.hardness) || lab.hardness < 0 || lab.hardness > 1)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  GlimsOpenImage *open = glims_lookup_image (engine, image_id);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (!gimp_image_undo_is_enabled (open->image) || gimp_image_get_undo_group_count (open->image))
    return GLIMS_STATUS_BUSY;
  GlimsPlateStorage storage;
  if (!glims_plate_storage_read_open (open, &storage) ||
      storage.map.mode != GLIMS_PLATE_MODE_LAB || storage.map.count != 3)
    return GLIMS_STATUS_UNSUPPORTED;
  GimpDrawable *drawable = GIMP_DRAWABLE (storage.planes[lab.role]);
  if (gimp_item_get_id (GIMP_ITEM (drawable)) != lab.axis ||
      memcmp (storage.map.entries[lab.role].uuid, lab.uuid, 16))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GList *selected = gimp_image_get_selected_channels (open->image);
  if (!selected || selected->next || selected->data != drawable)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  status = glims_check_item_locks (GIMP_ITEM (drawable), GLIMS_LOCK_PIXELS, error);
  if (status != GLIMS_STATUS_OK) return status;
  GimpSymmetry *symmetry = gimp_image_get_active_symmetry (open->image);
  if (!symmetry || G_OBJECT_TYPE (symmetry) != GIMP_TYPE_SYMMETRY)
    return GLIMS_STATUS_UNSUPPORTED;
  const GlimsLabRole roles[] = { GLIMS_LAB_ROLE_L, GLIMS_LAB_ROLE_A, GLIMS_LAB_ROLE_B };
  GlimsLabFormat format;
  switch (storage.map.storage)
    {
    case GLIMS_PLATE_STORAGE_U8: format = GLIMS_LAB_FORMAT_U8; break;
    case GLIMS_PLATE_STORAGE_U16: format = GLIMS_LAB_FORMAT_U16; break;
    case GLIMS_PLATE_STORAGE_FLOAT: format = GLIMS_LAB_FORMAT_FLOAT; break;
    default: return GLIMS_STATUS_UNSUPPORTED;
    }
  bool ignored;
  if (!glims_lab_fill_row (roles[lab.role], format, lab.value, lab.opacity,
                            0, NULL, NULL, NULL, &ignored))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  GlimsStrokeSampleV2 *samples = NULL;
  gsize count = 0;
  status = read_stroke_packet_v2 (packet, TRUE, 0, &samples, &count, error);
  if (status != GLIMS_STATUS_OK) return status;

  GimpBrush *brush = NULL;
  if (brush_id)
    status = glims_lookup_brush (engine, brush_id, &brush);
  else
    brush = gimp_context_get_brush (gimp_get_user_context (engine->gimp));
  GimpPaintInfo *info = glims_paint_info_for_tool (engine->gimp, GLIMS_PAINT_PAINTBRUSH);
  if (status != GLIMS_STATUS_OK || !brush || !info)
    {
      g_free (samples);
      return status != GLIMS_STATUS_OK ? status :
        glims_fail (error, NULL, "Choose an available mask brush before painting.");
    }

  GlimsBrushSettings geometry = { .struct_size = sizeof geometry,
    .size = lab.size, .opacity = lab.opacity, .tool = GLIMS_PAINT_PAINTBRUSH,
    .hardness = lab.hardness, .rate = -1, .flow = -1, .exposure = -1 };
  GlimsStroke *stroke = g_new0 (GlimsStroke, 1);
  stroke->image = g_object_ref (open->image);
  stroke->drawable = g_object_ref (drawable);
  stroke->lab_stroke = TRUE;
  stroke->component_stroke = TRUE;
  stroke->lab = lab;
  stroke->lab_storage = storage.map.storage;
  stroke->input_version = GLIMS_STROKE_INPUT_V2;
  stroke->last_time_ms = samples[0].time_ms;
  stroke->options = glims_make_paint_options (engine->gimp, info, &geometry, brush);
  g_object_set (stroke->options, "use-applicator", FALSE,
    "brush-spacing", .15, "brush-angle", 0.0, "brush-aspect-ratio", 0.0,
    "brush-hardness", lab.hardness, "brush-force", .5,
    "brush-lock-to-view", FALSE, "application-mode", GIMP_PAINT_CONSTANT,
    "expand-use", FALSE, NULL);
  stroke->options->jitter_options->use_jitter = FALSE;
  stroke->options->smoothing_options->use_smoothing = FALSE;
  gimp_paint_options_enable_dynamics (stroke->options, FALSE);
  gimp_context_define_property (GIMP_CONTEXT (stroke->options), GIMP_CONTEXT_PROP_PAINT_MODE, TRUE);
  gimp_context_set_paint_mode (GIMP_CONTEXT (stroke->options), GIMP_LAYER_MODE_NORMAL);

  if (facts && !capture_lab_stroke_facts (engine, open->image, stroke->options,
                                          &lab, storage.map.storage, &captured))
    drop_stroke_facts (&captured);
  if (expected_fingerprint && g_strcmp0 (expected_fingerprint, captured.fingerprint))
    {
      drop_stroke_facts (&captured);
      g_free (samples);
      glims_strokes_free (stroke);
      return glims_fail (error, NULL, "The recorded Lab brush or configuration changed.");
    }

  stroke->core = glims_lab_brush_core_new (roles[lab.role], format, lab.value, lab.opacity);
  stroke->drawables = g_list_prepend (NULL, drawable);
  GimpCoords coords = to_coords_v2 (&samples[0]);
  g_free (samples);
  GError *native_error = NULL;
  if (!gimp_paint_core_start (stroke->core, stroke->drawables, stroke->options, &coords, &native_error))
    {
      /* Start did not reach native preview freeze. Cleanup without a thaw. */
      drop_stroke_facts (&captured);
      g_list_free (stroke->drawables);
      stroke->drawables = NULL;
      gimp_paint_core_cleanup (stroke->core);
      glims_strokes_free (stroke);
      return glims_fail (error, native_error, "The Lab brush stroke could not start.");
    }
  stroke->core->last_coords = coords;
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_INIT, stroke->last_time_ms);
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_MOTION, stroke->last_time_ms);
  const char *failure = glims_lab_brush_core_error (stroke->core);
  if (failure)
    {
      drop_stroke_facts (&captured);
      if (error) *error = g_strdup (failure);
      glims_strokes_free (stroke);
      gimp_image_flush (open->image);
      return GLIMS_STATUS_FAILED;
    }

  gint id = glims_next_session_id (engine);
  g_hash_table_insert (engine->strokes, GINT_TO_POINTER (id), stroke);
  *out = id;
  if (facts && captured.fingerprint)
    {
      facts->brush_internal = captured.brush_internal;
      facts->brush_name = captured.brush_name;
      facts->brush_collection = captured.brush_collection;
      facts->fingerprint = captured.fingerprint;
    }
  else
    {
      drop_stroke_facts (&captured);
    }
  gimp_image_flush (open->image);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_stroke_begin_lab (GlimsEngine *engine, GlimsImageID image_id,
                        GlimsResourceID brush_id, const GlimsLabBrushSettings *settings,
                        const GlimsStrokePacketV2 *packet, GlimsStrokeID *out, char **error)
{
  return stroke_begin_lab_common (engine, image_id, brush_id, settings, packet,
                                  NULL, out, NULL, error);
}

GlimsStatus
glims_stroke_begin_lab_with_capture_facts (GlimsEngine *engine, GlimsImageID image_id,
                        GlimsResourceID brush_id, const GlimsLabBrushSettings *settings,
                        const GlimsStrokePacketV2 *packet, const char *expected_fingerprint,
                        GlimsStrokeID *out, GlimsStrokeCaptureFacts *facts, char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if (!facts) return GLIMS_STATUS_INVALID_ARGUMENT;
  return stroke_begin_lab_common (engine, image_id, brush_id, settings, packet,
                                  expected_fingerprint, out, facts, error);
}

GlimsStatus
glims_stroke_begin_ink_with_capture_facts (GlimsEngine *engine, GlimsImageID image,
    GlimsResourceID brush_id, const GlimsInkStrokeTarget *target,
    const GlimsBrushSettings *settings, const GlimsStrokePacketV2 *packet,
    const char *expected_fingerprint, GlimsStrokeID *out,
    GlimsStrokeCaptureFacts *facts, char **error)
{
  if (out) *out = 0;
  if (error) *error = NULL;
  if (!clear_lab_stroke_facts (facts) || !out || !target ||
      target->struct_size < sizeof *target || !settings || settings->struct_size < sizeof *settings)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (settings->tool != GLIMS_PAINT_PAINTBRUSH && settings->tool != GLIMS_PAINT_PENCIL)
    return GLIMS_STATUS_UNSUPPORTED;
  if (expected_fingerprint && (!brush_id || !valid_lab_expected_fingerprint (expected_fingerprint)))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  GlimsOpenImage *open = glims_lookup_image (engine, image);
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  GlimsStatus status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK) return status;
  status = ink_stroke_target_ready (engine, image, target, NULL, -1, NULL, error);
  if (status != GLIMS_STATUS_OK) return status;

  GlimsStrokeSampleV2 *samples = NULL;
  gsize count = 0;
  status = read_stroke_packet_v2 (packet, TRUE, 0, &samples, &count, error);
  if (status != GLIMS_STATUS_OK) return status;
  GimpBrush *resource = NULL;
  if (brush_id)
    status = glims_lookup_brush (engine, brush_id, &resource);
  else
    resource = gimp_context_get_brush (gimp_get_user_context (engine->gimp));
  if (status != GLIMS_STATUS_OK || !resource)
    {
      g_free (samples);
      return status != GLIMS_STATUS_OK ? status :
        glims_fail (error, NULL, "Choose an available brush before painting.");
    }
  g_object_ref (resource);
  const GlimsStrokeSampleV2 *p = samples;
  GlimsStrokePoint first = { p->x, p->y, p->pressure, p->xtilt, p->ytilt, p->time_ms };
  GimpCoords coords = to_coords_v2 (p);
  status = stroke_begin_common (engine, image, target->channel, settings, resource,
                                &first, &coords, out, expected_fingerprint, facts, target, error);
  g_object_unref (resource);
  g_free (samples);
  return status;
}

GlimsStatus
glims_stroke_cancel_ink (GlimsEngine *engine, GlimsStrokeID id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));
  if (!stroke) return GLIMS_STATUS_NOT_FOUND;
  if (!stroke->ink_capture_stroke) return GLIMS_STATUS_UNSUPPORTED;
  GimpImage *image = g_object_ref (stroke->image);
  g_hash_table_remove (engine->strokes, GINT_TO_POINTER (id));
  gimp_image_flush (image);
  g_object_unref (image);
  return GLIMS_STATUS_OK;
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
  if (stroke->lab_layer_stroke && stroke->lab_layer_dispatching) return GLIMS_STATUS_BUSY;
  GlimsStatus status = read_stroke_packet_v2 (packet, FALSE, stroke->last_time_ms, &samples, &count, error);
  if (status != GLIMS_STATUS_OK) return status;
  if (stroke->lab_stroke)
    {
      status = lab_stroke_target_ready (engine, stroke, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_free (samples);
          glims_stroke_cancel_lab (engine, id);
          return status;
        }
    }
  if (stroke->lab_layer_stroke)
    {
      status = lab_layer_stroke_target_ready (engine, stroke, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_free (samples);
          glims_stroke_cancel_lab_layer (engine, id);
          return status;
        }
    }
  if (stroke->ink_capture_stroke)
    {
      status = ink_stroke_target_ready (engine, gimp_image_get_id (stroke->image),
        &stroke->ink_target, stroke->drawable, stroke->ink_storage, NULL, error);
      if (status != GLIMS_STATUS_OK)
        {
          g_free (samples);
          glims_stroke_cancel_ink (engine, id);
          return status;
        }
    }
  if (!count) return GLIMS_STATUS_OK;
  if (stroke->lab_layer_stroke)
    { stroke->lab_layer_dispatching = TRUE; engine->busy++; }
  for (gsize i = 0; i < count; i++)
    {
      GimpCoords coords = to_coords_v2 (&samples[i]);
      gimp_paint_core_interpolate (stroke->core, stroke->drawables, stroke->options,
                                   &coords, samples[i].time_ms);
      if (stroke->lab_stroke && glims_lab_brush_core_error (stroke->core))
        {
          if (error) *error = g_strdup (glims_lab_brush_core_error (stroke->core));
          g_free (samples);
          glims_stroke_cancel_lab (engine, id);
          return GLIMS_STATUS_FAILED;
        }
      if (stroke->lab_layer_stroke && glims_lab_layer_brush_core_error (stroke->core))
        {
          if (error) *error = g_strdup (glims_lab_layer_brush_core_error (stroke->core));
          g_free (samples);
          engine->busy--;
          stroke->lab_layer_dispatching = FALSE;
          glims_stroke_cancel_lab_layer (engine, id);
          return GLIMS_STATUS_FAILED;
        }
    }
  stroke->last_time_ms = samples[count - 1].time_ms;
  g_free (samples);
  gimp_image_flush (stroke->image);
  if (stroke->lab_layer_stroke)
    {
      emit_lab_layer_brush_damage (engine, stroke);
      engine->busy--;
      stroke->lab_layer_dispatching = FALSE;
      status = lab_layer_stroke_target_ready (engine, stroke, error);
      if (status != GLIMS_STATUS_OK)
        { glims_stroke_cancel_lab_layer (engine, id); return status; }
    }
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_stroke_end (GlimsEngine   *engine,
                  GlimsStrokeID  id)
{
  GlimsStroke *stroke = g_hash_table_lookup (engine->strokes, GINT_TO_POINTER (id));

  if (! stroke)
    return GLIMS_STATUS_NOT_FOUND;
  if (stroke->lab_layer_stroke && stroke->lab_layer_dispatching)
    return GLIMS_STATUS_BUSY;

  if (stroke->ink_capture_stroke)
    {
      GlimsStatus status = ink_stroke_target_ready (engine, gimp_image_get_id (stroke->image),
        &stroke->ink_target, stroke->drawable, stroke->ink_storage, NULL, NULL);
      if (status != GLIMS_STATUS_OK)
        {
          glims_stroke_cancel_ink (engine, id);
          return status;
        }
    }
  if (stroke->lab_stroke)
    {
      GlimsStatus status = lab_stroke_target_ready (engine, stroke, NULL);
      if (status != GLIMS_STATUS_OK || glims_lab_brush_core_error (stroke->core))
        {
          glims_stroke_cancel_lab (engine, id);
          return status != GLIMS_STATUS_OK ? status : GLIMS_STATUS_FAILED;
        }
    }
  if (stroke->lab_layer_stroke)
    {
      GlimsStatus status = lab_layer_stroke_target_ready (engine, stroke, NULL);
      if (status != GLIMS_STATUS_OK || glims_lab_layer_brush_core_error (stroke->core))
        {
          glims_stroke_cancel_lab_layer (engine, id);
          return status != GLIMS_STATUS_OK ? status : GLIMS_STATUS_FAILED;
        }
    }
  gboolean layer_stroke = stroke->lab_layer_stroke;
  if (layer_stroke) { stroke->lab_layer_dispatching = TRUE; engine->busy++; }
  gimp_paint_core_paint (stroke->core, stroke->drawables, stroke->options,
                         GIMP_PAINT_STATE_FINISH, 0);
  gimp_paint_core_finish (stroke->core, stroke->drawables, TRUE);
  gimp_paint_core_cleanup (stroke->core);
  gimp_image_flush (stroke->image);

  /* Finished: nothing for the free function to cancel. */
  g_list_free (stroke->drawables);
  stroke->drawables = NULL;
  g_hash_table_remove (engine->strokes, GINT_TO_POINTER (id));
  if (layer_stroke) engine->busy--;

  return GLIMS_STATUS_OK;
}
