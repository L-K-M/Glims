/*
 * gradient-create-facade-tests.c — standalone facade-only tests for the
 * PUBLIC resource_create_gradient (facade slot 138). The producer adapter
 * is loaded with dlopen() exactly as the app does, and only the public
 * facade in glims_engine.h is used — no GIMP/GLib/GEGL types or headers,
 * no private struct layouts, no engine objects, no libgimp.
 *
 *   gradient-create-facade-tests LIBRARY WORK_DIR create|verify
 *
 * The engine starts only once per process, so scripts/
 * test-gradient-create-facade.py runs this binary twice on one isolated
 * WORK_DIR: "create" exercises the public slot end to end and records the
 * persisted identity triplets in WORK_DIR/handoff.txt (a plain owned
 * file, no KeyFile); "verify" starts a fresh engine on the same
 * directories and checks that the saved gradients reload and resolve by
 * their exact name/collection/internal triplet (never a NULL collection
 * for a file-backed resource).
 *
 * The source guards the API version AND the struct_size reaching slot 138
 * BEFORE dereferencing the new member: an older 137-slot producer refuses
 * cleanly here instead of reading past its table.
 *
 * Every direct facade call is made with the native output prefilled to a
 * nonzero sentinel immediately before the call (no wrapper pre-zeroing),
 * so a missing output reset on any path is caught. Everything the test
 * touches lives under WORK_DIR. Prints one line per check and exits
 * non-zero if any check fails.
 */
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "glims_engine.h"

static const GlimsEngineAPI *api;
static GlimsEngine          *engine;
static int                   failures;

typedef GlimsStatus (*CreateGradientFn) (GlimsEngine *, const char *,
                                         const GlimsColor *, const GlimsColor *,
                                         GlimsResourceID *, char **);
/* Read from the table only after the struct_size guard passed. */
static CreateGradientFn create_gradient;

#define CHECK(condition, ...)                     \
  do {                                            \
    if (condition) {                              \
      printf ("ok    ");                          \
    } else {                                      \
      printf ("FAIL  ");                          \
      failures++;                                 \
    }                                             \
    printf (__VA_ARGS__);                         \
    printf ("\n");                                \
    fflush (stdout);                              \
  } while (0)

/* .25/.5/.75 vs .75/.25/.5 endpoints: the left edge is red-poorer than
 * the right edge, which the LIMITED thumbnail oracle below relies on. */
static const GlimsColor LEFT  = { 0.25, 0.5, 0.75, 0.9 };
static const GlimsColor RIGHT = { 0.75, 0.25, 0.5, 0.1 };
#define NAME_A "glims-facade-grad-a"
#define NAME_B "glims-facade-grad-b"
#define PREFILL 0xFEEDBEEFCAFEF00DULL

static char work[4096];
static char user_dir[4096], cache_dir[4096], gradient_dir[4096];

static void
path_join (char *out, size_t cap, const char *a, const char *b)
{
  snprintf (out, cap, "%s/%s", a, b);
}

static int
mkdir_p (const char *path)
{
  char tmp[4096];
  size_t len = strlen (path);
  size_t i;

  if (len >= sizeof tmp)
    return -1;
  memcpy (tmp, path, len + 1);
  for (i = 1; i < len; i++)
    if (tmp[i] == '/')
      {
        tmp[i] = '\0';
        if (mkdir (tmp, 0700) != 0 && errno != EEXIST)
          return -1;
        tmp[i] = '/';
      }
  if (mkdir (tmp, 0700) != 0 && errno != EEXIST)
    return -1;
  return 0;
}

static int
read_all (const char *path, uint8_t **buf, size_t *len)
{
  FILE    *f = fopen (path, "rb");
  uint8_t *data;
  long     size;

  if (! f)
    return -1;
  if (fseek (f, 0, SEEK_END) != 0 || (size = ftell (f)) < 0 ||
      fseek (f, 0, SEEK_SET) != 0)
    {
      fclose (f);
      return -1;
    }
  data = malloc (size > 0 ? (size_t) size : 1);
  if (! data)
    {
      fclose (f);
      return -1;
    }
  if (size > 0 && fread (data, 1, (size_t) size, f) != (size_t) size)
    {
      free (data);
      fclose (f);
      return -1;
    }
  fclose (f);
  *buf = data;
  *len = (size_t) size;
  return 0;
}

