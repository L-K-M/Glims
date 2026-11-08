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

#include <string.h>

#include "core/gimp.h"
#include "core/gimpbrush.h"
#include "core/gimpcontainer.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpgradient.h"
#include "core/gimpobject.h"
#include "core/gimppattern.h"

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
