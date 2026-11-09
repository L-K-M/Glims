/*
 * Pixel-to-resource creation (facade slot 129, resource_create_pixels):
 * one saved bitmap brush or pattern built from owned straight-alpha
 * RGBA bytes, persisted into the engine's own configured writable data
 * folder and published to the engine's resource factory.
 *
 * Durability model (docs/resource-pixel-create.md): the resource is
 * first built privately — a GBR v2 seekable memory stream through
 * gimp_brush_load_brush() for a brush, a private GimpPattern with an
 * owned TempBuf mask for a pattern — then saved with a CHECKED
 * gimp_data_save() (vfunc AND stream-close must succeed) into a unique
 * hidden staging subdirectory of the chosen save folder, promoted to a
 * unique UUID final filename with g_file_move() (no overwrite, no copy
 * fallback), reassociated with gimp_data_set_file(), validated writable,
 * and only then added to the factory container after an exact-name
 * membership check. The native loader skips hidden directory entries
 * before recursing (gimpdataloaderfactory.c, load_directory), so the
 * staging subdirectory is never loaded. The factory convenience
 * new/duplicate calls are NOT used: they save unchecked and only
 * g_critical on failure (gimpdatafactory.c). Only this call's own
 * staging and final paths are ever deleted, and only on its own error
 * paths; no multi-step filesystem transaction or general rollback is
 * promised beyond that cleanup. No image, undo history, user context,
 * global clipboard or shared native data is read or mutated.
 */
#include "engine-private.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpbrush-header.h"
#include "core/gimpbrush-load.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpobject.h"
#include "core/gimppattern.h"
#include "core/gimppattern-load.h"
#include "core/gimptempbuf.h"
#include "core/gimp-utils.h"

/* The native resource dimension bound: GIMP_BRUSH_MAX_SIZE and
 * GIMP_PATTERN_MAX_SIZE are both 10000 (gimpbrush-header.h:25,
 * gimppattern-header.h:23). */
#define RESOURCE_MAX_DIMENSION 10000
/* The label bound: GIMP_BRUSH_MAX_NAME is 256 including the NUL
 * (gimpbrush-header.h:26), so at most 255 UTF-8 bytes. */
#define RESOURCE_NAME_MAX_BYTES 255
#define BRUSH_SPACING_MIN 1u
#define BRUSH_SPACING_MAX 1000u

static GimpDataFactory *
factory_for_kind (Gimp *gimp, uint32_t kind)
{
  switch (kind)
    {
    case GLIMS_RESOURCE_BRUSH:
      return gimp->brush_factory;
    case GLIMS_RESOURCE_PATTERN:
      return gimp->pattern_factory;
    }

  return NULL;
}

/* The label contract: nonempty, valid UTF-8, at most 255 bytes, and no
 * control character anywhere. An embedded NUL cannot arrive through a
 * C string (the Swift side rejects it before the bridge); strlen() sees
 * only up to the first NUL, which is what the native writers use.
 * Shared with resource-duplicate.c (glims_valid_resource_name). */
gboolean
glims_valid_resource_name (const char *name)
{
  const gchar *p;
  size_t       length;

  if (! name)
    return FALSE;

  length = strlen (name);
  if (length == 0 || length > RESOURCE_NAME_MAX_BYTES)
    return FALSE;
  if (! g_utf8_validate (name, (gssize) length, NULL))
    return FALSE;

  for (p = name; *p; p = g_utf8_next_char (p))
    if (g_unichar_iscntrl (g_utf8_get_char (p)))
      return FALSE;

  return TRUE;
}

/* Dimensions 1 ... 10000 and the exact width*height*4 byte count, all
 * in overflow-safe 64-bit arithmetic, before anything is mutated. */
static gboolean
valid_pixels (int32_t width, int32_t height, const uint8_t *pixels,
              size_t byte_count, uint64_t *out_bytes)
{
  uint64_t count;

  if (width < 1 || height < 1 ||
      width > RESOURCE_MAX_DIMENSION || height > RESOURCE_MAX_DIMENSION)
    return FALSE;

  count = (uint64_t) (uint32_t) width * (uint64_t) (uint32_t) height * 4u;
  if (count > GLIMS_MAX_PIXEL_BUFFER_BYTES || count > (uint64_t) SIZE_MAX)
    return FALSE;
  if (! pixels || count != (uint64_t) byte_count)
    return FALSE;

  *out_bytes = count;
  return TRUE;
}

