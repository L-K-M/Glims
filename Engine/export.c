/* Explicit native export settings, without loading libgimp into the app.
 * The file/image lifetime and exported-state sequence follows upstream
 * GIMP_3_2_8 app/file/file-save.c (GPL-3.0-or-later). Only local paths are
 * accepted by the facade. Upstream file plug-ins run in their own processes. */
#include "engine-private.h"
#include <cairo.h>
#include <math.h>
#include <string.h>
#include "core/gimp.h"
#include "core/gimpcontext.h"
#include "libgimpcolor/gimpcolor.h"
#include "gegl/gimp-babl.h"
#include "core/gimpdocumentlist.h"
#include "core/gimpimage.h"
#include "core/gimpimage-color-profile.h"
#include "core/gimpimage-convert-precision.h"
#include "core/gimpimage-duplicate.h"
#include "core/gimpimage-undo.h"
#include "core/gimplayer.h"
#include "core/gimplayer-new.h"
#include "core/gimppickable.h"
#include "core/gimpprogress.h"
#include "pdb/gimpprocedure.h"
#include "plug-in/gimppluginmanager-file.h"
#include "plug-in/gimppluginprocedure.h"

static gboolean
settings_valid (const GlimsExportSettings *s)
{
  return s->format >= GLIMS_EXPORT_PNG && s->format <= GLIMS_EXPORT_GIF &&
         isfinite (s->jpeg_quality) && s->jpeg_quality >= 0 && s->jpeg_quality <= 1 &&
         s->jpeg_progressive <= 1 && s->jpeg_optimize <= 1 &&
         s->jpeg_subsampling <= GLIMS_JPEG_BOTH &&
         s->png_compression >= 0 && s->png_compression <= 9 &&
         s->png_interlaced <= 1 && s->png_preserve_transparent_color <= 1 &&
         s->tiff_compression <= GLIMS_TIFF_PACK_BITS &&
         s->tiff_preserve_transparent_color <= 1 && s->psd_layout <= GLIMS_PSD_MERGED;
}

/* Bind by name and type, never by incidental upstream argument offsets.
 * The caller also runs each native param spec's validator before executing. */
static GValue *
argument (GimpProcedure *proc, GimpValueArray *args, const char *name, GType type)
{
  for (gint i = 0; i < proc->num_args; i++)
    if (strcmp (g_param_spec_get_name (proc->args[i]), name) == 0)
      {
        GValue *value = gimp_value_array_index (args, i);
        return G_VALUE_TYPE (value) == type ? value : NULL;
      }
  return NULL;
}

static gboolean
set_bool (GimpProcedure *p, GimpValueArray *a, const char *name, gboolean value)
{
  GValue *v = argument (p, a, name, G_TYPE_BOOLEAN);
  if (!v) return FALSE;
  g_value_set_boolean (v, value);
  return TRUE;
}
static gboolean
set_choice (GimpProcedure *p, GimpValueArray *a, const char *name, const char *value)
{
  GValue *v = argument (p, a, name, G_TYPE_STRING);
  if (!v) return FALSE;
  g_value_set_string (v, value);
  return TRUE;
}

