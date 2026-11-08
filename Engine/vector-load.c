/* GIMP 3.2.0's XCF loader converts ordinary layers to vector layers after
 * reading them. Adding the converted layer refreshes its pixels and, in
 * that release, automatically replaces its saved name with the path name.
 * Later engines restore the saved name after conversion (xcf-load.c).
 *
 * Observe native container insertion only while loading. The synchronous
 * container "add" signal precedes gimp_image_add_layer's vector refresh,
 * so disabling automatic naming there preserves the file's original name.
 * That loader also reads VectorLayerData after gimp_layer_from_layer()
 * releases the original raster layer which owns it. Retain those source
 * layers until loading finishes so the saved rasterization flag remains
 * alive; do not infer or overwrite the flag on the converted vector.
 *
 * 3.2.0 additionally re-renders the converted layer while adding it, which
 * overwrites the saved buffer of an intentionally rasterized (modified)
 * vector layer with a fresh render of the path. Later engines duplicate
 * that buffer before conversion and restore it afterwards (xcf-load.c).
 * Here the guard snapshots the saved buffer of every source whose saved
 * flag reads as modified and puts it back on the converted layer once
 * loading ends, but only when the loader itself rasterized that layer
 * (gimp_rasterizable_is_rasterized), so a genuine vector is never touched
 * and modified content never turns back into a genuine vector.
 *
 * VectorLayerData is private to the 3.2.0 XCF loader. This guard compiles
 * only for the exact 3.2.0 tag, where that struct opens with the path
 * tattoo followed by the rasterization flag (app/xcf/xcf-load.c), so the
 * two-field prefix below reads the saved flag instead of guessing it.
 * No file metadata, undo entries or upstream source changes are needed.
 */
#include "engine-private.h"

#if GIMP_CHECK_VERSION (3, 2, 0) && ! GIMP_CHECK_VERSION (3, 2, 1)
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpitem.h"
#include "core/gimprasterizable.h"
#include "core/gimpviewable.h"
#include "gegl/gimp-gegl-utils.h"
#include "path/gimpvectorlayer.h"

/* The opening of the loader-private VectorLayerData in the pinned 3.2.0
 * tag: path tattoo, then the saved rasterization flag. */
typedef struct
{
  GimpTattoo path_tattoo;
  gboolean   modified;
} GlimsVectorLayerDataPrefix;

typedef struct
{
  GimpLayer   *source;     /* retained while the load owns the vector data */
  guint        item_id;    /* shared with the layer made from source */
  gboolean     modified;   /* the saved flag, read while source was alive */
  GeglBuffer  *pixels;     /* dup of the saved buffer, only when modified */
  GimpLayer   *converted;  /* the vector layer made from source, if any */
} VectorSource;

typedef struct
{
  GimpContainer *container;
  gulong         handler;
} LoadConnection;

struct GlimsVectorLoadGuard
{
  GPtrArray  *connections;
  GHashTable *watched;
  GPtrArray  *vector_sources;   /* VectorSource* */
  GHashTable *retained_sources; /* source layer -> VectorSource* */
  GHashTable *sources_by_id;    /* item id -> VectorSource* */
};

static void watch_layers (GlimsVectorLoadGuard *guard, GimpContainer *container, gboolean imported);

static void
free_vector_source (gpointer data)
{
  VectorSource *source = data;

  g_object_unref (source->source);
  if (source->pixels)
    g_object_unref (source->pixels);
  if (source->converted)
    g_object_unref (source->converted);
  g_free (source);
}

static void
visit_layer (gpointer object, gpointer data)
{
  GlimsVectorLoadGuard *guard = data;
  GimpContainer       *children;
  gpointer             vdata = g_object_get_data (G_OBJECT (object), "gimp-vector-layer-data");

  if (vdata && g_hash_table_add (guard->retained_sources, object))
    {
      VectorSource *source = g_new0 (VectorSource, 1);

      source->source  = g_object_ref (object);
      source->item_id = gimp_item_get_id (GIMP_ITEM (object));
      /* Read the saved flag now, while the layer that owns the data is
       * alive; the loader reads it after gimp_layer_from_layer() has
       * released the original layer. */
      source->modified = ((GlimsVectorLayerDataPrefix *) vdata)->modified;
      if (source->modified)
        source->pixels = gimp_gegl_buffer_dup (gimp_drawable_get_buffer (GIMP_DRAWABLE (object)));
      g_hash_table_insert (guard->sources_by_id, GUINT_TO_POINTER (source->item_id), source);
      g_ptr_array_add (guard->vector_sources, source);
    }

  if (GIMP_IS_VECTOR_LAYER (object))
    {
      VectorSource *source;

      gimp_rasterizable_set_auto_rename (GIMP_RASTERIZABLE (object), FALSE);
      /* gimp_item_replace_item() gave the converted layer the source's
       * item id, so pair them here, before the loader rasterizes it. */
      source = g_hash_table_lookup (guard->sources_by_id,
                                    GUINT_TO_POINTER (gimp_item_get_id (GIMP_ITEM (object))));
      if (source && ! source->converted)
        source->converted = g_object_ref (object);
    }

  children = gimp_viewable_get_children (GIMP_VIEWABLE (object));
  if (children)
    watch_layers (guard, children, TRUE);
}