/* Exact name collision against the current factory membership; the
 * loader factories run with unique-names=TRUE, so adding a duplicate
 * would silently uniquify — refused here instead, before any write.
 * Shared with resource-duplicate.c (glims_resource_name_taken). */
gboolean
glims_resource_name_taken (GimpContainer *container, const gchar *name)
{
  gint n = gimp_container_get_n_children (container);
  gint i;

  for (i = 0; i < n; i++)
    {
      GimpObject *child = gimp_container_get_child_by_index (container, i);
      const gchar *child_name = child ? gimp_object_get_name (child) : NULL;

      if (child_name && strcmp (child_name, name) == 0)
        return TRUE;
    }

  return FALSE;
}

/* The save-directory chooser of the static gimp_data_factory_get_save_dir
 * (gimpdatafactory.c:1001-1091), reproduced with the public owned-list
 * getters: the first configured writable-path entry that is also in the
 * search path and exists (or can be created) as a directory. No
 * arbitrary HOME fallback and no configuration mutation. */
static GFile *
choose_save_dir (GimpDataFactory *factory, GError **error)
{
  GList  *path          = gimp_data_factory_get_data_path (factory);
  GList  *writable_path = gimp_data_factory_get_data_path_writable (factory);
  GFile  *writable_dir  = NULL;
  gboolean found_any    = FALSE;
  GList  *list;

  if (writable_path)
    {
      for (list = writable_path; list && ! writable_dir; list = g_list_next (list))
        {
          GList  *found = g_list_find_custom (path, list->data,
                                              (GCompareFunc) gimp_file_compare);
          GFile  *dir;
          GError *mkdir_error = NULL;

          if (! found)
            continue;

          found_any = TRUE;
          dir = found->data;

          if (! g_file_make_directory_with_parents (dir, NULL, &mkdir_error) &&
              g_file_query_file_type (dir, G_FILE_QUERY_INFO_NONE, NULL) != G_FILE_TYPE_DIRECTORY)
            {
              if (! list->next)
                g_set_error (error, GIMP_DATA_ERROR, 0,
                             "The configured writable data folder could not be created "
                             "or is not a directory.");
            }
          else
            {
              writable_dir = g_object_ref (dir);
            }
          g_clear_error (&mkdir_error);
        }

      if (! writable_dir && ! found_any)
        g_set_error (error, GIMP_DATA_ERROR, 0,
                     "The configured writable data folder is not part of the search path.");
    }
  else
    {
      g_set_error (error, GIMP_DATA_ERROR, 0,
                   "No writable data folder is configured for this resource kind.");
    }

  g_list_free_full (path,          (GDestroyNotify) g_object_unref);
  g_list_free_full (writable_path, (GDestroyNotify) g_object_unref);

  return writable_dir;
}

/* Serializes one GBR v2 bitmap brush: big-endian header, NUL-terminated
 * UTF-8 name, then the tightly packed straight R'G'B'A u8 payload. The
 * loader (gimpbrush-load.c) copies RGB into its owned R'G'B' pixmap and
 * alpha into its owned Y mask for bytes=4, and takes the spacing from
 * the header — no private brush field is written here. */
static GBytes *
serialize_gbr (const gchar *name, int32_t width, int32_t height,
               uint32_t spacing, const uint8_t *pixels, uint64_t byte_count)
{
  GimpBrushHeader header;
  gsize           name_length = strlen (name);
  gsize           total       = sizeof (header) + name_length + 1 + (gsize) byte_count;
  guchar         *buffer      = g_try_malloc (total);

  if (! buffer)
    return NULL;

  header.header_size  = g_htonl ((guint32) (sizeof (header) + name_length + 1));
  header.version      = g_htonl (2);
  header.width        = g_htonl ((guint32) width);
  header.height       = g_htonl ((guint32) height);
  header.bytes        = g_htonl (4);
  header.magic_number = g_htonl (GIMP_BRUSH_MAGIC);
  header.spacing      = g_htonl (spacing);

  memcpy (buffer, &header, sizeof (header));
  memcpy (buffer + sizeof (header), name, name_length + 1);
  memcpy (buffer + sizeof (header) + name_length + 1, pixels, (gsize) byte_count);

  return g_bytes_new_take (buffer, total);
}