static int
write_all (const char *path, const char *data, size_t len)
{
  FILE *f = fopen (path, "wb");

  if (! f)
    return -1;
  if (len > 0 && fwrite (data, 1, len, f) != len)
    {
      fclose (f);
      return -1;
    }
  return fclose (f) == 0 ? 0 : -1;
}

static unsigned long long
fnv1a (const uint8_t *data, size_t len)
{
  unsigned long long h = 1469598103934665603ULL;
  size_t i;

  for (i = 0; i < len; i++)
    h = (h ^ data[i]) * 1099511628211ULL;
  return h;
}

/* Regular-file count and staging-leftover count of one directory. */
static int
dir_stats (const char *path, int *staging)
{
  DIR           *d = opendir (path);
  struct dirent *e;
  int            n = 0;

  *staging = 0;
  if (! d)
    return 0;
  while ((e = readdir (d)))
    {
      char         full[4200];
      struct stat  st;

      if (strncmp (e->d_name, ".glims-stage-", 13) == 0)
        (*staging)++;
      if (e->d_name[0] == '.')
        continue;
      path_join (full, sizeof full, path, e->d_name);
      if (stat (full, &st) == 0 && S_ISREG (st.st_mode))
        n++;
    }
  closedir (d);
  return n;
}

/* ---- facade wrappers ---------------------------------------------------- */

/* The direct facade call with the native output prefilled to a nonzero
 * sentinel IMMEDIATELY before the call: the bridge must reset it on every
 * path (NOT_RUNNING included), so no wrapper may pre-zero it. */
static GlimsStatus
call_create (GlimsEngine *e, const char *name, const GlimsColor *l, const GlimsColor *r,
             GlimsResourceID *out, char **err)
{
  *out = PREFILL;
  if (err)
    *err = NULL;
  return create_gradient (e, name, l, r, out, err);
}

static void
expect_refusal (GlimsStatus want, const char *name, const GlimsColor *l,
                const GlimsColor *r, const char *what)
{
  GlimsResourceID out = 0;
  char           *err = NULL;
  GlimsStatus     st = call_create (engine, name, l, r, &out, &err);

  CHECK (st == want && out == 0, "%s: want status %d with out 0 (got %d/%llu)",
         what, (int) want, (int) st, (unsigned long long) out);
  if (want == GLIMS_STATUS_INVALID_ARGUMENT || want == GLIMS_STATUS_FAILED)
    CHECK (err != NULL, "%s: error message set", what);
  if (err)
    api->free_string (err);
}

static int
get_resources (uint32_t kind, GlimsResourceInfo **rows_out, int32_t *n_out)
{
  int32_t             n = 0;
  GlimsResourceInfo  *rows = NULL;

  if (api->resources (engine, kind, NULL, 0, &n) != GLIMS_STATUS_OK)
    return 0;
  if (n > 0)
    {
      rows = calloc ((size_t) n, sizeof *rows);
      if (! rows)
        return 0;
      if (api->resources (engine, kind, rows, n, &n) != GLIMS_STATUS_OK)
        {
          free (rows);
          return 0;
        }
    }
  *rows_out = rows;
  *n_out = n;
  return 1;
}

static int
row_by_id (const GlimsResourceInfo *rows, int32_t n, GlimsResourceID id, const char *name)
{
  int32_t i;

  for (i = 0; i < n; i++)
    if (rows[i].id == id && (! name || strcmp (rows[i].name, name) == 0))
      return 1;
  return 0;
}

static GlimsStatus
identifiers (GlimsResourceID id, char **name, char **collection, bool *internal)
{
  char *err = NULL;

  *name = *collection = NULL;
  *internal = false;
  return api->resource_identifiers (engine, id, name, collection, internal, &err);
}

static int
catalog_count (uint32_t kind)
{
  int32_t n = 0;

  return api->resources (engine, kind, NULL, 0, &n) == GLIMS_STATUS_OK ? n : -1;
}