static void
visit_existing_layer (gpointer object, gpointer data)
{
  GimpContainer *children = gimp_viewable_get_children (GIMP_VIEWABLE (object));

  /* Existing destination layers keep their naming policy, including on
   * a failed import. Only new arrivals are load/conversion candidates. */
  if (children)
    watch_layers (data, children, FALSE);
}

static void
layer_added (GimpContainer *container, GimpObject *object, gpointer data)
{
  (void) container;
  visit_layer (object, data);
}

static void
connect_container (GlimsVectorLoadGuard *guard, GimpContainer *container, GCallback callback)
{
  LoadConnection *connection = g_new0 (LoadConnection, 1);

  connection->container = g_object_ref (container);
  connection->handler = g_signal_connect (container, "add", callback, guard);
  g_ptr_array_add (guard->connections, connection);
}

static void
watch_layers (GlimsVectorLoadGuard *guard, GimpContainer *container, gboolean imported)
{
  if (! g_hash_table_add (guard->watched, container))
    return;

  connect_container (guard, container, G_CALLBACK (layer_added));
  gimp_container_foreach (container, imported ? visit_layer : visit_existing_layer, guard);
}

static void
image_added (GimpContainer *container, GimpObject *object, gpointer data)
{
  (void) container;
  watch_layers (data, gimp_image_get_layers (GIMP_IMAGE (object)), FALSE);
}

static void
disconnect_container (gpointer data)
{
  LoadConnection *connection = data;

  g_signal_handler_disconnect (connection->container, connection->handler);
  g_object_unref (connection->container);
  g_free (connection);
}
#endif

GlimsVectorLoadGuard *
glims_vector_load_guard_begin (GlimsEngine *engine, GimpImage *destination)
{
#if GIMP_CHECK_VERSION (3, 2, 0) && ! GIMP_CHECK_VERSION (3, 2, 1)
  GlimsVectorLoadGuard *guard = g_new0 (GlimsVectorLoadGuard, 1);

  guard->connections = g_ptr_array_new_with_free_func (disconnect_container);
  guard->watched = g_hash_table_new (g_direct_hash, g_direct_equal);
  guard->vector_sources = g_ptr_array_new_with_free_func (free_vector_source);
  guard->retained_sources = g_hash_table_new (g_direct_hash, g_direct_equal);
  guard->sources_by_id = g_hash_table_new (g_direct_hash, g_direct_equal);
  connect_container (guard, engine->gimp->images, G_CALLBACK (image_added));
  if (destination)
    watch_layers (guard, gimp_image_get_layers (destination), FALSE);
  return guard;
#else
  (void) engine;
  (void) destination;
  return NULL;
#endif
}

void
glims_vector_load_guard_end (GlimsVectorLoadGuard *guard)
{
#if GIMP_CHECK_VERSION (3, 2, 0) && ! GIMP_CHECK_VERSION (3, 2, 1)
  if (guard)
    {
      /* Put the saved pixels back on converted layers whose saved flag
       * was verified as modified and which the loader rasterized, like
       * later engines do right after conversion. A genuine vector is
       * never rasterized by the loader, so it keeps its fresh render. */
      for (guint i = 0; i < guard->vector_sources->len; i++)
        {
          VectorSource *source = g_ptr_array_index (guard->vector_sources, i);

          if (source->modified && source->pixels && source->converted &&
              gimp_rasterizable_is_rasterized (GIMP_RASTERIZABLE (source->converted)))
            gimp_drawable_set_buffer (GIMP_DRAWABLE (source->converted), FALSE, NULL,
                                      source->pixels);
        }
      g_ptr_array_unref (guard->connections);
      g_hash_table_unref (guard->watched);
      g_ptr_array_unref (guard->vector_sources);
      g_hash_table_unref (guard->retained_sources);
      g_hash_table_unref (guard->sources_by_id);
      g_free (guard);
    }
#else
  (void) guard;
#endif
}