/* Loads one owned brush from the serialized GBR through a private
 * seekable memory stream. `file` is loader identity/error context
 * only — this function never opens it. The private context keeps the
 * user context untouched. */
static GimpBrush *
load_brush_from_pixels (Gimp *gimp, GFile *file, const gchar *name,
                        int32_t width, int32_t height, uint32_t spacing,
                        const uint8_t *pixels, uint64_t byte_count,
                        GError **error)
{
  GBytes       *bytes   = serialize_gbr (name, width, height, spacing, pixels, byte_count);
  GInputStream *stream;
  GimpContext  *context;
  GimpBrush    *brush;

  if (! bytes)
    {
      g_set_error (error, GIMP_DATA_ERROR, GIMP_DATA_ERROR_WRITE,
                   "Not enough memory to serialize the brush.");
      return NULL;
    }

  stream  = g_memory_input_stream_new_from_bytes (bytes);
  context = gimp_context_new (gimp, "Glims resource create", NULL);
  brush   = gimp_brush_load_brush (context, file, stream, error);

  g_object_unref (stream);
  g_object_unref (context);
  g_bytes_unref (bytes);

  return brush;
}

/* One private pattern with an owned public TempBuf mask holding the
 * straight RGBA source. Direct field assignment is valid only here, on
 * a new private object before publication; finalize unrefs the mask
 * (gimppattern.c). */
static GimpPattern *
pattern_from_pixels (const gchar *name, int32_t width, int32_t height,
                     const uint8_t *pixels, uint64_t byte_count)
{
  GimpPattern *pattern;
  GimpTempBuf *mask;

  pattern = g_object_new (GIMP_TYPE_PATTERN,
                          "name",      name,
                          "mime-type", "image/x-gimp-pat",
                          NULL);
  mask = gimp_temp_buf_new (width, height, babl_format ("R'G'B'A u8"));
  if (! mask)
    {
      g_object_unref (pattern);
      return NULL;
    }

  memcpy (gimp_temp_buf_get_data (mask), pixels, (gsize) byte_count);
  pattern->mask = mask;

  return pattern;
}

/* ---- Checked persistence, shared with resource-duplicate.c ------------ */

GlimsStatus
glims_resource_staging_begin (GimpDataFactory      *factory,
                              const gchar          *extension,
                              GlimsResourceStaging *staging,
                              char                **error)
{
  GError *gerror = NULL;

  memset (staging, 0, sizeof *staging);
  staging->extension = extension;

  staging->save_dir = choose_save_dir (factory, &gerror);
  if (! staging->save_dir)
    {
      return glims_fail (error, g_steal_pointer (&gerror),
                         "No writable data folder is available for this resource kind.");
    }

  /* Stage in a unique hidden subdirectory: the native loader skips
   * hidden entries before recursing, so nothing staged here is ever
   * loaded as a catalog resource. */
  staging->uuid = g_uuid_string_random ();
  {
    gchar *staging_name = g_strdup_printf (".glims-stage-%s", staging->uuid);
    staging->staging_dir = g_file_get_child (staging->save_dir, staging_name);
    g_free (staging_name);
  }
  if (! g_file_make_directory (staging->staging_dir, NULL, &gerror))
    {
      glims_resource_staging_cleanup (staging, FALSE);
      return glims_fail (error, g_steal_pointer (&gerror),
                         "The staging directory could not be created.");
    }
  staging->staging_created = TRUE;

  {
    gchar *staging_file_name = g_strdup_printf ("staging%s", extension);
    staging->staging_file = g_file_get_child (staging->staging_dir, staging_file_name);
    g_free (staging_file_name);
  }

  return GLIMS_STATUS_OK;
}