/* Bounded, owned thumbnail read plus the LIMITED pixel oracle: with
 * LEFT.red < RIGHT.red the leftmost pixel's red byte must be below the
 * rightmost one's. This is deliberately only an endpoint-order oracle —
 * the exact segment colors and static stops are the Core harness's job
 * (Engine/tests/gradient-create-tests.c), not claimed here. */
static int
check_thumbnail (GlimsResourceID id, int32_t max_size, const char *label)
{
  GlimsPixelBuffer buf = { 0 };
  char            *err = NULL;
  int              ok = 0;
  int32_t          w, h;
  size_t           bytes;

  if (api->resource_thumbnail (engine, id, max_size, NULL, NULL, &buf, &err) != GLIMS_STATUS_OK)
    {
      CHECK (0, "%s: resource_thumbnail failed: %s", label, err ? err : "?");
      if (err)
        api->free_string (err);
      return 0;
    }
  w = buf.bounds.width;
  h = buf.bounds.height;
  bytes = (size_t) w * (size_t) h * 4;
  CHECK (buf.bounds.x == 0 && buf.bounds.y == 0 && w > 0 && h > 0 &&
         w <= max_size && h <= max_size && buf.pixels != NULL &&
         buf.byte_count == bytes && bytes > 0,
         "%s: thumbnail bounded and nonempty (%dx%d, %zu bytes)", label, w, h, buf.byte_count);
  if (buf.pixels && buf.byte_count == bytes && w > 0 && h > 0)
    {
      /* Gradients come back exactly max_size x max(1, max_size/2). */
      CHECK (w == max_size && h == (max_size > 1 ? max_size / 2 : 1),
             "%s: gradient thumbnail is exactly %dx%d", label, max_size,
             max_size > 1 ? max_size / 2 : 1);
      ok = buf.pixels[0] < buf.pixels[(buf.byte_count - 4)];
      CHECK (ok, "%s: LIMITED oracle — leftmost red %u < rightmost red %u",
             label, buf.pixels[0], buf.pixels[buf.byte_count - 4]);
    }
  api->free_pixels (buf.pixels);  /* owned cleanup on every path */
  return ok;
}

/* One rendered-pixels hash + info/undo/selection snapshot of the image. */
typedef struct {
  bool                dirty;
  int32_t             w, h;
  int32_t             undo, redo;
  unsigned long long  pix;
  GlimsItemID         sel[8];
  int32_t             sel_n;
} Snap;

static int
snapshot (GlimsImageID img, Snap *s)
{
  GlimsImageInfo info;
  GlimsUndoInfo  undo;
  uint8_t       *px;

  memset (s, 0, sizeof *s);
  if (api->image_info (engine, img, &info) != GLIMS_STATUS_OK ||
      api->image_undo_info (engine, img, &undo) != GLIMS_STATUS_OK)
    return -1;
  s->dirty = info.dirty;
  s->w = info.width;
  s->h = info.height;
  s->undo = undo.undo_count;
  s->redo = undo.redo_count;
  px = calloc ((size_t) info.width * (size_t) info.height, 4);
  if (! px)
    return -1;
  if (api->image_render (engine, img, 1.0,
                         (GlimsRect) { 0, 0, info.width, info.height },
                         px, (size_t) info.width * 4) != GLIMS_STATUS_OK)
    {
      free (px);
      return -1;
    }
  s->pix = fnv1a (px, (size_t) info.width * (size_t) info.height * 4);
  free (px);
  s->sel_n = 0;
  if (api->image_selected_items (engine, img, GLIMS_ITEM_SET_LAYER, s->sel, 8,
                                 &s->sel_n) != GLIMS_STATUS_OK)
    return -1;
  return 0;
}

static int
snap_equal (const Snap *a, const Snap *b)
{
  return a->dirty == b->dirty && a->w == b->w && a->h == b->h &&
         a->undo == b->undo && a->redo == b->redo && a->pix == b->pix &&
         a->sel_n == b->sel_n &&
         (a->sel_n == 0 || memcmp (a->sel, b->sel, sizeof a->sel[0] * (size_t) a->sel_n) == 0);
}

