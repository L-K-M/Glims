/* Test-only lifetime oracle for the public select_color facade.
 *
 * Links an existing, unmodified adapter/core producer. All interface changes
 * run on the engine thread, use the official GimpPickableInterface header,
 * and are restored before any image closes. Wrappers preserve the native
 * transfer-full getter contract; weak watches never acquire a strong ref.
 * One process handles one mode/sample/count case. Count zero still creates
 * and closes one unselected image, so the baseline lifetime check is real.
 */
#include "engine-private.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core/gimpimage.h"
#include "core/gimplayer.h"
#include "core/gimppickable.h"

#define MAX_BUFFERS 16
#define MAX_IMAGES 2
#define WATCH_BASE 1u
#define WATCH_EFFECTS 2u

typedef GeglBuffer * (*BufferGetter) (GimpPickable *pickable);

typedef struct
{
  gpointer identity;             /* comparison only; never dereferenced */
  gint finalized;                /* weak callback may run on any thread */
  guint flags;
  guint effects_calls;
} BufferWatch;

typedef struct
{
  gint image_finalized;
  gint layer_finalized;
} ImageWatch;

typedef struct
{
  GimpPickableInterface *iface;
  BufferGetter original_effects;
  BufferGetter original_buffer;
  BufferGetter wrapper;
  gboolean active;
} GetterHook;

typedef struct
{
  gboolean contiguous;
  gboolean merged;
  guint selections;
} Case;

static const GlimsEngineAPI *api;
static BufferWatch buffers[MAX_BUFFERS];
static ImageWatch images[MAX_IMAGES];
static GetterHook hooks[2];
static guint buffer_count;
static guint image_count;
static guint effects_calls[2];
static gint watch_overflow;
static int failures;

int main (int argc, char **argv);

#define CHECK(condition, ...)                                      \
  do {                                                            \
    gboolean passed_ = (condition);                               \
    printf ("%s ", passed_ ? "ok  " : "FAIL");                      \
    if (!passed_) failures++;                                     \
    printf (__VA_ARGS__);                                         \
    printf ("\n");                                                \
    fflush (stdout);                                              \
  } while (0)

static void
object_finalized (gpointer data, GObject *object)
{
  (void) object;
  g_atomic_int_set ((gint *) data, 1);
}

static void
watch_buffer (GeglBuffer *buffer, guint flags)
{
  guint i;
  BufferWatch *watch;

  for (i = 0; i < buffer_count; i++)
    if (!g_atomic_int_get (&buffers[i].finalized) && buffers[i].identity == buffer)
      {
        buffers[i].flags |= flags;
        buffers[i].effects_calls += (flags & WATCH_EFFECTS) != 0;
        return;
      }
  if (buffer_count == MAX_BUFFERS)
    {
      g_atomic_int_set (&watch_overflow, 1);
      return;
    }
  watch = &buffers[buffer_count++];
  watch->identity = buffer;
  watch->flags = flags;
  watch->effects_calls = (flags & WATCH_EFFECTS) != 0;
  g_atomic_int_set (&watch->finalized, 0);
  g_object_weak_ref (G_OBJECT (buffer), object_finalized, &watch->finalized);
}

static GeglBuffer *
observe_getter (guint index, GimpPickable *pickable)
{
  GetterHook *hook = &hooks[index];
  GeglBuffer *buffer = NULL;

  /* Match gimp_pickable_get_buffer_with_effects exactly. In particular,
   * the image's NULL effects vfunc falls back to ref(get_buffer()). */
  if (hook->original_effects)
    buffer = hook->original_effects (pickable);
  else if (hook->original_buffer)
    buffer = g_object_ref (hook->original_buffer (pickable));

  effects_calls[index]++;
  if (buffer)
    watch_buffer (buffer, WATCH_EFFECTS);
  return buffer;
}

static GeglBuffer *
layer_get_effects (GimpPickable *pickable)
{
  return observe_getter (0, pickable);
}