void
glims_resource_staging_cleanup (GlimsResourceStaging *staging,
                                gboolean              keep_final)
{
  /* A generated pathname is not ownership. Only a successful mkdir or
   * move grants cleanup ownership; collisions must preserve their files.
   * A published success keeps its final file. */
  if (staging->staging_file)
    {
      if (staging->staging_created)
        g_file_delete (staging->staging_file, NULL, NULL);
      g_object_unref (staging->staging_file);
    }
  if (staging->staging_dir)
    {
      if (staging->staging_created)
        g_file_delete (staging->staging_dir, NULL, NULL);
      g_object_unref (staging->staging_dir);
    }
  if (staging->final_file)
    {
      if (staging->promoted && ! keep_final)
        g_file_delete (staging->final_file, NULL, NULL);
      g_object_unref (staging->final_file);
    }
  if (staging->save_dir)
    g_object_unref (staging->save_dir);
  g_free (staging->uuid);
  memset (staging, 0, sizeof *staging);
}

GlimsStatus
glims_resource_save_and_publish (GimpDataFactory      *factory,
                                 GimpData             *data,
                                 const gchar          *name,
                                 GlimsResourceStaging *staging,
                                 GlimsResourceID      *outID,
                                 char                **error)
{
  GimpContainer *container = gimp_data_factory_get_container (factory);
  GError        *gerror    = NULL;
  gchar         *final_name = NULL;
  gboolean       published  = FALSE;
  GlimsStatus    status     = GLIMS_STATUS_FAILED;

  /* Associate the staging file and require the result writable before
   * saving. */
  gimp_data_set_file (data, staging->staging_file, TRUE, TRUE);
  if (! gimp_data_is_writable (data))
    {
      status = glims_fail (error, NULL, "The staged resource file is not writable.");
      goto cleanup;
    }

  /* Checked save: the class vfunc AND the stream close must succeed
   * (gimpdata.c gimp_data_save). */
  if (! gimp_data_save (data, &gerror))
    {
      status = glims_fail (error, g_steal_pointer (&gerror),
                           "The resource could not be saved.");
      goto cleanup;
    }

  /* Promote to a unique UUID final filename with the native extension:
   * a real rename only (no copy fallback), and no overwrite — an
   * existing target fails instead of being replaced. */
  final_name = g_strdup_printf ("%s%s", staging->uuid, staging->extension);
  staging->final_file = g_file_get_child (staging->save_dir, final_name);
  if (! g_file_move (staging->staging_file, staging->final_file,
                     G_FILE_COPY_NO_FALLBACK_FOR_MOVE,
                     NULL, NULL, NULL, &gerror))
    {
      status = glims_fail (error, g_steal_pointer (&gerror),
                           "The saved resource could not be promoted to its final name.");
      goto cleanup;
    }
  staging->promoted = TRUE;

  /* Reassociate the data to the final path and validate writable
   * again before publishing to the factory. */
  gimp_data_set_file (data, staging->final_file, TRUE, TRUE);
  if (! gimp_data_is_writable (data))
    {
      status = glims_fail (error, NULL, "The saved resource file is not writable.");
      goto cleanup;
    }

  /* Publish: the unique-names container must keep the exact name, and
   * the membership and the native id must verify before returning. */
  if (glims_resource_name_taken (container, name))
    {
      status = glims_fail (error, NULL, "A resource with this name already exists.");
      goto cleanup;
    }
  if (! gimp_container_add (container, GIMP_OBJECT (data)))
    {
      status = glims_fail (error, NULL, "The resource could not be added to the catalog.");
      goto cleanup;
    }
  published = TRUE;

  if (! gimp_container_have (container, GIMP_OBJECT (data)) ||
      strcmp (gimp_object_get_name (GIMP_OBJECT (data)), name) != 0)
    {
      status = glims_fail (error, NULL, "The catalog did not keep the exact resource name.");
      goto cleanup;
    }

  {
    gint native_id = gimp_data_get_id (data);

    if (native_id <= 0)
      {
        status = glims_fail (error, NULL, "The new resource has no usable identity.");
        goto cleanup;
      }
    *outID = (GlimsResourceID) native_id;
  }

  status = GLIMS_STATUS_OK;
  /* The container holds its own reference now; drop only ours and keep
   * the published resource out of the error cleanup below. */
  g_object_unref (data);
  data = NULL;

cleanup:
  if (data)
    {
      if (published)
        gimp_container_remove (container, GIMP_OBJECT (data));
      g_object_unref (data);
    }
  g_free (final_name);
  glims_resource_staging_cleanup (staging, status == GLIMS_STATUS_OK);

  return status;
}