static gboolean
configure (GimpProcedure *p, GimpValueArray *a, const GlimsExportSettings *s, gboolean cmyk)
{
  static const char *jpeg_sampling[] = { "sub-sampling-1x1", "sub-sampling-2x1",
                                        "sub-sampling-1x2", "sub-sampling-2x2" };
  static const char *tiff_compression[] = { "none", "lzw", "adobe_deflate", "packbits" };
  GValue *number;
  switch (s->format)
    {
    case GLIMS_EXPORT_JPEG:
      number = argument (p, a, "quality", G_TYPE_DOUBLE);
      if (!number) return FALSE;
      g_value_set_double (number, s->jpeg_quality);
      return set_bool (p, a, "progressive", s->jpeg_progressive) &&
             set_bool (p, a, "optimize", s->jpeg_optimize) &&
             set_choice (p, a, "sub-sampling", jpeg_sampling[s->jpeg_subsampling]);
    case GLIMS_EXPORT_PNG:
      number = argument (p, a, "compression", G_TYPE_INT);
      if (!number) return FALSE;
      g_value_set_int (number, s->png_compression);
      return set_bool (p, a, "interlaced", s->png_interlaced) &&
             set_bool (p, a, "save-transparent", s->png_preserve_transparent_color);
    case GLIMS_EXPORT_TIFF:
      return set_choice (p, a, "compression", tiff_compression[s->tiff_compression]) &&
             set_bool (p, a, "save-transparent-pixels", s->tiff_preserve_transparent_color) &&
             /* The native noninteractive TIFF loader includes the thumbnail
              * IFD as a layer. Omit that redundant image so round trips keep
              * the exported dimensions and composite. */
             set_bool (p, a, "include-thumbnail", FALSE);
    case GLIMS_EXPORT_PSD:
      return set_bool (p, a, "cmyk", cmyk) &&
             set_bool (p, a, "duotone", FALSE) &&
             set_bool (p, a, "clippingpath", FALSE);
    case GLIMS_EXPORT_GIF:
      return set_bool (p, a, "interlace", FALSE) &&
             set_bool (p, a, "as-animation", FALSE);
    default:
      return FALSE;
    }
}

/* Follow GIMP_3_2_8 app/pdb/layer-cmds.c's new-from-visible template.
 * Preserve the source profile/precision and alpha, and explicitly clip the
 * projection to the canvas. Flatten would replace alpha with a background.
 * The duplicate retains image metadata; none of its layers reach the file. */
static GimpImage *
merged_export_image (GimpImage *source)
{
  GimpImage *copy = gimp_image_duplicate (source);
  GimpLayer *layer;
  GeglBuffer *projection, *clipped;
  GList *layers;
  GeglRectangle bounds = { 0, 0, gimp_image_get_width (source), gimp_image_get_height (source) };
  if (!copy) return NULL;
  gimp_image_undo_disable (copy);
  gimp_pickable_flush (GIMP_PICKABLE (source));
  projection = gimp_pickable_get_buffer (GIMP_PICKABLE (source));
  clipped = gegl_buffer_new (&bounds, gegl_buffer_get_format (projection));
  gegl_buffer_copy (projection, &bounds, GEGL_ABYSS_NONE, clipped, &bounds);
  layer = gimp_layer_new_from_gegl_buffer (clipped, copy,
            gimp_image_get_layer_format (copy, TRUE), "Merged appearance",
            GIMP_OPACITY_OPAQUE, GIMP_LAYER_MODE_NORMAL,
            gimp_color_managed_get_color_profile (GIMP_COLOR_MANAGED (source)));
  g_object_unref (clipped);
  if (!layer) { g_object_unref (copy); return NULL; }
  /* Only remove roots: removing a group also destroys its children. */
  while ((layers = gimp_image_get_layer_iter (copy)))
    gimp_image_remove_layer (copy, layers->data, FALSE, NULL);
  if (!gimp_image_add_layer (copy, layer, NULL, 0, FALSE))
    { g_object_unref (layer); g_object_unref (copy); return NULL; }
  gimp_image_unset_selected_channels (copy);
  gimp_image_flush (copy);
  return copy;
}

