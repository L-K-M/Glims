/*
 * Image color state and conversions: the color model, precision and
 * effective color profile the engine reports, and the mode and
 * precision conversions. The conversions are single validated calls
 * into GIMP's own GUI-free core (app/core/gimpimage-convert-type.c,
 * app/core/gimpimage-convert-precision.c), which open their own undo
 * group, so each is exactly one undo step; everything the core would
 * refuse is validated before the call, so a refused call mutates
 * nothing. Runs on the engine thread.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include <cairo.h>

#include "gegl/gimp-babl.h"
#include "libgimpcolor/gimpcolor.h"

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-convert-indexed.h"
#include "core/gimpimage-convert-precision.h"
#include "core/gimpimage-convert-type.h"
#include "core/gimpitem.h"
#include "core/gimpitemstack.h"
#include "core/gimppalette.h"
#include "text/gimptextlayer.h"
#if GIMP_CHECK_VERSION (3, 2, 0)
#include "path/gimpvectorlayer.h"
#include "core/gimplinklayer.h"
#endif

/* ---- Facade <-> engine enum mapping ------------------------------------ */
/* The engine's enum values never cross the facade; these switches are
 * the only place they meet. */

static uint32_t
facade_mode (GimpImageBaseType type)
{
  switch (type)
    {
    case GIMP_RGB:     return GLIMS_COLOR_MODE_RGB;
    case GIMP_GRAY:    return GLIMS_COLOR_MODE_GRAYSCALE;
    case GIMP_INDEXED: return GLIMS_COLOR_MODE_INDEXED;
    default:           return GLIMS_COLOR_MODE_UNKNOWN;
    }
}

/* The engine base type of a facade mode, or FALSE for an unknown value.
 * GIMP_INDEXED is reported as unsupported by the caller: converting to
 * indexed needs a palette and dither policy, a later slice. */
static gboolean
engine_mode (uint32_t           mode,
             GimpImageBaseType *type)
{
  switch (mode)
    {
    case GLIMS_COLOR_MODE_RGB:       *type = GIMP_RGB;  return TRUE;
    case GLIMS_COLOR_MODE_GRAYSCALE: *type = GIMP_GRAY; return TRUE;
    default:                                            return FALSE;
    }
}

static uint32_t
facade_component (GimpComponentType type)
{
  switch (type)
    {
    case GIMP_COMPONENT_TYPE_U8:     return GLIMS_COLOR_COMPONENT_U8;
    case GIMP_COMPONENT_TYPE_U16:    return GLIMS_COLOR_COMPONENT_U16;
    case GIMP_COMPONENT_TYPE_U32:    return GLIMS_COLOR_COMPONENT_U32;
    case GIMP_COMPONENT_TYPE_HALF:   return GLIMS_COLOR_COMPONENT_HALF;
    case GIMP_COMPONENT_TYPE_FLOAT:  return GLIMS_COLOR_COMPONENT_FLOAT;
    case GIMP_COMPONENT_TYPE_DOUBLE: return GLIMS_COLOR_COMPONENT_DOUBLE;
    default:                         return GLIMS_COLOR_COMPONENT_UNKNOWN;
    }
}

static gboolean
engine_component (uint32_t           component,
                  GimpComponentType *type)
{
  switch (component)
    {
    case GLIMS_COLOR_COMPONENT_U8:     *type = GIMP_COMPONENT_TYPE_U8;     return TRUE;
    case GLIMS_COLOR_COMPONENT_U16:    *type = GIMP_COMPONENT_TYPE_U16;    return TRUE;
    case GLIMS_COLOR_COMPONENT_U32:    *type = GIMP_COMPONENT_TYPE_U32;    return TRUE;
    case GLIMS_COLOR_COMPONENT_HALF:   *type = GIMP_COMPONENT_TYPE_HALF;   return TRUE;
    case GLIMS_COLOR_COMPONENT_FLOAT:  *type = GIMP_COMPONENT_TYPE_FLOAT;  return TRUE;
    case GLIMS_COLOR_COMPONENT_DOUBLE: *type = GIMP_COMPONENT_TYPE_DOUBLE; return TRUE;
    default:                                                          return FALSE;
    }
}

static uint32_t
facade_trc (GimpTRCType trc)
{
  switch (trc)
    {
    case GIMP_TRC_LINEAR:     return GLIMS_COLOR_TRC_LINEAR;
    case GIMP_TRC_NON_LINEAR: return GLIMS_COLOR_TRC_NONLINEAR;
    case GIMP_TRC_PERCEPTUAL: return GLIMS_COLOR_TRC_PERCEPTUAL;
    default:                  return GLIMS_COLOR_TRC_UNKNOWN;
    }
}