GlimsStatus
glims_resource_create_pixels (GlimsEngine *e, uint32_t kind, const char *name,
                              int32_t width, int32_t height,
                              const uint8_t *pixels, size_t byte_count,
                              uint32_t brush_spacing, GlimsResourceID *outID,
                              char **error)
{
  GimpDataFactory      *factory;
  GimpContainer        *container;
  GimpData             *data = NULL;
  GError               *gerror = NULL;
  GlimsResourceStaging  staging;
  const gchar          *extension;
  uint64_t              bytes = 0;
  GlimsStatus           status;

  if (outID)
    *outID = 0;

  /* Admission, all before any mutation. */
  if (! outID)
    {
      if (error)
        *error = strdup ("The id output is required.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (kind == GLIMS_RESOURCE_GRADIENT)
    {
      if (error)
        *error = strdup ("Creating a gradient from pixels is not supported.");
      return GLIMS_STATUS_UNSUPPORTED;
    }
  if (kind != GLIMS_RESOURCE_BRUSH && kind != GLIMS_RESOURCE_PATTERN)
    {
      if (error)
        *error = strdup ("Unknown resource kind.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (! glims_valid_resource_name (name))
    {
      if (error)
        *error = strdup ("The resource name must be nonempty UTF-8 without control "
                         "characters, at most 255 bytes.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (! valid_pixels (width, height, pixels, byte_count, &bytes))
    {
      if (error)
        *error = strdup ("The dimensions must be 1 ... 10000 and the pixel buffer "
                         "exactly width * height * 4 bytes.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (kind == GLIMS_RESOURCE_BRUSH
        ? (brush_spacing < BRUSH_SPACING_MIN || brush_spacing > BRUSH_SPACING_MAX)
        : brush_spacing != 0)
    {
      if (error)
        *error = strdup (kind == GLIMS_RESOURCE_BRUSH
                           ? "The brush spacing must be 1 ... 1000."
                           : "Patterns take no brush spacing (0).");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  /* No image argument: refuse the engine-global busy flag and ANY
   * active stroke or filter session, on any image. */
  if (e->busy > 0 ||
      g_hash_table_size (e->strokes) > 0 ||
      g_hash_table_size (e->filters) > 0)
    return GLIMS_STATUS_BUSY;

  factory   = factory_for_kind (e->gimp, kind);
  container = gimp_data_factory_get_container (factory);

  if (glims_resource_name_taken (container, name))
    return glims_fail (error, NULL, "A resource with this name already exists.");

  extension = (kind == GLIMS_RESOURCE_BRUSH) ? GIMP_BRUSH_FILE_EXTENSION
                                              : GIMP_PATTERN_FILE_EXTENSION;

  status = glims_resource_staging_begin (factory, extension, &staging, error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* Build the private resource from the owned pixels; the staging file
   * is the loader's identity/error context only, never opened by it. */
  if (kind == GLIMS_RESOURCE_BRUSH)
    data = GIMP_DATA (load_brush_from_pixels (e->gimp, staging.staging_file, name,
                                              width, height, brush_spacing,
                                              pixels, bytes, &gerror));
  else
    data = GIMP_DATA (pattern_from_pixels (name, width, height, pixels, bytes));

  if (! data)
    {
      glims_resource_staging_cleanup (&staging, FALSE);
      return glims_fail (error, g_steal_pointer (&gerror),
                         "The resource could not be built from these pixels.");
    }

  return glims_resource_save_and_publish (factory, data, name, &staging, outID, error);
}
