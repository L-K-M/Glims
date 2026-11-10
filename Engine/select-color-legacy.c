/* Exact-3.0.8 compensation for the source-buffer leak in
 * gimp_pickable_contiguous_region_by_seed() and
 * gimp_pickable_contiguous_region_by_color(): each acquires an owned
 * GeglBuffer via gimp_pickable_get_buffer_with_effects() and returns
 * without releasing it (_engine/src/GIMP_3_0_8/gimp/app/core/
 * gimppickable-contiguous-region.cc:147, 225). Supported 3.2.0 and 3.2.8
 * already use g_clear_object on src_buffer and must not compensate.
 *
 * The workaround cannot borrow the effects buffer and must not patch
 * the algorithms, so the leak is compensated instead: the real source's
 * effects buffer is materialized once, and the unchanged algorithm runs
 * against a private proxy pickable whose get_buffer_with_effects()
 * emits one owned reference of that buffer per call and counts them.
 * After the synchronous run the counted references are exactly the ones
 * the algorithm omitted, so they are released before the proxy and the
 * materialized buffer are.
 *
 * The proxy subclasses GimpObject because GimpPickable's interface
 * prerequisite is GIMP_TYPE_OBJECT (G_DEFINE_INTERFACE in
 * gimppickable.c); a bare GObject cannot implement it. Only the
 * callbacks the unchanged algorithms reach are implemented:
 * gimp_pickable_flush() and gimp_pickable_get_buffer_with_effects(),
 * plus get_buffer() and the readable "buffer" interface property for
 * the same buffer. Everything else stays NULL like the interface
 * contract allows.
 */
#include "engine-private.h"

#include "select-color-legacy.h"

#if GIMP_MAJOR_VERSION == 3 && GIMP_MINOR_VERSION == 0 && GIMP_MICRO_VERSION == 8

#include "core/gimpobject.h"
#include "core/gimppickable.h"
#include "core/gimppickable-contiguous-region.h"


#define GLIMS_TYPE_LEGACY_PICKABLE (glims_legacy_pickable_get_type ())

typedef struct
{
  GimpObject   parent_instance;

  GeglBuffer  *buffer;   /* owned: the source's materialized effects buffer */
  guint        emitted;  /* owned refs handed out so far, for balancing */
} GlimsLegacyPickable;

typedef struct
{
  GimpObjectClass  parent_class;
} GlimsLegacyPickableClass;

enum
{
  PROP_0,
  PROP_BUFFER
};

static void         glims_legacy_pickable_get_property          (GObject               *object,
                                                                 guint                  property_id,
                                                                 GValue                *value,
                                                                 GParamSpec            *pspec);
static void         glims_legacy_pickable_dispose               (GObject               *object);
static void         glims_legacy_pickable_flush                 (GimpPickable          *pickable);
static GeglBuffer * glims_legacy_pickable_get_buffer            (GimpPickable          *pickable);
static GeglBuffer * glims_legacy_pickable_get_buffer_with_fx    (GimpPickable          *pickable);
static void         glims_legacy_pickable_pickable_init         (GimpPickableInterface *iface);
static GType        glims_legacy_pickable_get_type              (void);


G_DEFINE_TYPE_WITH_CODE (GlimsLegacyPickable, glims_legacy_pickable,
                         GIMP_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (GIMP_TYPE_PICKABLE,
                                                glims_legacy_pickable_pickable_init))


static void
glims_legacy_pickable_class_init (GlimsLegacyPickableClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->dispose      = glims_legacy_pickable_dispose;
  object_class->get_property = glims_legacy_pickable_get_property;

  /* The readable "buffer" property GimpPickable installs on every
   * implementor (gimp_pickable_default_init): it reports the same
   * buffer get_buffer() returns. */
  g_object_class_override_property (object_class, PROP_BUFFER, "buffer");
}

static void
glims_legacy_pickable_init (GlimsLegacyPickable *self)
{
  self->buffer  = NULL;
  self->emitted = 0;
}