static GeglBuffer *
image_get_effects (GimpPickable *pickable)
{
  return observe_getter (1, pickable);
}

static gboolean
install_hooks (GimpLayer *layer, GimpImage *image)
{
  guint i;

  memset (hooks, 0, sizeof hooks);
  hooks[0].iface = GIMP_PICKABLE_GET_IFACE (layer);
  hooks[0].wrapper = layer_get_effects;
  hooks[1].iface = GIMP_PICKABLE_GET_IFACE (image);
  hooks[1].wrapper = image_get_effects;
  if (hooks[0].iface == hooks[1].iface)
    return FALSE;
  /* Capture both originals before changing either table. These actual
   * instance tables include the layer's inherited drawable vfunc. */
  for (i = 0; i < G_N_ELEMENTS (hooks); i++)
    {
      GetterHook *hook = &hooks[i];
      hook->original_effects = hook->iface->get_buffer_with_effects;
      hook->original_buffer = hook->iface->get_buffer;
      if ((!hook->original_effects && !hook->original_buffer) ||
          hook->original_effects == layer_get_effects ||
          hook->original_effects == image_get_effects)
        return FALSE;
    }
  for (i = 0; i < G_N_ELEMENTS (hooks); i++)
    {
      hooks[i].iface->get_buffer_with_effects = hooks[i].wrapper;
      hooks[i].active = TRUE;
    }
  return TRUE;
}

static void
restore_hooks (void)
{
  guint i;

  for (i = 0; i < G_N_ELEMENTS (hooks); i++)
    if (hooks[i].active)
      {
        CHECK (hooks[i].iface->get_buffer_with_effects == hooks[i].wrapper,
               "interface %u still holds this harness's wrapper before restore", i);
        hooks[i].iface->get_buffer_with_effects = hooks[i].original_effects;
        hooks[i].active = FALSE;
        CHECK (hooks[i].iface->get_buffer_with_effects == hooks[i].original_effects &&
               hooks[i].iface->get_buffer == hooks[i].original_buffer,
               "interface %u original getters are restored before image close", i);
      }
}

static guint
finalized_buffers (void)
{
  guint i, count = 0;

  for (i = 0; i < buffer_count; i++)
    count += g_atomic_int_get (&buffers[i].finalized) != 0;
  return count;
}