static gboolean
engine_trc (uint32_t     trc,
            GimpTRCType *type)
{
  switch (trc)
    {
    case GLIMS_COLOR_TRC_LINEAR:     *type = GIMP_TRC_LINEAR;     return TRUE;
    case GLIMS_COLOR_TRC_NONLINEAR:  *type = GIMP_TRC_NON_LINEAR; return TRUE;
    case GLIMS_COLOR_TRC_PERCEPTUAL: *type = GIMP_TRC_PERCEPTUAL; return TRUE;
    default:                                                   return FALSE;
    }
}

/* ---- Color state -------------------------------------------------------- */

GlimsStatus
glims_image_color_info (GlimsEngine   *engine,
                        GlimsImageID   id,
                        GlimsColorInfo *info)
{
  GlimsOpenImage   *open = glims_lookup_image (engine, id);
  GimpImage        *image;
  GimpPrecision     precision;
  GimpColorProfile *profile;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! info)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  image     = open->image;
  precision = gimp_image_get_precision (image);

  memset (info, 0, sizeof (*info));
  info->mode      = facade_mode (gimp_image_get_base_type (image));
  info->component = facade_component (gimp_babl_component_type (precision));
  info->trc       = facade_trc (gimp_babl_trc (precision));

  /* Embedded means an ICC profile parasite travels with the image (and
   * so with its files); the label is the effective profile's — the
   * image's own when it has one, the engine's builtin fallback for its
   * model otherwise. Both getters return borrowed profiles: reading
   * metadata must not release the image's profile. */
  info->profile_embedded = gimp_image_get_icc_parasite (image) != NULL;
  profile = gimp_image_get_color_profile (image);
  if (! profile)
    profile = gimp_image_get_builtin_color_profile (image);
  if (profile)
    {
      const gchar *label = gimp_color_profile_get_label (profile);

      if (label)
        g_strlcpy (info->profile_label, label, sizeof (info->profile_label));
    }

  return GLIMS_STATUS_OK;
}

/* ---- Mode conversion ---------------------------------------------------- */