static void
glims_legacy_pickable_get_property (GObject    *object,
                                    guint       property_id,
                                    GValue     *value,
                                    GParamSpec *pspec)
{
  GlimsLegacyPickable *self = (GlimsLegacyPickable *) object;

  switch (property_id)
    {
    case PROP_BUFFER:
      g_value_set_object (value, self->buffer);
      break;
    default:
      G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
      break;
    }
}

static void
glims_legacy_pickable_dispose (GObject *object)
{
  GlimsLegacyPickable *self = (GlimsLegacyPickable *) object;

  g_clear_object (&self->buffer);

  G_OBJECT_CLASS (glims_legacy_pickable_parent_class)->dispose (object);
}

/* No-op: the real source pickable was already flushed before its buffer
 * was materialized, and the proxy's buffer never goes stale. */
static void
glims_legacy_pickable_flush (GimpPickable *pickable)
{
  (void) pickable;
}

/* Borrowed: the proxy owns `buffer` for its whole call-scoped life. */
static GeglBuffer *
glims_legacy_pickable_get_buffer (GimpPickable *pickable)
{
  return ((GlimsLegacyPickable *) pickable)->buffer;
}

/* One owned reference per call, counted: the 3.0.8 contiguous-region
 * bodies keep every reference they acquire this way, so the count tells
 * us exactly what to release after the run. */
static GeglBuffer *
glims_legacy_pickable_get_buffer_with_fx (GimpPickable *pickable)
{
  GlimsLegacyPickable *self = (GlimsLegacyPickable *) pickable;

  self->emitted++;

  return g_object_ref (self->buffer);
}

static void
glims_legacy_pickable_pickable_init (GimpPickableInterface *iface)
{
  iface->flush                   = glims_legacy_pickable_flush;
  iface->get_buffer              = glims_legacy_pickable_get_buffer;
  iface->get_buffer_with_effects = glims_legacy_pickable_get_buffer_with_fx;
}

GeglBuffer *
glims_select_color_legacy_mask (GimpPickable *source,
                                gboolean      contiguous,
                                gboolean      antialias,
                                gfloat        threshold,
                                gint          x,
                                gint          y,
                                GeglColor    *color)
{
  GlimsLegacyPickable *proxy;
  GeglBuffer          *native;
  GeglBuffer          *mask;

  g_return_val_if_fail (GIMP_IS_PICKABLE (source), NULL);
  g_return_val_if_fail (contiguous || GEGL_IS_COLOR (color), NULL);

  /* Flush the real source like a native call would, then materialize
   * its post-effects buffer exactly once. A pickable without a buffer
   * is the only clean early out; nothing was allocated yet. */
  gimp_pickable_flush (source);
  native = gimp_pickable_get_buffer_with_effects (source);
  if (! native)
    return NULL;

  /* The proxy holds its own reference to the materialized buffer for
   * the call's duration; the unchanged algorithm only ever sees it. */
  proxy = g_object_new (GLIMS_TYPE_LEGACY_PICKABLE, NULL);
  proxy->buffer = g_object_ref (native);

  if (contiguous)
    mask = gimp_pickable_contiguous_region_by_seed (GIMP_PICKABLE (proxy),
                                                    antialias,
                                                    threshold,
                                                    TRUE /* select_transparent */,
                                                    GIMP_SELECT_CRITERION_COMPOSITE,
                                                    FALSE /* diagonal_neighbors */,
                                                    x, y);
  else
    mask = gimp_pickable_contiguous_region_by_color (GIMP_PICKABLE (proxy),
                                                     antialias,
                                                     threshold,
                                                     TRUE /* select_transparent */,
                                                     GIMP_SELECT_CRITERION_COMPOSITE,
                                                     color);

  /* Balance exactly the owned references the 3.0.8 algorithm acquired
   * through the proxy and omitted to release — no raw refcount checks,
   * and never any compensation for other callers or versions. */
  while (proxy->emitted > 0)
    {
      g_object_unref (native);
      proxy->emitted--;
    }

  g_object_unref (proxy);   /* releases the proxy's buffer reference */
  g_object_unref (native);  /* the materialized base reference */

  return mask;
}

#endif /* exact GIMP 3.0.8 */