static int
start_engine (void)
{
  GlimsEngineConfig config = { 0 };
  char             *error = NULL;

  path_join (user_dir, sizeof user_dir, work, "user");
  path_join (cache_dir, sizeof cache_dir, work, "cache");
  path_join (gradient_dir, sizeof gradient_dir, user_dir, "gradients");
  if (strncmp (gradient_dir, work, strlen (work)) != 0)
    {
      fprintf (stderr, "FAIL  gradient folder escapes WORK_DIR\n");
      return 0;
    }
  mkdir_p (user_dir);
  mkdir_p (cache_dir);

  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "start: %s\n", error ? error : "unknown");
      if (error)
        api->free_string (error);
      return 0;
    }
  return 1;
}

/* Exact identity triplet roundtrip through the public resolve: the actual
 * collection string is passed back — never NULL for a file-backed
 * resource. */
static int
identity_roundtrip (GlimsResourceID id, const char *label)
{
  char           *name = NULL, *coll = NULL, *err = NULL;
  bool            internal = true;
  GlimsResourceID rt = 0;
  int             ok = 0;

  if (identifiers (id, &name, &coll, &internal) != GLIMS_STATUS_OK || ! name)
    {
      CHECK (0, "%s: resource_identifiers failed", label);
      goto done;
    }
  CHECK (name && strcmp (name, label) == 0 && coll != NULL && ! internal,
         "%s: identity triplet name='%s' collection non-NULL internal=false",
         label, name);
  if (api->resource_resolve (engine, GLIMS_RESOURCE_GRADIENT, name, coll, internal,
                             &rt, &err) == GLIMS_STATUS_OK && rt == id)
    {
      CHECK (1, "%s: exact identity triplet resolves back to id %llu", label,
             (unsigned long long) id);
      ok = 1;
    }
  else
    CHECK (0, "%s: exact identity triplet resolve (got %llu)", label,
           (unsigned long long) rt);
done:
  if (name)  api->free_string (name);
  if (coll)  api->free_string (coll);
  if (err)   api->free_string (err);
  return ok;
}

/* ---- phase create ------------------------------------------------------- */