static GlimsStatus
export_configured (GlimsEngine *engine, GlimsImageID id,
                   const char *path, const GlimsExportSettings *settings,
                   GimpColorProfile *cmyk_profile, GimpColorRenderingIntent intent,
                   char **error)
{
  static const char *procedures[] = { NULL, "file-png-export", "file-jpeg-export", "file-tiff-export", "file-psd-export", "file-gif-export" };
  GlimsOpenImage *open = glims_lookup_image (engine, id);
  GimpPlugInProcedure *file_proc;
  GimpProcedure *proc;
  GimpImage *image, *private_image = NULL;
  GimpExportOptions *options;
  GimpValueArray *args, *returns;
  GValue *run, *image_arg, *file_arg, *options_arg;
  GFile *file;
  GError *gerror = NULL;
  GlimsProgress *progress;
  GimpPDBStatusType status;
  gboolean valid;

  if (!settings_valid (settings)) return GLIMS_STATUS_INVALID_ARGUMENT;
  if (!open) return GLIMS_STATUS_NOT_FOUND;
  if (engine->busy || g_hash_table_size (engine->strokes) ||
      g_hash_table_size (engine->filters)) return GLIMS_STATUS_BUSY;
#if GIMP_MAJOR_VERSION == 3 && GIMP_MINOR_VERSION == 3
  if (cmyk_profile)
    {
      /* The qualified development writer requests float RGBA for CMYK in
       * get_pixel_format(), then create_merged_image() blends its bytes as
       * u8 RGBA. Its PSD composite fails an independent CMYK plane oracle.
       * Do not publish that corrupt preview; no upstream source is patched. */
      if (error) *error = g_strdup ("CMYK PSD output is unavailable with this development image engine. Use the bundled stable engine.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
#endif
  if (settings->format == GLIMS_EXPORT_PSD)
    {
      const char *extension = strrchr (path, '.');
      if (!extension || g_ascii_strcasecmp (extension, ".psd") != 0)
        {
          if (error) *error = g_strdup ("PSD export requires a .psd filename.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
    }
  if (settings->format == GLIMS_EXPORT_GIF)
    {
      const char *extension = strrchr (path, '.');
      if (!extension || g_ascii_strcasecmp (extension, ".gif") != 0)
        {
          if (error) *error = g_strdup ("GIF export requires a .gif filename.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
    }
  if (cmyk_profile && gimp_image_get_base_type (open->image) != GIMP_RGB)
    {
      if (error) *error = g_strdup ("CMYK PSD output requires an RGB document. Convert its mode before exporting.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (settings->format == GLIMS_EXPORT_PSD && gimp_image_get_base_type (open->image) == GIMP_INDEXED)
    {
      if (error) *error = g_strdup ("PSD export requires an RGB or grayscale image. Convert its mode before exporting.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
#if !GIMP_CHECK_VERSION (3, 2, 6)
  if (settings->format == GLIMS_EXPORT_PSD)
    {
      /* Upstream 62f1d4909f (first released in 3.2.6) made PSD pixel
       * encoding honor its embedded profile. Earlier writers use babl's
       * default space while still attaching the image's ICC profile.
       * Refuse that mismatch before touching a destination. */
      GimpColorProfile *profile = gimp_color_managed_get_color_profile (GIMP_COLOR_MANAGED (open->image));
      GimpColorProfile *standard = gimp_image_get_base_type (open->image) == GIMP_GRAY
        ? gimp_color_profile_new_d65_gray_srgb_trc () : gimp_color_profile_new_rgb_srgb ();
      gboolean compatible = profile && gimp_color_profile_is_equal (profile, standard);
      g_object_unref (standard);
      if (!compatible)
        {
          if (error) *error = g_strdup ("This image engine cannot preserve this color profile in PSD. Use TIFF or a newer image engine.");
          return GLIMS_STATUS_UNSUPPORTED;
        }
    }
#endif

  file = g_file_new_for_path (path);
  file_proc = gimp_plug_in_manager_file_procedure_find (engine->gimp->plug_in_manager,
                  GIMP_FILE_PROCEDURE_GROUP_EXPORT, file, &gerror);
  if (!file_proc)
    {
      g_object_unref (file);
      return glims_fail (error, gerror, "No exporter supports this filename.");
    }
  if (strcmp (gimp_object_get_name (file_proc), procedures[settings->format]) != 0)
    {
      g_object_unref (file);
      if (error) *error = g_strdup ("The filename extension does not match the selected export format.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  proc = GIMP_PROCEDURE (file_proc);
  args = gimp_procedure_get_arguments (proc);
  run = argument (proc, args, "run-mode", GIMP_TYPE_RUN_MODE);
  image_arg = argument (proc, args, "image", GIMP_TYPE_IMAGE);
  file_arg = argument (proc, args, "file", G_TYPE_FILE);
  options_arg = argument (proc, args, "options", GIMP_TYPE_EXPORT_OPTIONS);
  if (!run || !image_arg || !file_arg || !options_arg || !configure (proc, args, settings, cmyk_profile != NULL))
    {
      gimp_value_array_unref (args);
      g_object_unref (file);
      if (error) *error = g_strdup ("This engine does not provide the requested export controls.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  options = g_object_new (GIMP_TYPE_EXPORT_OPTIONS, NULL);
  g_value_set_enum (run, GIMP_RUN_NONINTERACTIVE);
  g_value_set_object (image_arg, open->image);
  g_value_set_object (file_arg, file);
  g_value_set_object (options_arg, options);
  g_object_unref (options);
  valid = TRUE;
  for (gint i = 0; i < proc->num_args; i++)
    if (g_param_value_validate (proc->args[i], gimp_value_array_index (args, i)))
      valid = FALSE;
  if (!valid)
    {
      gimp_value_array_unref (args);
      g_object_unref (file);
      if (error) *error = g_strdup ("This engine cannot represent the requested export settings.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  if (g_file_query_exists (file, NULL))
    {
      GFileInfo *info = g_file_query_info (file, G_FILE_ATTRIBUTE_STANDARD_TYPE ","
                  G_FILE_ATTRIBUTE_ACCESS_CAN_WRITE, G_FILE_QUERY_INFO_NONE, NULL, &gerror);
      if (!info || g_file_info_get_file_type (info) != G_FILE_TYPE_REGULAR ||
          !g_file_info_get_attribute_boolean (info, G_FILE_ATTRIBUTE_ACCESS_CAN_WRITE))
        {
          g_clear_object (&info);
          gimp_value_array_unref (args);
          g_object_unref (file);
          return glims_fail (error, gerror, "The export destination is not a writable regular file.");
        }
      g_object_unref (info);
    }

  /* Plug-ins nest a main loop: retain the image, never use `open` afterward. */
  image = g_object_ref (open->image);
  if ((settings->format == GLIMS_EXPORT_PSD && (settings->psd_layout == GLIMS_PSD_MERGED || cmyk_profile)) ||
      settings->format == GLIMS_EXPORT_GIF)
    {
      private_image = settings->format == GLIMS_EXPORT_GIF || settings->psd_layout == GLIMS_PSD_MERGED
        ? merged_export_image (image) : gimp_image_duplicate (image);
      if (!private_image)
        {
          gimp_value_array_unref (args);
          g_object_unref (file);
          g_object_unref (image);
          return glims_fail (error, NULL, settings->format == GLIMS_EXPORT_GIF
                               ? "The visible image could not be prepared for GIF export."
                               : "The visible image could not be prepared for PSD export.");
        }
      if (settings->format == GLIMS_EXPORT_GIF)
        gimp_image_parasite_detach (private_image, "gif/animated", FALSE);
      if (cmyk_profile)
        {
          gimp_image_undo_disable (private_image);
          GimpComponentType component = gimp_babl_component_type (gimp_image_get_precision (private_image));
          /* CMYK PSD supports 8/16-bit channels. Do not let development
           * writers emit a 32-bit CMYK file that their loader rejects. */
          if (component != GIMP_COMPONENT_TYPE_U8 && component != GIMP_COMPONENT_TYPE_U16)
            gimp_image_convert_precision (private_image, GIMP_PRECISION_U16_NON_LINEAR,
                                           GEGL_DITHER_NONE, GEGL_DITHER_NONE, GEGL_DITHER_NONE, NULL);
          if (!gimp_image_set_simulation_profile (private_image, cmyk_profile))
            {
              gimp_value_array_unref (args);
              g_object_unref (file);
              g_object_unref (image);
              g_object_unref (private_image);
              return glims_fail (error, NULL, "The CMYK output profile could not be installed on the export copy.");
            }
          gimp_image_set_simulation_intent (private_image, intent);
          gimp_image_flush (private_image);
        }
      g_value_set_object (image_arg, private_image);
    }
  gimp_image_saving (image);
  progress = glims_progress_new (engine);
  engine->progress = progress;
  engine->busy++;
  returns = gimp_procedure_execute (proc, engine->gimp, gimp_get_user_context (engine->gimp),
                                     GIMP_PROGRESS (progress), args, &gerror);
  engine->busy--;
  if (gimp_progress_is_active (GIMP_PROGRESS (progress)))
    gimp_progress_end (GIMP_PROGRESS (progress));
  engine->progress = NULL;
  g_object_unref (progress);
  status = returns ? g_value_get_enum (gimp_value_array_index (returns, 0)) : GIMP_PDB_EXECUTION_ERROR;
  g_clear_pointer (&returns, gimp_value_array_unref);
  gimp_value_array_unref (args);
  g_clear_object (&private_image);
  if (status == GIMP_PDB_SUCCESS)
    {
      gimp_image_set_exported_file (image, file);
      gimp_image_set_export_proc (image, file_proc);
      gimp_image_set_imported_file (image, NULL);
      gimp_image_export_clean_all (image);
      gimp_image_exported (image, file);
      gimp_document_list_add_file (GIMP_DOCUMENT_LIST (engine->gimp->documents), file,
                                   g_slist_nth_data (file_proc->mime_types_list, 0));
    }
  gimp_image_flush (image);
  g_object_unref (image);
  g_object_unref (file);
  if (status == GIMP_PDB_CANCEL)
    {
      g_clear_error (&gerror);
      return GLIMS_STATUS_CANCELLED;
    }
  if (status != GIMP_PDB_SUCCESS)
    return glims_fail (error, gerror, "The image could not be exported.");
  g_clear_error (&gerror);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_export_configured (GlimsEngine *engine, GlimsImageID id,
                               const char *path, const GlimsExportSettings *settings,
                               char **error)
{
  return export_configured (engine, id, path, settings, NULL,
                             GIMP_COLOR_RENDERING_INTENT_RELATIVE_COLORIMETRIC, error);
}

GlimsStatus
glims_image_export_psd_cmyk (GlimsEngine *engine, GlimsImageID id,
                             const char *path, const GlimsExportSettings *settings,
                             const uint8_t *icc, size_t length,
                             char **error)
{
  const GimpColorRenderingIntent native_intent = GIMP_COLOR_RENDERING_INTENT_RELATIVE_COLORIMETRIC;
  GError *gerror = NULL;
  GimpColorProfile *profile;
  GlimsStatus status;
  if (!icc || !length || length > 4 * 1024 * 1024 || settings->format != GLIMS_EXPORT_PSD)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  /* The supported babl CMYK path uses relative colorimetric + BPC
   * (babl/babl-icc.c's lcms_from_rgba). Do not expose ignored intent choices. */
  profile = gimp_color_profile_new_from_icc_profile (icc, length, &gerror);
  if (!profile) return glims_fail (error, gerror, "The CMYK output ICC profile could not be read.");
  if (!gimp_color_profile_is_cmyk (profile) ||
      !gimp_color_profile_get_space (profile, native_intent, &gerror))
    {
      g_object_unref (profile);
      return glims_fail (error, gerror, "Choose a usable CMYK output ICC profile.");
    }
  status = export_configured (engine, id, path, settings, profile, native_intent, error);
  g_object_unref (profile);
  return status;
}