static GlimsStatus
exercise (GlimsEngine *engine, gpointer data)
{
  const Case *test = data;
  const guint fixtures = MAX (1u, test->selections);
  guint fixture;
  guchar pixels[16 * 12 * 4];

  CHECK (g_thread_self () == engine->thread, "all interface instrumentation runs on the engine thread");
  for (fixture = 0; fixture < sizeof pixels; fixture += 4)
    {
      pixels[fixture] = 255;
      pixels[fixture + 1] = pixels[fixture + 2] = 0;
      pixels[fixture + 3] = 255;
    }
  for (fixture = 0; fixture < fixtures; fixture++)
    {
      GlimsImageID id = 0;
      GlimsOpenImage *open = NULL;
      GimpImage *image = NULL;
      GimpLayer *layer = NULL;
      GimpPickable *source = NULL;
      GeglBuffer *baseline = NULL;
      GList *layers = NULL;
      char *error = NULL;
      guint previous[2] = { effects_calls[0], effects_calls[1] };
      GlimsStatus status;

      status = api->image_from_pixels (engine, 16, 12, pixels, sizeof pixels, &id, &error);
      CHECK (status == GLIMS_STATUS_OK && id > 0, "fresh public pixel image %u is created: %s",
             fixture, error ? error : "no error");
      if (status != GLIMS_STATUS_OK || !id)
        goto cleanup;
      open = glims_lookup_image (engine, id);
      image = open ? open->image : NULL;
      if (image)
        layers = gimp_image_get_layer_list (image);
      layer = layers ? layers->data : NULL;
      CHECK (image && G_OBJECT_TYPE (image) == GIMP_TYPE_IMAGE &&
             g_list_length (layers) == 1 && layer && G_OBJECT_TYPE (layer) == GIMP_TYPE_LAYER,
             "fixture %u has the exact plain image/layer interface pair", fixture);
      if (!image || !layer || g_list_length (layers) != 1 ||
          G_OBJECT_TYPE (image) != GIMP_TYPE_IMAGE || G_OBJECT_TYPE (layer) != GIMP_TYPE_LAYER)
        goto cleanup;
      if (image_count == MAX_IMAGES)
        {
          CHECK (FALSE, "bounded image-watch storage did not overflow");
          goto cleanup;
        }
      g_object_weak_ref (G_OBJECT (image), object_finalized, &images[image_count].image_finalized);
      g_object_weak_ref (G_OBJECT (layer), object_finalized, &images[image_count].layer_finalized);
      image_count++;
      source = test->merged ? GIMP_PICKABLE (image) : GIMP_PICKABLE (layer);
      gimp_pickable_flush (source);
      baseline = gimp_pickable_get_buffer (source); /* borrowed, no added ref */
      CHECK (baseline != NULL, "fixture %u exposes a borrowed baseline source buffer", fixture);
      if (!baseline)
        goto cleanup;
      watch_buffer (baseline, WATCH_BASE);
      if (!install_hooks (layer, image))
        {
          CHECK (FALSE, "fixture %u cannot transparently wrap both original interfaces", fixture);
          goto cleanup;
        }
      if (test->selections)
        {
          GlimsSelectOptions options = {0};
          GlimsRect bounds = {0};
          bool empty = true;

          options.struct_size = sizeof options;
          options.operation = GLIMS_SELECT_REPLACE;
          options.threshold = 0.0;
          options.contiguous = test->contiguous;
          options.sample_merged = test->merged;
          status = api->select_color (engine, id, (GlimsPoint) {4, 4}, &options, &error);
          CHECK (status == GLIMS_STATUS_OK, "public color selection %u succeeds: %s",
                 fixture, error ? error : "no error");
          CHECK (api->selection_bounds (engine, id, &empty, &bounds) == GLIMS_STATUS_OK &&
                 !empty && bounds.x == 0 && bounds.y == 0 && bounds.width == 16 && bounds.height == 12,
                 "public selection %u covers the independently known solid image", fixture);
        }
      CHECK (effects_calls[test->merged ? 1 : 0] - previous[test->merged ? 1 : 0] == (test->selections ? 1u : 0u) &&
             effects_calls[test->merged ? 0 : 1] == previous[test->merged ? 0 : 1],
             "fixture %u observes exactly the selected source's one owned getter, or zero for control", fixture);
cleanup:
      restore_hooks ();
      g_list_free (layers);
      if (error)
        api->free_string (error);
      if (id)
        {
          GlimsImageInfo info = {0};
          CHECK (api->image_close (engine, id) == GLIMS_STATUS_OK,
                 "fixture %u public image closes after restoring interfaces", fixture);
          CHECK (api->image_info (engine, id, &info) == GLIMS_STATUS_NOT_FOUND,
                 "fixture %u has no remaining public image handle", fixture);
        }
    }
  printf ("OBS after image close: watched=%u finalized=%u effects_calls=%u/%u\n",
          buffer_count, finalized_buffers (), effects_calls[0], effects_calls[1]);
  fflush (stdout);
  return failures ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  Case test;
  GlimsEngineConfig config = {0};
  GlimsEngine *engine = NULL;
  GlimsStatus status;
  gchar *home, *cache, *user, *temporary;
  char *error = NULL;
  guint i, effects_unique = 0, survivors = 0, effects_survivors = 0;

  if (argc != 5 || (strcmp (argv[2], "0") && strcmp (argv[2], "1")) ||
      (strcmp (argv[3], "0") && strcmp (argv[3], "1")) || strlen (argv[4]) != 1 ||
      argv[4][0] < '0' || argv[4][0] > '2')
    {
      fprintf (stderr, "usage: %s WORK CONTIGUOUS_0_OR_1 MERGED_0_OR_1 SELECTION_COUNT_0_TO_2\n", argv[0]);
      return 2;
    }
  test.contiguous = argv[2][0] == '1';
  test.merged = argv[3][0] == '1';
  test.selections = (guint) (argv[4][0] - '0');
  home = g_build_filename (argv[1], "home", NULL);
  cache = g_build_filename (argv[1], "cache", NULL);
  user = g_build_filename (argv[1], "user", NULL);
  temporary = g_build_filename (argv[1], "tmp", NULL);
  if (g_strcmp0 (g_getenv ("HOME"), home) || g_strcmp0 (g_getenv ("XDG_CACHE_HOME"), cache) ||
      g_strcmp0 (g_getenv ("GIMP3_DIRECTORY"), user) || g_strcmp0 (g_getenv ("TMPDIR"), temporary))
    {
      fprintf (stderr, "refusing non-private environment; use scripts/test-select-color-ownership.py run\n");
      g_free (home); g_free (cache); g_free (user); g_free (temporary);
      return 2;
    }
  config.struct_size = sizeof config;
  config.user_directory = user;
  config.cache_directory = cache;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < sizeof *api || api->api_version != GLIMS_ENGINE_API_VERSION)
    {
      fprintf (stderr, "producer facade version/size does not match the harness\n");
      g_free (home); g_free (cache); g_free (user); g_free (temporary);
      return 2;
    }
  status = api->start (&config, &engine, &error);
  CHECK (status == GLIMS_STATUS_OK && engine, "private engine starts: %s", error ? error : "no error");
  if (error)
    api->free_string (error);
  if (!engine || status != GLIMS_STATUS_OK)
    {
      g_free (home); g_free (cache); g_free (user); g_free (temporary);
      return 1;
    }
  printf ("CASE engine=%s contiguous=%u merged=%u selections=%u\n",
          api->engine_version (engine), (guint) test.contiguous, (guint) test.merged, test.selections);
  status = glims_engine_call (engine, exercise, &test);
  api->stop (engine);
  /* Callback storage is static and survives engine shutdown; read callback
   * flags atomically. No dead watched pointer is dereferenced here. */
  CHECK (!g_atomic_int_get (&watch_overflow), "bounded weak-watch storage did not overflow");
  CHECK (image_count == MAX (1u, test.selections), "all fresh image fixtures were observed");
  CHECK (effects_calls[test.merged ? 1 : 0] == test.selections &&
         effects_calls[test.merged ? 0 : 1] == 0,
         "owned getter call count is exactly the public selection count");
  for (i = 0; i < image_count; i++)
    CHECK (g_atomic_int_get (&images[i].image_finalized) && g_atomic_int_get (&images[i].layer_finalized),
           "fixture %u image and layer lifetime ended by engine stop", i);
  for (i = 0; i < buffer_count; i++)
    {
      gboolean finalized = g_atomic_int_get (&buffers[i].finalized) != 0;
      effects_unique += (buffers[i].flags & WATCH_EFFECTS) != 0;
      survivors += !finalized;
      effects_survivors += !finalized && (buffers[i].flags & WATCH_EFFECTS) != 0;
      CHECK (finalized, "source buffer %u lifetime ended after image close and engine stop (flags=%u, owned_calls=%u)",
             i, buffers[i].flags, buffers[i].effects_calls);
    }
  CHECK (buffer_count >= MAX (1u, test.selections) && effects_unique == test.selections,
         "zero control has a real source watch; fresh selections expose distinct owned source buffers");
  printf ("OBS after engine stop: watched=%u finalized=%u effects_unique=%u effects_calls=%u survivors=%u effects_survivors=%u\n",
          buffer_count, finalized_buffers (), effects_unique, effects_calls[0] + effects_calls[1], survivors, effects_survivors);
  printf ("%s: %d failure(s)\n", failures || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED", failures);
  g_free (home); g_free (cache); g_free (user); g_free (temporary);
  return failures || status != GLIMS_STATUS_OK ? 1 : 0;
}