static int
phase_create (void)
{
  static const char *const bad_names[] = { "", "\xC3\x28", "a\tb", " x", "x " };
  static const char *const bad_what[] = { "empty name", "invalid UTF-8", "Cc control",
                                          "leading ASCII space", "trailing ASCII space" };
  GlimsImageID  img = 0;
  GlimsItemID   layer = 0;
  GlimsLayerInfo lrow;
  int32_t       ln = 0;
  GlimsColor    fill = { 0.1, 0.2, 0.3, 1.0 };
  char         *err = NULL;
  Snap          before, after;
  int           cat0, cat1, files0, files1, staging;
  GlimsResourceID id_a = 0, id_b = 0;
  int           i;

  if (! start_engine ())
    return 1;

  /* Fixture: one open image, cleared once (its undo step is part of the
   * fixture, before the baseline). */
  CHECK (api->image_new (engine, 16, 12, &img, &err) == GLIMS_STATUS_OK && img != 0,
         "fixture image created");
  CHECK (api->image_layers (engine, img, &lrow, 1, &ln) == GLIMS_STATUS_OK && ln == 1,
         "fixture layer listed");
  layer = lrow.id;
  CHECK (api->image_clear (engine, img, &fill, &err) == GLIMS_STATUS_OK,
         "fixture image cleared");

  /* BUSY via public stroke/filter sessions only, then undone/aborted so
   * the preservation baseline starts clean. */
  {
    GlimsBrushSettings brush;
    GlimsStrokePoint   first = { 2, 2, 1, 0, 0, 0 };
    GlimsStrokeID      stroke = 0;
    GlimsFilterID      filter = 0;

    memset (&brush, 0, sizeof brush);
    brush.struct_size = sizeof brush;
    brush.size = 9.0;
    brush.opacity = 1.0;
    brush.tool = GLIMS_PAINT_PAINTBRUSH;
    brush.hardness = brush.rate = brush.flow = brush.exposure = -1.0;
    CHECK (api->stroke_begin (engine, img, layer, &brush, &first, &stroke, &err) ==
           GLIMS_STATUS_OK && stroke != 0, "probe stroke begun for BUSY");
    expect_refusal (GLIMS_STATUS_BUSY, "glims-facade-busy-stroke", &LEFT, &RIGHT,
                    "create during an open stroke is BUSY");
    CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "probe stroke ended");
    CHECK (api->image_undo (engine, img) == GLIMS_STATUS_OK, "probe stroke undone");
    CHECK (api->filter_begin (engine, img, layer, "gegl:gaussian-blur", &filter, &err) ==
           GLIMS_STATUS_OK && filter != 0, "probe filter begun for BUSY");
    expect_refusal (GLIMS_STATUS_BUSY, "glims-facade-busy-filter", &LEFT, &RIGHT,
                    "create during an open filter is BUSY");
    CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "probe filter aborted");
  }

  /* Preservation baseline after the probes. */
  CHECK (snapshot (img, &before) == 0, "baseline snapshot taken");
  cat0 = catalog_count (GLIMS_RESOURCE_GRADIENT);
  files0 = dir_stats (gradient_dir, &staging);

  /* NULL engine: valid inputs dispatch to NOT_RUNNING and the bridge
   * still clears the prefilled output. No fake non-NULL engine pointer
   * is ever dereferenced. */
  {
    GlimsResourceID out = 0;
    char           *e2 = NULL;
    GlimsStatus     st = call_create (NULL, "glims-facade-null-engine", &LEFT, &RIGHT, &out, &e2);

    CHECK (st == GLIMS_STATUS_NOT_RUNNING && out == 0,
           "NULL engine -> NOT_RUNNING with prefilled out cleared (got %d/%llu)",
           (int) st, (unsigned long long) out);
    if (e2)
      api->free_string (e2);
  }

  /* Required-pointer refusals with a running engine (validated inside the
   * creator without pre-dereference). */
  expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, NULL, &LEFT, &RIGHT, "NULL name");
  expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, "glims-facade-null-left", NULL, &RIGHT, "NULL left");
  expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, "glims-facade-null-right", &LEFT, NULL, "NULL right");
  {
    char *e2 = NULL;
    GlimsStatus st = create_gradient (engine, "glims-facade-null-out", &LEFT, &RIGHT, NULL, &e2);

    CHECK (st == GLIMS_STATUS_INVALID_ARGUMENT && e2 != NULL,
           "NULL out -> INVALID_ARGUMENT with error message");
    if (e2)
      api->free_string (e2);
  }

  /* Name battery: empty, invalid UTF-8, over-255-byte, Cc control, and the
   * two GGR ASCII edge-whitespace cases. */
  for (i = 0; i < 5; i++)
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, bad_names[i], &LEFT, &RIGHT, bad_what[i]);
  {
    char longname[257];

    memset (longname, 'a', 256);
    longname[256] = '\0';
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, longname, &LEFT, &RIGHT, "256-byte name");
  }

  /* Endpoint battery: NaN / +Inf / out-of-range, on the LEFT and the RIGHT
   * endpoint, alpha included. */
  {
    GlimsColor bad;

    bad = LEFT;  bad.red = NAN;       expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, "glims-facade-bad-1", &bad, &RIGHT, "NaN in left.red");
    bad = RIGHT; bad.alpha = INFINITY; expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, "glims-facade-bad-2", &LEFT, &bad, "+Inf in right.alpha");
    bad = LEFT;  bad.green = -0.1;     expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, "glims-facade-bad-3", &bad, &RIGHT, "-0.1 in left.green");
    bad = RIGHT; bad.blue = 1.1;       expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, "glims-facade-bad-4", &LEFT, &bad, "1.1 in right.blue");
  }

  /* Real public create -> catalog row with the current id -> exact
   * identity triplet roundtrip -> bounded thumbnail with the limited
   * oracle. */
  {
    GlimsResourceInfo *rows = NULL;
    int32_t            n = 0;

    CHECK (call_create (engine, NAME_A, &LEFT, &RIGHT, &id_a, &err) == GLIMS_STATUS_OK &&
           id_a > 0, "valid create OK, id %llu%s%s", (unsigned long long) id_a,
           err ? ": " : "", err ? err : "");
    if (err) { api->free_string (err); err = NULL; }
    CHECK (get_resources (GLIMS_RESOURCE_GRADIENT, &rows, &n) &&
           row_by_id (rows, n, id_a, NAME_A),
           "gradient catalog lists the new current id with name '%s'", NAME_A);
    free (rows);
    identity_roundtrip (id_a, NAME_A);
    check_thumbnail (id_a, 32, "created gradient");
    expect_refusal (GLIMS_STATUS_FAILED, NAME_A, &LEFT, &RIGHT,
                    "exact duplicate name FAILED, out cleared");
  }
  CHECK (call_create (engine, NAME_B, &LEFT, &RIGHT, &id_b, &err) == GLIMS_STATUS_OK &&
         id_b > 0 && id_b != id_a, "second create OK, distinct id %llu",
         (unsigned long long) id_b);
  if (err) { api->free_string (err); err = NULL; }
  identity_roundtrip (id_b, NAME_B);

  /* The battery preserved image, history, selection and catalog/files
   * except the two intended creates. Context and clipboard have no public
   * facade reader, so they are not observable here. */
  CHECK (snapshot (img, &after) == 0 && snap_equal (&before, &after),
         "image pixels/dirty/undo/selection unchanged by the battery");
  cat1 = catalog_count (GLIMS_RESOURCE_GRADIENT);
  files1 = dir_stats (gradient_dir, &staging);
  CHECK (cat1 == cat0 + 2, "gradient catalog grew by exactly 2 (%d -> %d)", cat0, cat1);
  CHECK (files1 == files0 + 2, "writable gradient folder grew by exactly 2 files (%d -> %d)",
         files0, files1);
  CHECK (staging == 0, "no staging leftovers in the gradient folder");

  /* Persist the actual identity triplets in a plain owned file (no
   * KeyFile) for the fresh-process verify phase. */
  {
    char handoff[4096], buf[2400] = "";
    size_t off = 0;
    GlimsResourceID ids[2] = { id_a, id_b };

    path_join (handoff, sizeof handoff, work, "handoff.txt");
    for (i = 0; i < 2; i++)
      {
        char *nm = NULL, *coll = NULL;
        bool  internal = true;

        if (identifiers (ids[i], &nm, &coll, &internal) == GLIMS_STATUS_OK && nm && coll)
          off += (size_t) snprintf (buf + off, sizeof buf - off, "%s\t%s\t%d\n",
                                    nm, coll, internal ? 1 : 0);
        else
          CHECK (0, "identity of created gradient %llu readable for handoff",
                 (unsigned long long) ids[i]);
        if (nm)   api->free_string (nm);
        if (coll) api->free_string (coll);
      }
    CHECK (write_all (handoff, buf, strlen (buf)) == 0,
           "plain handoff file written (%zu bytes)", strlen (buf));
  }

  CHECK (api->image_close (engine, img) == GLIMS_STATUS_OK, "fixture image closed");
  api->stop (engine);
  engine = NULL;
  return 0;
}

