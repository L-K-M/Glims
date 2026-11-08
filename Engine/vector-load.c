/* GIMP 3.2.0's XCF loader converts ordinary layers to vector layers after
 * reading them. Adding the converted layer refreshes its pixels and, in
 * that release, automatically replaces its saved name with the path name.
 * Later engines restore the saved name after conversion (xcf-load.c).
 *
 * That loader also reads VectorLayerData after gimp_layer_from_layer()
 * releases the original raster layer which owns it (3.2.0's xcf-load.c
 * touches vdata->modified after the conversion unrefs the source layer,
 * while 3.2.8 snapshots the flag first). Retain those source layers until
 * loading finishes so the saved rasterization flag stays alive; do not
 * infer or overwrite the flag on the converted vector.
 *
 * Observe native container insertion only while loading. The synchronous
 * container "add" signal precedes gimp_image_add_layer's vector refresh,
 * so disabling automatic naming there preserves the file's original name.
 * No file metadata, undo entries or upstream source changes are needed.
 */
#include "engine-private.h"

#if GIMP_CHECK_VERSION (3, 2, 0) && ! GIMP_CHECK_VERSION (3, 2, 1)
#include "core/gimp.h"
#include "core/gimpcontainer.h"
#include "core/gimpimage.h"
#include "core/gimprasterizable.h"
#include "core/gimpviewable.h"
#include "path/gimpvectorlayer.h"

typedef struct
{
  GimpContainer *container;
  gulong         handler;
} LoadConnection;

struct GlimsVectorLoadGuard
{
  GPtrArray  *connections;
  GHashTable *watched;
  GPtrArray  *vector_sources;
  GHashTable *retained_sources;
};

static void watch_layers (GlimsVectorLoadGuard *guard, GimpContainer *container, gboolean imported);

static void
visit_layer (gpointer object, gpointer data)
{
  GlimsVectorLoadGuard *guard = data;
  GimpContainer       *children;

  if (g_object_get_data (G_OBJECT (object), "gimp-vector-layer-data") &&
      g_hash_table_add (guard->retained_sources, object))
    g_ptr_array_add (guard->vector_sources, g_object_ref (object));

  if (GIMP_IS_VECTOR_LAYER (object))
    gimp_rasterizable_set_auto_rename (GIMP_RASTERIZABLE (object), FALSE);

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
  guard->vector_sources = g_ptr_array_new_with_free_func (g_object_unref);
  guard->retained_sources = g_hash_table_new (g_direct_hash, g_direct_equal);
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
      g_ptr_array_unref (guard->connections);
      g_hash_table_unref (guard->watched);
      g_ptr_array_unref (guard->vector_sources);
      g_hash_table_unref (guard->retained_sources);
      g_free (guard);
    }
#else
  (void) guard;
#endif
}
