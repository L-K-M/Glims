/*
 * Brushes, patterns and gradients: names-only enumeration of the engine's
 * stock data factories, and the persistent identity triplet that survives
 * a restart (gimp_data_get_identifiers / gimp_data_identify).
 *
 * Everything here is read-only: no factory, data, context or file is
 * changed. The native gimp_data_get_id ids are ephemeral session values
 * in a table shared by every Gimp in the process, so a facade handle is
 * re-resolved on every call and revalidated against this engine's own
 * factory container before use. Handles are never raw pointers and no
 * upstream enum value crosses the facade.
 */
#include "engine-private.h"

#include <math.h>
#include <string.h>

#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpgradient.h"
#include "core/gimpobject.h"
#include "core/gimppattern.h"
#include "core/gimptempbuf.h"
#include "core/gimpviewable.h"

/* The thumbnail box the facade promises (glims_engine.h,
 * resource_thumbnail): small enough that a preview cannot approach
 * GIMP_VIEWABLE_MAX_PREVIEW_SIZE on any supported engine. */
#define THUMBNAIL_MAX_SIZE 512

static GimpDataFactory *
factory_for_kind (Gimp *gimp, uint32_t kind)
{
  switch (kind)
    {
    case GLIMS_RESOURCE_BRUSH:
      return gimp->brush_factory;
    case GLIMS_RESOURCE_PATTERN:
      return gimp->pattern_factory;
    case GLIMS_RESOURCE_GRADIENT:
      return gimp->gradient_factory;
    }

  return NULL;
}

/* The kinds are disjoint GimpData subclasses; brushes carry the
 * generated, pipe and clipboard subclasses. */
static uint32_t
kind_of_data (GimpData *data)
{
  if (GIMP_IS_GRADIENT (data))
    return GLIMS_RESOURCE_GRADIENT;
  if (GIMP_IS_PATTERN (data))
    return GLIMS_RESOURCE_PATTERN;
  if (GIMP_IS_BRUSH (data))
    return GLIMS_RESOURCE_BRUSH;

  return 0;
}

static gboolean
data_matches_kind (GimpData *data, uint32_t kind)
{
  return kind_of_data (data) == kind;
}

/* The nonempty valid UTF-8 text the identity contract requires. */
static gboolean
usable_text (const gchar *text)
{
  return text && *text && g_utf8_validate (text, -1, NULL);
}

/* Copies `text` into `buffer` as the row's display label: valid UTF-8,
 * truncated at most to `size` - 1 bytes and never inside a multi-byte
 * character. */
static void
copy_label (char *buffer, size_t size, const gchar *text)
{
  gchar *valid;
  size_t length;

  valid  = g_utf8_make_valid (text ? text : "", -1);
  length = strlen (valid);

  if (length > size - 1)
    {
      length = size - 1;
      while (length > 0 && (valid[length] & 0xC0) == 0x80)
        length--;
    }

  memcpy (buffer, valid, length);
  buffer[length] = '\0';
  g_free (valid);
}

/* Resolves a facade handle to the live data it names. resources() only
 * ever issues 1 ... G_MAXINT, so anything else is refused before it
 * could reach the native id table through a narrowing cast. What does
 * resolve must also be the right type and a member of this engine's own
 * factory container for that kind: the native id table is global, so a
 * foreign or recycled id must not pass. */
static GlimsStatus
lookup_resource (GlimsEngine *engine, GlimsResourceID id, GimpData **out)
{
  GimpData      *data;
  GimpContainer *container;
  uint32_t       kind;

  *out = NULL;

  if (id == 0 || id > (GlimsResourceID) G_MAXINT)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  data = gimp_data_get_by_id ((gint) id);
  if (! data || ! GIMP_IS_DATA (data))
    return GLIMS_STATUS_NOT_FOUND;

  kind = kind_of_data (GIMP_DATA (data));
  if (! kind)
    return GLIMS_STATUS_NOT_FOUND;

  container = gimp_data_factory_get_container (factory_for_kind (engine->gimp, kind));
  if (! container || ! gimp_container_have (container, GIMP_OBJECT (data)))
    return GLIMS_STATUS_NOT_FOUND;

  *out = GIMP_DATA (data);
  return GLIMS_STATUS_OK;
}

/* The narrowly typed lookup the paint path needs. It reuses
 * lookup_resource(), which already refuses 0 and out-of-native-range
 * handles before the native id table (INVALID_ARGUMENT) and stale,
 * foreign or out-of-factory handles (NOT_FOUND), so the id is never
 * truncated unsafely here; a live resource of another kind is a
 * wrong-kind argument for a brush. */