/* ---- phase verify (fresh engine process on the same WORK_DIR) ----------- */

static int
phase_verify (void)
{
  char handoff[4096];
  uint8_t *data = NULL;
  size_t   len = 0;
  char    *cursor;
  int      entries = 0;

  if (! start_engine ())
    return 1;
  path_join (handoff, sizeof handoff, work, "handoff.txt");
  CHECK (read_all (handoff, &data, &len) == 0 && len > 0,
         "verify reads the plain handoff file from the create phase");
  if (! data)
    {
      api->stop (engine);
      return 1;
    }
  cursor = (char *) data;
  while (cursor && *cursor && entries < 8)
    {
      char *eol = strchr (cursor, '\n');
      char *tab1, *tab2;
      char  name[256], coll[512];
      int   internal;
      GlimsResourceID id = 0;
      char *err = NULL;
      GlimsResourceInfo *rows = NULL;
      int32_t n = 0;

      if (! eol)
        break;
      *eol = '\0';
      tab1 = strchr (cursor, '\t');
      tab2 = tab1 ? strchr (tab1 + 1, '\t') : NULL;
      if (! tab1 || ! tab2)
        {
          CHECK (0, "handoff line parseable: '%s'", cursor);
          cursor = eol + 1;
          continue;
        }
      *tab1 = '\0';
      *tab2 = '\0';
      snprintf (name, sizeof name, "%s", cursor);
      snprintf (coll, sizeof coll, "%s", tab1 + 1);
      internal = atoi (tab2 + 1);
      cursor = eol + 1;
      entries++;

      /* Fresh process: resolve by the EXACT persisted triplet — the actual
       * collection, never NULL for this file-backed resource. */
      CHECK (api->resource_resolve (engine, GLIMS_RESOURCE_GRADIENT, name, coll,
                                    internal, &id, &err) == GLIMS_STATUS_OK && id > 0,
             "after reload: resolve('%s') -> id %llu", name, (unsigned long long) id);
      if (err) { api->free_string (err); err = NULL; }
      CHECK (get_resources (GLIMS_RESOURCE_GRADIENT, &rows, &n) && row_by_id (rows, n, id, name),
             "after reload: catalog contains '%s' under the resolved id", name);
      free (rows);
      identity_roundtrip (id, name);
      check_thumbnail (id, 32, "reloaded gradient");
      {
        /* The durable .ggr file itself carries the exact name line. */
        DIR           *d = opendir (gradient_dir);
        struct dirent *e;
        int            file_ok = 0;
        char           want[300];

        snprintf (want, sizeof want, "Name: %s\n", name);
        while (d && (e = readdir (d)) && ! file_ok)
          {
            char full[4200];
            uint8_t *fb = NULL;
            size_t   fl = 0;

            if (! strstr (e->d_name, ".ggr"))
              continue;
            path_join (full, sizeof full, gradient_dir, e->d_name);
            if (read_all (full, &fb, &fl) == 0 && fl > 0)
              {
                /* NUL-terminate a bounded copy for the strstr oracle. */
                char *text = malloc (fl + 1);

                memcpy (text, fb, fl);
                text[fl] = '\0';
                file_ok = strstr (text, want) != NULL;
                free (text);
              }
            free (fb);
          }
        if (d)
          closedir (d);
        CHECK (file_ok, "after reload: a saved .ggr file carries 'Name: %s'", name);
      }
    }
  free (data);
  CHECK (entries == 2, "verify checked both handed-over gradients (%d)", entries);
  api->stop (engine);
  engine = NULL;
  return 0;
}