GlimsStatus
glims_image_convert_mode (GlimsEngine  *engine,
                          GlimsImageID  id,
                          uint32_t      mode,
                          char        **error)
{
  GlimsOpenImage   *open = glims_lookup_image (engine, id);
  GimpImageBaseType new_type;
  GlimsStatus       status;
  GError           *gerror = NULL;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  if (mode == GLIMS_COLOR_MODE_INDEXED)
    {
      /* Indexed needs palette and dither policy; the dedicated call
       * takes it. gimp_image_convert_type refuses the target itself. */
      if (error)
        *error = strdup ("Converting to indexed goes through image_convert_indexed, "
                         "which takes the palette and dither settings.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (! engine_mode (mode, &new_type))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* A no-op changes nothing and pushes no undo step; the core call
   * would refuse it. */
  if (new_type == gimp_image_get_base_type (open->image))
    return GLIMS_STATUS_OK;

  /* One validated core conversion. A NULL dest_profile leaves the
   * profile choice to the core, which picks the builtin profile of the
   * new model when grayscale is involved; assigning or converting the
   * profile itself is a later slice. The core opens its own undo group
   * (Convert Image to RGB / Grayscale), so the whole call is one undo
   * step and cannot leave a partial change behind. */
  if (! gimp_image_convert_type (open->image, new_type, NULL, NULL, &gerror))
    return glims_fail (error, gerror, "The image could not be converted.");

  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

/* ---- Precision conversion ------------------------------------------------ */

GlimsStatus
glims_image_convert_precision (GlimsEngine  *engine,
                               GlimsImageID  id,
                               uint32_t      component,
                               uint32_t      trc,
                               char        **error)
{
  GlimsOpenImage    *open = glims_lookup_image (engine, id);
  GimpComponentType  comp;
  GimpTRCType        trc_type;
  GimpPrecision      precision;
  GlimsStatus        status;

  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! engine_component (component, &comp) || ! engine_trc (trc, &trc_type))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  precision = gimp_babl_precision (comp, trc_type);

  /* The combinations the engine actually accepts: every component/TRC
   * pair for RGB and grayscale, only u8 non-linear for indexed
   * (gimp_babl_is_valid). */
  if (! gimp_babl_is_valid (gimp_image_get_base_type (open->image), precision))
    {
      if (error)
        *error = strdup ("Indexed images keep 8-bit non-linear precision.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* A no-op changes nothing and pushes no undo step; the core call
   * would refuse it. */
  if (precision == gimp_image_get_precision (open->image))
    return GLIMS_STATUS_OK;

  /* One validated core conversion with no dithering, as one undo step
   * (the core's own undo group, "Convert Image to <precision>"). */
  gimp_image_convert_precision (open->image, precision,
                                GEGL_DITHER_NONE, GEGL_DITHER_NONE, GEGL_DITHER_NONE,
                                NULL);
  gimp_image_flush (open->image);

  return GLIMS_STATUS_OK;
}

/* ---- Indexed conversion ------------------------------------------------- */

static gboolean
indexed_palette (uint32_t               value,
                 GimpConvertPaletteType *type)
{
  switch (value)
    {
    case GLIMS_INDEXED_PALETTE_GENERATED: *type = GIMP_CONVERT_PALETTE_GENERATE; return TRUE;
    case GLIMS_INDEXED_PALETTE_WEB:       *type = GIMP_CONVERT_PALETTE_WEB;      return TRUE;
    case GLIMS_INDEXED_PALETTE_MONO:      *type = GIMP_CONVERT_PALETTE_MONO;     return TRUE;
    case GLIMS_INDEXED_PALETTE_CUSTOM:    *type = GIMP_CONVERT_PALETTE_CUSTOM;   return TRUE;
    default:                                                                   return FALSE;
    }
}

static gboolean
indexed_dither (uint32_t              value,
                GimpConvertDitherType *type)
{
  switch (value)
    {
    case GLIMS_INDEXED_DITHER_NONE:         *type = GIMP_CONVERT_DITHER_NONE;        return TRUE;
    case GLIMS_INDEXED_DITHER_FS:           *type = GIMP_CONVERT_DITHER_FS;          return TRUE;
    case GLIMS_INDEXED_DITHER_FS_LOW_BLEED: *type = GIMP_CONVERT_DITHER_FS_LOWBLEED; return TRUE;
    case GLIMS_INDEXED_DITHER_FIXED:        *type = GIMP_CONVERT_DITHER_FIXED;       return TRUE;
    default:                                                                       return FALSE;
    }
}

/* Genuine editable layers the indexed conversion would rasterize:
 * vector and link layers always (the core's quantize path runs for
 * every non-text layer, and their set_buffer rasterizes), a text layer
 * only when `dither_text` makes it take the same path — with it off the
 * core re-renders the text in indexed format instead and it stays
 * editable (gimpimage-convert-indexed.c:1054-1099, plus the
 * gimptextlayer/gimpvectorlayer/gimplinklayer set_buffer overrides). */
static gboolean
has_indexed_rasterize_targets (GimpImage *image,
                               gboolean   dither_text)
{
  GList    *layers = gimp_image_get_layer_list (image);
  GList    *iter;
  gboolean  found  = FALSE;

  for (iter = layers; iter; iter = iter->next)
    {
      GimpItem *item = GIMP_ITEM (iter->data);

      if (
#if GIMP_CHECK_VERSION (3, 2, 0)
          gimp_item_is_vector_layer (item) || gimp_item_is_link_layer (item) ||
#endif
          (dither_text && gimp_item_is_text_layer (item)))
        {
          found = TRUE;
          break;
        }
    }
  g_list_free (layers);
  return found;
}

GlimsStatus
glims_image_convert_indexed (GlimsEngine                 *engine,
                             GlimsImageID                 id,
                             const GlimsIndexedSettings  *settings,
                             const GlimsColor            *colors,
                             int32_t                      color_count,
                             char                       **error)
{
  GlimsOpenImage         *open = glims_lookup_image (engine, id);
  GimpImage              *image;
  GimpConvertPaletteType  palette;
  GimpConvertDitherType   dither;
  GimpPalette            *custom = NULL;
  GlimsStatus             status;
  GError                 *gerror = NULL;
  gboolean                ok;

  /* Whole-input validation before anything is touched; every refusal
   * below leaves pixels and history alone. */
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;
  if (! settings || settings->struct_size < sizeof (GlimsIndexedSettings) ||
      ! indexed_palette (settings->palette, &palette) ||
      ! indexed_dither (settings->dither, &dither) ||
      (settings->preservation != GLIMS_INDEXED_PRESERVE_EDITABLE &&
       settings->preservation != GLIMS_INDEXED_ALLOW_RASTERIZE))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (palette == GIMP_CONVERT_PALETTE_GENERATE &&
      (settings->max_colors < 2 || settings->max_colors > MAXNUMCOLORS))
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (palette == GIMP_CONVERT_PALETTE_CUSTOM)
    {
      int32_t i;

      if (! colors || color_count < 1 || color_count > MAXNUMCOLORS)
        return GLIMS_STATUS_INVALID_ARGUMENT;
      /* The custom palette holds opaque colors only (the native colormap
       * carries no per-entry alpha); non-opaque is refused, not clamped. */
      for (i = 0; i < color_count; i++)
        if (! isfinite (colors[i].red)   || colors[i].red   < 0.0 || colors[i].red   > 1.0 ||
            ! isfinite (colors[i].green) || colors[i].green < 0.0 || colors[i].green > 1.0 ||
            ! isfinite (colors[i].blue)  || colors[i].blue  < 0.0 || colors[i].blue  > 1.0 ||
            colors[i].alpha != 1.0)
          return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  image = open->image;

  /* Converting an indexed image is a history-free no-op; the core
   * refuses it with no GError. */
  if (gimp_image_get_base_type (image) == GIMP_INDEXED)
    return GLIMS_STATUS_OK;

  /* The engine's own gates (image-actions.c: the menu item is
   * sensitive iff !groups && u8-gamma; the PDB invoker checks the flat
   * stack): indexed allows only 8-bit non-linear precision and never
   * runs on a stack containing a group — the core's loop has no group
   * guard and would treat the group drawable like a layer. */
  if (gimp_image_get_precision (image) != GIMP_PRECISION_U8_NON_LINEAR)
    {
      if (error)
        *error = strdup ("Indexed color needs 8-bit non-linear precision; "
                         "convert the precision first.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (! gimp_item_stack_is_flat (GIMP_ITEM_STACK (gimp_image_get_layers (image))))
    {
      if (error)
        *error = strdup ("Indexed color needs a flat layer stack; "
                         "merge or ungroup the layer groups first.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  if (settings->preservation == GLIMS_INDEXED_PRESERVE_EDITABLE &&
      has_indexed_rasterize_targets (image, settings->dither_text))
    {
      if (error)
        *error = strdup ("Converting to indexed would turn editable vector, link or "
                         "dithered text layers into pixels; convert with "
                         "allow-rasterize consent instead.");
      return GLIMS_STATUS_REQUIRES_RASTERIZE;
    }

  /* A private palette for the call's own color list: created, filled
   * and released entirely inside this synchronous call. The core
   * borrows it and copies the entries out during quantization
   * (custompal_pass1), so a NULL context and a transient lifetime are
   * correct — and it is never NULL for CUSTOM, so the core's silent
   * CUSTOM->MONO fallback cannot trigger; an empty list was refused
   * above, the only case the core itself reports. */
  if (palette == GIMP_CONVERT_PALETTE_CUSTOM)
    {
      int32_t i;

      custom = GIMP_PALETTE (gimp_palette_new (NULL, "Custom"));
      for (i = 0; i < color_count; i++)
        {
          GeglColor *color = gegl_color_new (NULL);

          gegl_color_set_rgba_with_space (color, colors[i].red, colors[i].green,
                                          colors[i].blue, 1.0, NULL);
          gimp_palette_add_entry (custom, -1, NULL, color);
          g_object_unref (color);
        }
    }

  /* FIXED dithers with a process-global matrix; reset it so a PDB call
   * that changed it cannot leak into this conversion (the facade
   * exposes only the engine's default matrix). */
  if (dither == GIMP_CONVERT_DITHER_FIXED)
    gimp_image_convert_indexed_set_dither_matrix (NULL, 0, 0);

  /* One validated core call: its own "Convert Image to Indexed" undo
   * group is the single undo step — no extra group is opened here.
   * Rasterizing of structured layers under ALLOW_RASTERIZE happens
   * inside it, with their sources retained and restored by undo. For
   * non-GENERATED palettes the core sizes its quantizer from
   * max_colors; it ignores the value outside GENERATE, so pass the
   * native maximum, as the engine's own dialog's default does. */
  ok = gimp_image_convert_indexed (image, palette,
                                   palette == GIMP_CONVERT_PALETTE_GENERATE
                                     ? settings->max_colors : MAXNUMCOLORS,
                                   settings->remove_unused, dither,
                                   settings->dither_alpha, settings->dither_text,
                                   custom, NULL, &gerror);
  g_clear_object (&custom);

  /* A FALSE return past our validation is the core's own failure
   * (the GError it sets; its other refusals are log-only preconditions
   * already excluded above). */
  if (! ok)
    return glims_fail (error, gerror, "The image could not be converted to indexed color.");

  gimp_image_flush (image);

  return GLIMS_STATUS_OK;
}