GlimsStatus
glims_lookup_brush (GlimsEngine *engine, GlimsResourceID id, GimpBrush **out)
{
  GimpData   *data;
  GlimsStatus status;

  if (! out)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  *out = NULL;

  status = lookup_resource (engine, id, &data);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (! GIMP_IS_BRUSH (data))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  *out = GIMP_BRUSH (data);
  return GLIMS_STATUS_OK;
}

/* The narrow pattern lookup fill_pattern uses: the generic admission
 * above (id range before any native narrowing, kind table, membership in
 * this engine's own factory container) plus the pattern kind itself, so
 * a brush or gradient handle is NOT_FOUND here. The returned pattern is
 * borrowed from the factory; the caller passes it to a private context
 * and never mutates or releases it. */
GlimsStatus
glims_lookup_pattern (GlimsEngine *engine, GlimsResourceID id, GimpPattern **out)
{
  GimpData   *data;
  GlimsStatus status;

  *out = NULL;

  status = lookup_resource (engine, id, &data);
  if (status != GLIMS_STATUS_OK)
    return status;

  if (kind_of_data (data) != GLIMS_RESOURCE_PATTERN)
    return GLIMS_STATUS_NOT_FOUND;

  *out = GIMP_PATTERN (data);
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_resources (GlimsEngine       *engine,
                 uint32_t           kind,
                 GlimsResourceInfo *rows,
                 int32_t            capacity,
                 int32_t           *count)
{
  GimpDataFactory *factory;
  GimpContainer   *container;
  gint             n, i;
  int32_t          total = 0;

  if (count)
    *count = 0;

  if (! count || capacity < 0 || (capacity > 0 && ! rows))
    return GLIMS_STATUS_INVALID_ARGUMENT;

  factory = factory_for_kind (engine->gimp, kind);
  if (! factory)
    return GLIMS_STATUS_INVALID_ARGUMENT;

  container = gimp_data_factory_get_container (factory);
  n = gimp_container_get_n_children (container);

  for (i = 0; i < n; i++)
    {
      GimpObject *child = gimp_container_get_child_by_index (container, i);
      GimpData   *data;
      gint        native_id;

      if (! child || ! GIMP_IS_DATA (child))
        continue;

      data = GIMP_DATA (child);
      if (! data_matches_kind (data, kind))
        continue;

      native_id = gimp_data_get_id (data);
      if (native_id <= 0)
        continue;

      if (total < capacity)
        {
          GlimsResourceInfo *row = &rows[total];

          row->id   = (GlimsResourceID) native_id;
          row->kind = kind;
          copy_label (row->name, sizeof row->name, gimp_object_get_name (child));
        }

      total++;
    }

  *count = total;
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_resource_identifiers (GlimsEngine      *engine,
                            GlimsResourceID   id,
                            char            **name,
                            char            **collection,
                            bool             *internal,
                            char            **error)
{
  GimpData *data;
  gchar    *out_name       = NULL;
  gchar    *out_collection = NULL;
  gboolean  is_internal    = FALSE;
  GlimsStatus status;

  if (name)
    *name = NULL;
  if (collection)
    *collection = NULL;
  if (internal)
    *internal = false;

  if (! name || ! collection || ! internal)
    {
      if (error)
        *error = strdup ("The name, collection and internal outputs are required.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = lookup_resource (engine, id, &data);
  if (status == GLIMS_STATUS_INVALID_ARGUMENT)
    {
      if (error)
        *error = strdup ("This handle cannot name a resource.");
      return status;
    }
  if (status != GLIMS_STATUS_OK)
    return status;

  gimp_data_get_identifiers (data, &out_name, &out_collection, &is_internal);

  /* The triplet must be usable by resource_resolve(), which requires a
   * nonempty valid UTF-8 name even for internal resources, and a
   * UTF-8 collection when there is one. The collection is passed
   * through otherwise: NULL and "" stay distinct values. */
  if (! usable_text (out_name) ||
      (out_collection && ! g_utf8_validate (out_collection, -1, NULL)))
    {
      g_free (out_name);
      g_free (out_collection);
      return glims_fail (error, NULL, "This resource has no usable identity.");
    }

  *name       = out_name;
  *collection = out_collection;
  *internal   = is_internal ? true : false;

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_resource_resolve (GlimsEngine     *engine,
                        uint32_t         kind,
                        const char      *name,
                        const char      *collection,
                        bool             internal,
                        GlimsResourceID *outID,
                        char           **error)
{
  GimpDataFactory *factory;
  GimpContainer   *container;
  gint             n, i;

  if (outID)
    *outID = 0;

  if (! outID)
    {
      if (error)
        *error = strdup ("The id output is required.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  factory = factory_for_kind (engine->gimp, kind);
  if (! factory)
    {
      if (error)
        *error = strdup ("Unknown resource kind.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (! usable_text (name) ||
      (collection && ! g_utf8_validate (collection, -1, NULL)))
    {
      if (error)
        *error = strdup ("The identity name must be nonempty UTF-8 text, "
                         "and the collection UTF-8 when given.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  container = gimp_data_factory_get_container (factory);
  n = gimp_container_get_n_children (container);

  for (i = 0; i < n; i++)
    {
      GimpObject *child = gimp_container_get_child_by_index (container, i);
      GimpData   *data;
      gint        native_id;

      if (! child || ! GIMP_IS_DATA (child))
        continue;

      data = GIMP_DATA (child);
      if (! data_matches_kind (data, kind))
        continue;

      /* Exactly gimp_data_identify's matching: the collection compares
       * exactly (NULL and "" distinct) and the name only for
       * non-internal resources, whose display names are not localized.
       * No name-only fallback: a stale collection reports NOT_FOUND. */
      if (! gimp_data_identify (data, name, collection, internal ? TRUE : FALSE))
        continue;

      native_id = gimp_data_get_id (data);
      if (native_id <= 0)
        {
          if (error)
            *error = strdup ("This resource has no usable identity.");
          return GLIMS_STATUS_FAILED;
        }

      *outID = (GlimsResourceID) native_id;
      return GLIMS_STATUS_OK;
    }

  return GLIMS_STATUS_NOT_FOUND;
}

/* The colors a thumbnail may recolor with: every component finite and
 * inside 0 ... 1, the same contract GlimsColor documents and the
 * filter property colors enforce. */
static gboolean
color_usable (const GlimsColor *color)
{
  gdouble rgba[4] = { color->red, color->green, color->blue, color->alpha };
  gint    i;

  for (i = 0; i < 4; i++)
    if (! isfinite (rgba[i]) || rgba[i] < 0.0 || rgba[i] > 1.0)
      return FALSE;

  return TRUE;
}

/* Copies the preview's pixels into the facade's owned straight-alpha
 * RGBA buffer: rows follow the pixbuf's own rowstride, and a
 * three-channel preview gains an opaque alpha. Returns NULL when the
 * size cannot be represented or the allocation fails. */
static uint8_t *
clone_preview_pixels (GdkPixbuf *pixbuf, size_t *byte_count,
                      int32_t *out_width, int32_t *out_height)
{
  const guchar *source;
  uint8_t      *pixels;
  gint          width, height, stride, x, y;
  gboolean      has_alpha;
  size_t        bytes;

  width    = gdk_pixbuf_get_width (pixbuf);
  height   = gdk_pixbuf_get_height (pixbuf);
  stride   = gdk_pixbuf_get_rowstride (pixbuf);
  has_alpha = gdk_pixbuf_get_has_alpha (pixbuf);
  source   = gdk_pixbuf_get_pixels (pixbuf);

  if (width <= 0 || height <= 0 ||
      (size_t) width > SIZE_MAX / 4 / (size_t) height)
    return NULL;

  bytes  = (size_t) width * (size_t) height * 4;
  pixels = g_try_malloc (bytes);
  if (! pixels)
    return NULL;

  for (y = 0; y < height; y++)
    {
      const guchar *row = source + (gsize) y * (gsize) stride;
      uint8_t      *dst = pixels + (gsize) y * (size_t) width * 4;

      if (has_alpha)
        {
          memcpy (dst, row, (size_t) width * 4);
        }
      else
        {
          for (x = 0; x < width; x++)
            {
              dst[x * 4 + 0] = row[x * 3 + 0];
              dst[x * 4 + 1] = row[x * 3 + 1];
              dst[x * 4 + 2] = row[x * 3 + 2];
              dst[x * 4 + 3] = 255;
            }
        }
    }

  *byte_count = bytes;
  *out_width  = width;
  *out_height = height;
  return pixels;
}

GlimsStatus
glims_resource_thumbnail (GlimsEngine       *engine,
                          GlimsResourceID    id,
                          int32_t            max_size,
                          const GlimsColor  *foreground,
                          const GlimsColor  *background,
                          GlimsPixelBuffer  *out,
                          char             **error)
{
  GimpData     *data;
  GimpViewable *viewable;
  GimpContext  *context;
  GimpTempBuf  *temp_buf;
  GdkPixbuf    *pixbuf;
  GeglColor    *fg_color;
  GeglColor    *bg_color;
  GlimsStatus   status;
  gint          width, height, src_width, src_height;
  int32_t       thumb_width = 0, thumb_height = 0;
  size_t        byte_count = 0;
  uint8_t      *pixels;

  if (out)
    memset (out, 0, sizeof *out);

  if (! out)
    {
      if (error)
        *error = strdup ("The pixel buffer output is required.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if (max_size < 1 || max_size > THUMBNAIL_MAX_SIZE)
    {
      if (error)
        *error = strdup ("The maximum size must be between 1 and 512.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  if ((foreground && ! color_usable (foreground)) ||
      (background && ! color_usable (background)))
    {
      if (error)
        *error = strdup ("The foreground and background colors need "
                         "finite components inside 0...1.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  status = lookup_resource (engine, id, &data);
  if (status == GLIMS_STATUS_INVALID_ARGUMENT)
    {
      if (error)
        *error = strdup ("This handle cannot name a resource.");
      return status;
    }
  if (status != GLIMS_STATUS_OK)
    return status;

  viewable = GIMP_VIEWABLE (data);

  /* Gradients have no native size and fill their request exactly, so
   * they get the bounded strip the facade documents. Brushes and
   * patterns fit their source dimensions inside the box without
   * upscaling, which is also what their native preview does with the
   * request. */
  if (kind_of_data (data) == GLIMS_RESOURCE_GRADIENT)
    {
      width  = max_size;
      height = MAX (1, max_size / 2);
    }
  else if (gimp_viewable_get_size (viewable, &src_width, &src_height) &&
           src_width > 0 && src_height > 0)
    {
      gdouble scale = MIN ((gdouble) max_size / (gdouble) src_width,
                           (gdouble) max_size / (gdouble) src_height);

      scale  = MIN (1.0, scale);
      width  = MAX (1, (gint) ((gdouble) src_width  * scale + 0.5));
      height = MAX (1, (gint) ((gdouble) src_height * scale + 0.5));
    }
  else
    {
      width = height = max_size;
    }

  /* A parentless per-call context carrying explicit colors: the
   * gradient's foreground/background segments read these, and nothing
   * global (the user context) is read or changed. The defaults are the
   * core's own: black foreground, white background. */
  context  = gimp_context_new (engine->gimp, "Glims resource thumbnail", NULL);
  fg_color = gegl_color_new (NULL);
  bg_color = gegl_color_new (NULL);
  gegl_color_set_rgba_with_space (fg_color,
                       foreground ? foreground->red   : 0.0,
                       foreground ? foreground->green : 0.0,
                       foreground ? foreground->blue  : 0.0,
                       foreground ? foreground->alpha : 1.0, NULL);
  gegl_color_set_rgba_with_space (bg_color,
                       background ? background->red   : 1.0,
                       background ? background->green : 1.0,
                       background ? background->blue  : 1.0,
                       background ? background->alpha : 1.0, NULL);
  gimp_context_set_foreground (context, fg_color);
  gimp_context_set_background (context, bg_color);

  /* Fresh, owned preview: gimp_viewable_get_new_preview runs the
   * class's own renderer on every call, while the cached
   * gimp_viewable_get_preview path keys on width, height and the
   * foreground alone and would serve stale gradients when only the
   * background changes. The TempBuf keeps its own format; the pixbuf
   * call normalizes it to 8-bit RGB or RGBA. Both objects are owned
   * here and released below. */
#if GIMP_CHECK_VERSION (3, 3, 0)
  temp_buf = gimp_viewable_get_new_preview (viewable, context, width, height, 1, fg_color);
#else
  temp_buf = gimp_viewable_get_new_preview (viewable, context, width, height, fg_color);
#endif

  g_object_unref (bg_color);
  g_object_unref (fg_color);
  g_object_unref (context);

  if (! temp_buf)
    return glims_fail (error, NULL, "This resource has no thumbnail.");

  pixbuf = gimp_temp_buf_create_pixbuf (temp_buf);
  if (! pixbuf)
    {
      gimp_temp_buf_unref (temp_buf);
      return glims_fail (error, NULL, "Not enough memory for this thumbnail.");
    }

  pixels = clone_preview_pixels (pixbuf, &byte_count, &thumb_width, &thumb_height);
  g_object_unref (pixbuf);
  gimp_temp_buf_unref (temp_buf);

  if (! pixels)
    return glims_fail (error, NULL, "Not enough memory for this thumbnail.");

  out->bounds     = (GlimsRect) { 0, 0, thumb_width, thumb_height };
  out->pixels     = pixels;
  out->byte_count = byte_count;

  return GLIMS_STATUS_OK;
}