int
main (int argc, char **argv)
{
  void                    *library;
  GlimsEngineGetAPIFunction get_api;
  size_t                   slot_end;

  if (argc != 4 || (strcmp (argv[3], "create") != 0 && strcmp (argv[3], "verify") != 0))
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR create|verify\n", argv[0]);
      return 2;
    }

  snprintf (work, sizeof work, "%s", argv[2]);
  while (strlen (work) > 1 && work[strlen (work) - 1] == '/')
    work[strlen (work) - 1] = '\0';

  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (! library)
    {
      fprintf (stderr, "dlopen: %s\n", dlerror ());
      return 2;
    }
  get_api = (GlimsEngineGetAPIFunction) dlsym (library, "glims_engine_get_api");
  api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  if (! api || api->api_version != GLIMS_ENGINE_API_VERSION)
    {
      fprintf (stderr, "FAIL  library does not serve facade version %u\n",
               (unsigned) GLIMS_ENGINE_API_VERSION);
      return 2;
    }

  /* Guard BEFORE dereferencing slot 138: an older 137-slot producer has a
   * smaller struct_size and must refuse cleanly here. sizeof never reads
   * the member, so the guard itself is safe on the old table. */
  slot_end = offsetof (GlimsEngineAPI, resource_create_gradient) +
             sizeof (api->resource_create_gradient);
  if (api->struct_size < slot_end)
    {
      fprintf (stderr,
               "REFUSED: producer struct_size %u predates slot 138 (needs %zu); "
               "no member dereferenced\n", api->struct_size, slot_end);
      return 2;
    }
  create_gradient = api->resource_create_gradient;
  CHECK (create_gradient != NULL, "slot 138 resource_create_gradient present "
         "(api %u, struct_size %u)", api->api_version, api->struct_size);

  {
    int rc = strcmp (argv[3], "create") == 0 ? phase_create () : phase_verify ();

    if (rc != 0)
      failures++;
  }

  dlclose (library);
  printf ("%s: %d failure%s\n", failures ? "FAILED" : "PASSED", failures,
          failures == 1 ? "" : "s");
  return failures ? 1 : 0;
}
