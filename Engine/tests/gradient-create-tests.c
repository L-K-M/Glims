/*
 * gradient-create-tests.c — Core-linked harness for the INTERNAL-ONLY
 * glims_resource_create_gradient (Engine/resource-gradient-create.c; no
 * facade slot). Test-only, linked by scripts/test-gradient-create.py with
 * the selected adapter producer objects plus a fresh resource-gradient-create.o
 * (no dlopen, no libgimp, no adapter relink):
 *   gradient-create-tests WORK_DIR create|verify
 * The driver runs the phases as two separate processes on one WORK_DIR; the
 * engine starts once per process. One outer glims_engine_call() runs the
 * phase; every helper call inside goes through glims_engine_call() again.
 * Verify-phase identity is by NAME via WORK_DIR/gradient-create-handoff.txt.
 * Covered: refusal matrix, valid creates with .25/.5/.75 endpoints, static
 * FIXED stops under a foreign PRIVATE context, native shape (one segment,
 * 0/.5/1, LINEAR/RGB, FIXED/FIXED, sRGB endpoints, RGB_PERCEPTUAL midpoint),
 * preservation of context/clipboard/image/catalog/files, armed staging and
 * final collisions via the reused resource-create-interpose.c shim, and
 * fresh-process native GGR reload (factory scan + file content check).
 */
#include "engine-private.h"

#include <dirent.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <babl/babl.h>
#include <gegl-buffer.h>

#include "core/gimp.h"
#include "core/gimpbuffer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpgradient.h"
#include "core/gimpgradient-load.h"
#include "core/gimpobject.h"

static const GlimsEngineAPI *api;
static int failures;

#define CHECK(cond, ...)                                                  \
  do {                                                                    \
    if (cond) printf ("ok    "); else { printf ("FAIL  "); failures++; }  \
    printf (__VA_ARGS__); printf ("\n"); fflush (stdout);                 \
  } while (0)

/* .25/.5/.75 endpoints: a linear-light misreading of facade sRGB fails
 * loudly. float32 storage + GGR text round-trip justify TOL 1e-5. */
static const GlimsColor LEFT  = { 0.25, 0.5, 0.75, 0.9 };
static const GlimsColor RIGHT = { 0.75, 0.25, 0.5, 0.1 };
#define NAME_A "glims-test-grad-a"
#define NAME_B "glims-test-grad-b"
#define TOL 1e-5

typedef struct
{
  GlimsEngine *engine;
  Gimp *gimp;
  const char *work, *phase;
  char *save_dir;  /* owned: writable gradient folder */
  void (*arm) (const char *, const char *, const char *);
  void (*disarm) (void);
  unsigned (*uuid_replaced) (void), (*mkdir_calls) (void), (*move_calls) (void), (*path_mismatch) (void);
} Probe;

typedef struct
{
  const char *name;
  const GlimsColor *left, *right;
  GlimsResourceID out;
  char *error;
  GlimsStatus status;
} CreateCall;

static GlimsStatus
call_create (GlimsEngine *engine, gpointer data)
{
  CreateCall *c = data;

  c->status = glims_resource_create_gradient (engine, c->name, c->left, c->right,
                                              &c->out, &c->error);
  return c->status;
}

static GlimsStatus
do_create (Probe *p, const char *name, const GlimsColor *left,
           const GlimsColor *right, GlimsResourceID *out, char **err)
{
  CreateCall c = { name, left, right, 0xfeedbeef, NULL, GLIMS_STATUS_FAILED };
  if (err) *err = NULL;
  glims_engine_call (p->engine, call_create, &c);
  if (out) *out = c.out;
  if (err) *err = c.error;
  else free (c.error);
  return c.status;
}

static void
expect_refusal (Probe *p, GlimsStatus want, const char *name, const GlimsColor *l,
                const GlimsColor *r, const char *what)
{
  GlimsResourceID out = 0xdeadbeef;
  char *err = NULL;
  GlimsStatus st = do_create (p, name, l, r, &out, &err);

  CHECK (st == want && out == 0, "%s: want %d out 0 (got %d/%llu)", what, want, st,
         (unsigned long long) out);
  if (st == GLIMS_STATUS_INVALID_ARGUMENT || st == GLIMS_STATUS_FAILED)
    CHECK (err != NULL, "%s: error message set", what);
  free (err);
}

/* ---- snapshots: gradient folder count, catalog count, context, clipboard, image */

static int
dir_count (const char *path)
{
  DIR *d = opendir (path);
  struct dirent *de;
  int n = 0;

  if (! d)
    return errno == ENOENT ? 0 : -1;
  while ((de = readdir (d)))
    {
      char full[1024];
      struct stat st;

      if (de->d_name[0] == '.')
        continue;  /* hidden staging dirs are covered by the sentinels */
      snprintf (full, sizeof full, "%s/%s", path, de->d_name);
      if (stat (full, &st) == 0 && S_ISREG (st.st_mode))
        n++;
    }
  closedir (d);
  return n;
}

static int
cat_count (Probe *p)
{
  int32_t n = 0;

  return api->resources (p->engine, GLIMS_RESOURCE_GRADIENT, NULL, 0, &n) == GLIMS_STATUS_OK
         ? n : -1;
}

typedef struct { double fg[4], bg[4]; } CtxSnap;

static void
ctx_snap (Probe *p, CtxSnap *s)
{
  GimpContext *user = gimp_get_user_context (p->gimp);
  GeglColor *c = gimp_context_get_foreground (user);

  gegl_color_get_rgba_with_space (c, &s->fg[0], &s->fg[1], &s->fg[2], &s->fg[3], NULL);
  c = gimp_context_get_background (user);
  gegl_color_get_rgba_with_space (c, &s->bg[0], &s->bg[1], &s->bg[2], &s->bg[3], NULL);
}

typedef struct { void *obj; unsigned long long hash; } ClipSnap;

static unsigned long long
hash_bytes (const void *data, size_t len)
{
  const unsigned char *b = data;
  unsigned long long h = 1469598103934665603ULL;
  size_t i;

  for (i = 0; i < len; i++)
    h = (h ^ b[i]) * 1099511628211ULL;
  return h;
}

static void
clip_snap (Probe *p, ClipSnap *s)
{
  GimpObject *obj = gimp_get_clipboard_object (p->gimp);

  s->obj = obj;
  s->hash = 0;
  CHECK (obj && GIMP_IS_BUFFER(obj), "the known clipboard buffer still exists");
  if (obj && GIMP_IS_BUFFER (obj))
    {
      GeglBuffer *buf = gimp_buffer_get_buffer (GIMP_BUFFER (obj));
      const GeglRectangle *ext = gegl_buffer_get_extent (buf);
      unsigned char *px = g_malloc ((gsize) ext->width * ext->height * 4);

      gegl_buffer_get (buf, ext, 1.0, babl_format ("R'G'B'A u8"), px, GEGL_AUTO_ROWSTRIDE,
                       GEGL_ABYSS_NONE);
      unsigned char expected[64];
      for (int i=0; i<64; i++) expected[i]=(unsigned char)(i*3+7);
      CHECK (ext->width==4 && ext->height==4 && memcmp(px,expected,sizeof expected)==0,
             "clipboard snapshot reads the exact known fixture pixels");
      s->hash = hash_bytes (px, (gsize) ext->width * ext->height * 4);
      g_free (px);
    }
}

typedef struct { bool dirty; int undo, redo; unsigned long long pix; } ImgSnap;

static int
img_snap (Probe *p, GlimsImageID img, ImgSnap *s)
{
  GlimsImageInfo info;
  GlimsUndoInfo undo;
  unsigned char *px;

  memset (s, 0, sizeof *s);
  if (api->image_info (p->engine, img, &info) != GLIMS_STATUS_OK ||
      api->image_undo_info (p->engine, img, &undo) != GLIMS_STATUS_OK)
    return -1;
  s->dirty = info.dirty;
  s->undo = undo.undo_count;
  s->redo = undo.redo_count;
  px = calloc ((size_t) info.width * info.height, 4);
  if (api->image_render (p->engine, img, 1.0,
                         (GlimsRect) { 0, 0, info.width, info.height },
                         px, (size_t) info.width * 4) != GLIMS_STATUS_OK)
    { free (px); return -1; }
  s->pix = hash_bytes (px, (size_t) info.width * info.height * 4);
  free (px);
  return 0;
}

/* ---- native gradient verification ------------------------------------ */

static void
sample_at (GimpGradient *g, GimpContext *ctx, double pos, double rgba[4])
{
  GeglColor *c = NULL;

  gimp_gradient_get_color_at (g, ctx, NULL, pos, FALSE,
                              GIMP_GRADIENT_BLEND_RGB_PERCEPTUAL, &c);
  gegl_color_get_rgba_with_space (c, &rgba[0], &rgba[1], &rgba[2], &rgba[3], NULL);
  g_object_unref (c);
}

static int
near (const double *a, const GlimsColor *b)
{
  return fabs (a[0] - b->red) < TOL && fabs (a[1] - b->green) < TOL &&
         fabs (a[2] - b->blue) < TOL && fabs (a[3] - b->alpha) < TOL;
}

/* One LINEAR/RGB/FIXED/FIXED segment at 0/.5/1, both sRGB endpoints incl.
 * alpha, independent midpoint. `sample_ctx` is a PRIVATE context with
 * arbitrary FG/BG: FIXED stops must ignore it. */
static void
check_gradient_native (Probe *p, GimpGradient *g, const char *name,
                       GimpContext *sample_ctx, const char *label)
{
  GimpGradientSegment *seg = g ? g->segments : NULL;
  GimpContext *ctx = sample_ctx;
  gboolean owned = FALSE;
  double lv[4], rv[4], s0[4], sm[4], s1[4];

  CHECK (g && GIMP_IS_GRADIENT (g) && strcmp (gimp_object_get_name (GIMP_OBJECT (g)), name) == 0 &&
         ! gimp_data_is_internal (GIMP_DATA (g)), "%s: live non-internal gradient '%s'",
         label, name);
  if (! g)
    return;
  CHECK (seg && ! seg->next && ! seg->prev && seg->left == 0.0 && seg->middle == 0.5 &&
         seg->right == 1.0 && seg->type == GIMP_GRADIENT_SEGMENT_LINEAR &&
         seg->color == GIMP_GRADIENT_SEGMENT_RGB &&
         seg->left_color_type == GIMP_GRADIENT_COLOR_FIXED &&
         seg->right_color_type == GIMP_GRADIENT_COLOR_FIXED,
         "%s: one segment 0/.5/1 LINEAR/RGB FIXED/FIXED", label);
  if (! seg)
    return;
  gegl_color_get_rgba_with_space (seg->left_color, &lv[0], &lv[1], &lv[2], &lv[3], NULL);
  gegl_color_get_rgba_with_space (seg->right_color, &rv[0], &rv[1], &rv[2], &rv[3], NULL);
  CHECK (near (lv, &LEFT) && near (rv, &RIGHT),
         "%s: endpoints sRGB+alpha L %.4f %.4f %.4f %.4f R %.4f %.4f %.4f %.4f",
         label, lv[0], lv[1], lv[2], lv[3], rv[0], rv[1], rv[2], rv[3]);
  if (! ctx)
    {
      ctx = gimp_context_new (p->gimp, "glims gradient probe", NULL);
      owned = TRUE;
    }
  sample_at (g, ctx, 0.0, s0);
  sample_at (g, ctx, 0.5, sm);
  sample_at (g, ctx, 1.0, s1);
  if (owned)
    g_object_unref (ctx);
  CHECK (fabs (s0[0] - LEFT.red) < TOL && fabs (s0[3] - LEFT.alpha) < TOL &&
         fabs (s1[0] - RIGHT.red) < TOL && fabs (s1[3] - RIGHT.alpha) < TOL &&
         fabs (sm[0] - (LEFT.red + RIGHT.red) / 2) < TOL &&
         fabs (sm[1] - (LEFT.green + RIGHT.green) / 2) < TOL &&
         fabs (sm[2] - (LEFT.blue + RIGHT.blue) / 2) < TOL &&
         fabs (sm[3] - (LEFT.alpha + RIGHT.alpha) / 2) < TOL,
         "%s: RGB_PERCEPTUAL endpoint + midpoint samples match (alpha independent)", label);
}

/* ---- phase create ------------------------------------------------------ */

static void
phase_create (Probe *p)
{
  static const char *const bad_names[] = { "", "\xC3\x28", "a\tb", " x", "x " };
  static const char *const bad_what[] = { "empty", "bad UTF-8", "Cc control", "leading space",
                                          "trailing space" };
  int dir0, dir1, cat0, cat1, i;
  CtxSnap ctx0, ctx1;
  ClipSnap clip0, clip1;
  ImgSnap img0, img1;
  GlimsImageID img = 0;
  GlimsItemID layer = 0;
  GlimsResourceID id = 0, idb = 0;
  GlimsLayerInfo lrow;
  int32_t ln = 0;
  GlimsColor fill = { 0.1, 0.2, 0.3, 1.0 };
  char *err = NULL;
  char path[1024];
  FILE *f;

  /* Fixture: one open image (cleared once), a known clipboard buffer. */
  CHECK (api->image_new (p->engine, 16, 12, &img, &err) == GLIMS_STATUS_OK && img != 0,
         "fixture image created");
  CHECK (api->image_layers (p->engine, img, &lrow, 1, &ln) == GLIMS_STATUS_OK && ln == 1,
         "fixture layer listed");
  layer = lrow.id;
  CHECK (api->image_clear (p->engine, img, &fill, &err) == GLIMS_STATUS_OK,
         "fixture image cleared");
  {
    GeglBuffer *gb = gegl_buffer_new (GEGL_RECTANGLE (0, 0, 4, 4), babl_format ("R'G'B'A u8"));
    unsigned char px[64];
    GimpBuffer *cb;

    for (i = 0; i < 64; i++)
      px[i] = (unsigned char) (i * 3 + 7);
    gegl_buffer_set (gb, GEGL_RECTANGLE (0, 0, 4, 4), 0, babl_format ("R'G'B'A u8"),
                     px, GEGL_AUTO_ROWSTRIDE);
    cb = gimp_buffer_new (gb, "glims clipboard fixture", 0, 0, TRUE);
    g_object_unref (gb);
    gimp_set_clipboard_buffer (p->gimp, cb);
    g_object_unref (cb);
  }

  /* BUSY probes first; the legitimate probe-stroke undo is isolated from
   * the preservation baseline taken after it. */
  {
    GlimsBrushSettings brush;
    GlimsStrokePoint first = { 2, 2, 1, 0, 0, 0 };
    GlimsStrokeID stroke = 0;
    GlimsFilterID filter = 0;

    memset (&brush, 0, sizeof brush);
    brush.struct_size = sizeof brush;
    brush.size = 9.0; brush.opacity = 1.0;
    brush.tool = GLIMS_PAINT_PAINTBRUSH;
    brush.hardness = brush.rate = brush.flow = brush.exposure = -1.0;
    CHECK (api->stroke_begin (p->engine, img, layer, &brush, &first, &stroke, &err) ==
           GLIMS_STATUS_OK && stroke != 0, "probe stroke begun for BUSY");
    expect_refusal (p, GLIMS_STATUS_BUSY, "glims-busy-stroke", &LEFT, &RIGHT,
                    "create during an open stroke is BUSY");
    CHECK (api->stroke_end (p->engine, stroke) == GLIMS_STATUS_OK, "probe stroke ended");
    CHECK (api->image_undo (p->engine, img) == GLIMS_STATUS_OK, "probe stroke undone");
    CHECK (api->filter_begin (p->engine, img, layer, "gegl:gaussian-blur", &filter, &err) ==
           GLIMS_STATUS_OK && filter != 0, "probe filter begun for BUSY");
    expect_refusal (p, GLIMS_STATUS_BUSY, "glims-busy-filter", &LEFT, &RIGHT,
                    "create during an open filter is BUSY");
    CHECK (api->filter_abort (p->engine, filter) == GLIMS_STATUS_OK, "probe filter aborted");
  }

  /* Preservation baseline AFTER the probe-stroke undo. */
  dir0 = dir_count (p->save_dir);
  cat0 = cat_count (p);
  ctx_snap (p, &ctx0);
  clip_snap (p, &clip0);
  CHECK (img_snap (p, img, &img0) == 0, "image baseline snapshotted");

  /* Refusal battery: names. */
  expect_refusal (p, GLIMS_STATUS_INVALID_ARGUMENT, NULL, &LEFT, &RIGHT, "NULL name");
  for (i = 0; i < 5; i++)
    expect_refusal (p, GLIMS_STATUS_INVALID_ARGUMENT, bad_names[i], &LEFT, &RIGHT, bad_what[i]);
  {
    char longname[257];

    memset (longname, 'a', 256);
    longname[256] = '\0';
    expect_refusal (p, GLIMS_STATUS_INVALID_ARGUMENT, longname, &LEFT, &RIGHT, "256-byte name");
  }
  /* Refusal battery: endpoints and outputs. */
  expect_refusal (p, GLIMS_STATUS_INVALID_ARGUMENT, "glims-null-left", NULL, &RIGHT, "NULL left");
  expect_refusal (p, GLIMS_STATUS_INVALID_ARGUMENT, "glims-null-right", &LEFT, NULL, "NULL right");
  {
    static const struct { int ch; double v; const char *what; } badc[] = {
      { 0, NAN, "NaN" }, { 3, INFINITY, "Inf" }, { 1, -0.1, "negative" }, { 2, 1.1, ">1" }
    };
    GlimsColor bad;

    for (i = 0; i < 4; i++)
      {
        bad = (i < 2) ? LEFT : RIGHT;
        (&bad.red)[badc[i].ch] = badc[i].v;
        expect_refusal (p, GLIMS_STATUS_INVALID_ARGUMENT, "glims-badc", &bad, &RIGHT, badc[i].what);
      }
    {
      /* NULL engine/out cannot go through glims_engine_call (NULL engine is
       * NOT_RUNNING at dispatch), so the helper's own admission is called
       * directly for those two cases. */
      GlimsResourceID out = 0;
      char *e2 = NULL;
      GlimsStatus st;

      st = glims_resource_create_gradient (NULL, "glims-null-engine", &LEFT, &RIGHT, &out, &e2);
      CHECK (st == GLIMS_STATUS_INVALID_ARGUMENT && out == 0, "NULL engine INVALID_ARGUMENT, out 0");
      free (e2);
      st = glims_resource_create_gradient (p->engine, "glims-null-out", &LEFT, &RIGHT, NULL, &e2);
      CHECK (st == GLIMS_STATUS_INVALID_ARGUMENT && e2 != NULL, "NULL out INVALID_ARGUMENT");
      free (e2);
    }
  }

  /* Valid create: nontrivial endpoints, real native shape. */
  CHECK (do_create (p, NAME_A, &LEFT, &RIGHT, &id, &err) == GLIMS_STATUS_OK && id > 0,
         "valid create OK, id %llu%s%s", (unsigned long long) id, err ? ": " : "", err ? err : "");
  free (err); err = NULL;
  {
    GimpGradient *g = NULL;

    CHECK (glims_lookup_gradient (p->engine, id, &g) == GLIMS_STATUS_OK && g, "created id resolves");
    check_gradient_native (p, g, NAME_A, NULL, "created gradient");
  }
  expect_refusal (p, GLIMS_STATUS_FAILED, NAME_A, &LEFT, &RIGHT, "duplicate label FAILED");

  /* Static under a different PRIVATE context's FG/BG (user context never
   * touched; the FIXED stops must ignore the sampling context). */
  {
    GimpContext *other = gimp_context_new (p->gimp, "glims other context", NULL);
    GeglColor *c = gegl_color_new (NULL);
    GimpGradient *g = NULL;

    gegl_color_set_rgba_with_space (c, 0.9, 0.1, 0.4, 1.0, NULL);
    gimp_context_set_foreground (other, c);
    gegl_color_set_rgba_with_space (c, 0.2, 0.8, 0.6, 1.0, NULL);
    gimp_context_set_background (other, c);
    g_object_unref (c);
    CHECK (do_create (p, NAME_B, &LEFT, &RIGHT, &idb, &err) == GLIMS_STATUS_OK && idb > 0,
           "second create, id %llu", (unsigned long long) idb);
    free (err); err = NULL;
    CHECK (glims_lookup_gradient (p->engine, idb, &g) == GLIMS_STATUS_OK && g,
           "second gradient resolves");
    check_gradient_native (p, g, NAME_B, other, "sampled under foreign FG/BG");
    g_object_unref (other);
  }

  /* Armed fault collisions via the reused interpose shim (optional). Each
   * arm wraps exactly ONE resource call, after startup. */
  if (p->arm && p->disarm && p->uuid_replaced && p->mkdir_calls && p->move_calls && p->path_mismatch)
    {
      const char *uuid1 = "11111111-2222-3333-4444-555555555555";
      const char *uuid2 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
      char sentinel_dir[1200], sentinel_file[1200], staging2[1200];

      snprintf (sentinel_dir, sizeof sentinel_dir, "%s/.glims-stage-%s", p->save_dir, uuid1);
      snprintf (sentinel_file, sizeof sentinel_file, "%s/%s.ggr", p->save_dir, uuid2);
      snprintf (staging2, sizeof staging2, "%s/.glims-stage-%s", p->save_dir, uuid2);
      mkdir (sentinel_dir, 0755);
      f = fopen (sentinel_file, "wb");
      if (f) { fputs ("SENTINEL", f); fclose (f); }
      p->arm (uuid1, p->save_dir, ".ggr");
      expect_refusal (p, GLIMS_STATUS_FAILED, "glims-fault-stage", &LEFT, &RIGHT,
                      "staging-dir collision FAILED");
      CHECK (p->uuid_replaced() > 0 && p->mkdir_calls() > 0 && p->move_calls() == 0
             && p->path_mismatch() == 0, "stage-collision hooks ran on the expected paths");
      p->disarm ();
      CHECK (access (sentinel_dir, F_OK) == 0, "sentinel staging dir survives");
      p->arm (uuid2, p->save_dir, ".ggr");
      expect_refusal (p, GLIMS_STATUS_FAILED, "glims-fault-final", &LEFT, &RIGHT,
                      "final-file collision FAILED");
      CHECK (p->uuid_replaced() > 0 && p->mkdir_calls() > 0 && p->move_calls() > 0
             && p->path_mismatch() == 0, "final-collision move hook ran on the expected paths");
      p->disarm ();
      f = fopen (sentinel_file, "rb");
      char sentinel_bytes[16] = {0};
      size_t sentinel_length = f ? fread(sentinel_bytes,1,sizeof sentinel_bytes,f) : 0;
      CHECK (sentinel_length == 8 && memcmp(sentinel_bytes,"SENTINEL",8)==0, "sentinel final file survives intact");
      if (f) fclose (f);
      CHECK (access (staging2, F_OK) != 0, "owned staging cleaned, no leftovers");
      rmdir (sentinel_dir);
      unlink (sentinel_file);
    }
  else
    CHECK (false, "the required interpose fault shim exports are present");

  /* The battery preserved everything except the two intended creates. */
  dir1 = dir_count (p->save_dir);
  cat1 = cat_count (p);
  ctx_snap (p, &ctx1);
  clip_snap (p, &clip1);
  CHECK (img_snap (p, img, &img1) == 0 && img1.dirty == img0.dirty &&
         img1.undo == img0.undo && img1.redo == img0.redo && img1.pix == img0.pix,
         "image pixels/undo/dirty unchanged");
  CHECK (memcmp (&ctx0, &ctx1, sizeof ctx0) == 0, "user context FG/BG unchanged");
  CHECK (clip0.obj == clip1.obj && clip0.hash == clip1.hash, "clipboard object/content unchanged");
  CHECK (cat1 == cat0 + 2, "catalog grew by exactly 2 (%d -> %d)", cat0, cat1);
  CHECK (dir1 == dir0 + 2, "gradient folder grew by exactly 2 files (%d -> %d)", dir0, dir1);
  /* Persist the actual native identity triplets, never session handles or
   * a fabricated NULL file collection. */
  {
    GKeyFile *handoff = g_key_file_new ();
    const GlimsResourceID ids[2] = {id, idb};
    const char *groups[2] = {"first", "second"};
    for (int i=0; i<2; i++) {
      char *name=NULL, *collection=NULL, *identity_error=NULL;
      bool internal=true;
      GlimsResourceID roundtrip=0;
      GlimsStatus result=api->resource_identifiers(p->engine,ids[i],&name,&collection,&internal,&identity_error);
      CHECK(result==GLIMS_STATUS_OK && name && collection && !internal, "saved gradient has a full file identity");
      if (result==GLIMS_STATUS_OK && name && collection) {
        CHECK(api->resource_resolve(p->engine,GLIMS_RESOURCE_GRADIENT,name,collection,internal,&roundtrip,NULL)==GLIMS_STATUS_OK
              && roundtrip==ids[i], "exact identity roundtrip before restart");
        g_key_file_set_string(handoff,groups[i],"name",name);
        g_key_file_set_string(handoff,groups[i],"collection",collection);
        g_key_file_set_boolean(handoff,groups[i],"internal",internal);
      }
      free(name); free(collection); free(identity_error);
    }
    snprintf(path,sizeof path,"%s/gradient-create-handoff.ini",p->work);
    char *serialized=g_key_file_to_data(handoff,NULL,NULL);
    CHECK(serialized && g_file_set_contents(path,serialized,-1,NULL), "full identity handoff written");
    g_free(serialized); g_key_file_unref(handoff);
  }
  CHECK (api->image_close (p->engine, img) == GLIMS_STATUS_OK, "fixture image closed");
}

/* ---- phase verify (fresh engine process) ------------------------------- */

static void
phase_verify (Probe *p)
{
  char path[1024];
  int checked = 0;
  GKeyFile *handoff = g_key_file_new ();
  const char *groups[2] = {"first", "second"};
  snprintf(path,sizeof path,"%s/gradient-create-handoff.ini",p->work);
  gboolean loaded=g_key_file_load_from_file(handoff,path,G_KEY_FILE_NONE,NULL);
  CHECK(loaded,"verify reads the complete identity handoff");
  if (!loaded) { g_key_file_unref(handoff); return; }
  for (int entry=0; entry<2; entry++)
    {
      gchar *line=g_key_file_get_string(handoff,groups[entry],"name",NULL);
      gchar *collection=g_key_file_get_string(handoff,groups[entry],"collection",NULL);
      gboolean stored_internal=g_key_file_get_boolean(handoff,groups[entry],"internal",NULL);
      CHECK(line && collection,"handoff contains both identity strings");
      if (!line || !collection) { g_free(line); g_free(collection); continue; }
      GlimsResourceID id = 0;
      char *name = NULL, *coll = NULL, *err = NULL;
      bool internal = true;
      GimpGradient *g = NULL;
      char want[300];
      DIR *d;
      struct dirent *de;
      int file_ok = 0;

      /* Fresh process: resolve the exact persisted name/collection/internal. */
      CHECK (api->resource_resolve (p->engine, GLIMS_RESOURCE_GRADIENT, line, collection, stored_internal,
                                    &id, &err) == GLIMS_STATUS_OK && id > 0,
             "fresh process resolves '%s', id %llu", line, (unsigned long long) id);
      free (err); err = NULL;
      CHECK (api->resource_identifiers (p->engine, id, &name, &coll, &internal, &err) ==
             GLIMS_STATUS_OK && name && strcmp (name, line) == 0 && ! internal,
             "identity roundtrip '%s', non-internal", line);
      free (name); free (coll); free (err);
      CHECK (glims_lookup_gradient (p->engine, id, &g) == GLIMS_STATUS_OK && g,
             "native gradient resolves");
      check_gradient_native (p, g, line, NULL, "reloaded gradient");
      /* The saved .ggr file itself carries the exact name line. */
      snprintf (want, sizeof want, "Name: %s\n", line);
      d = opendir (p->save_dir);
      while (d && (de = readdir (d)) && ! file_ok)
        {
          if (strncmp (de->d_name, ".glims-stage", 12) == 0 || ! strstr (de->d_name, ".ggr"))
            continue;
          {
            char full[1200];
            FILE *gf;

            snprintf (full, sizeof full, "%s/%s", p->save_dir, de->d_name);
            gf = fopen (full, "rb");
            if (gf)
              {
                char buf[4096];
                size_t r = fread (buf, 1, sizeof buf - 1, gf);

                buf[r] = '\0';
                file_ok = strstr (buf, want) != NULL;
                fclose (gf);
              }
          }
        }
      if (d)
        closedir (d);
      CHECK (file_ok, "saved GGR file carries 'Name: %s'", line);
      g_free(line); g_free(collection);
      checked++;
    }
  g_key_file_unref(handoff);
  CHECK (checked == 2, "verify checked both handoff gradients (%d)", checked);
}

static GlimsStatus
run_phase (GlimsEngine *engine, gpointer data)
{
  Probe *p = data;
  GList *wl = gimp_data_factory_get_data_path_writable (engine->gimp->gradient_factory);

  p->engine = engine;
  p->gimp   = engine->gimp;
  if (! wl)
    return GLIMS_STATUS_FAILED;
  p->save_dir = g_file_get_path (wl->data);
  g_list_free_full (wl, (GDestroyNotify) g_object_unref);
  p->arm    = (void (*)(const char *, const char *, const char *))
              dlsym (RTLD_DEFAULT, "glims_test_arm");
  p->disarm = (void (*)(void)) dlsym (RTLD_DEFAULT, "glims_test_disarm");
  p->uuid_replaced = (unsigned (*)(void)) dlsym(RTLD_DEFAULT,"glims_test_uuid_replaced");
  p->mkdir_calls = (unsigned (*)(void)) dlsym(RTLD_DEFAULT,"glims_test_mkdir_calls");
  p->move_calls = (unsigned (*)(void)) dlsym(RTLD_DEFAULT,"glims_test_move_calls");
  p->path_mismatch = (unsigned (*)(void)) dlsym(RTLD_DEFAULT,"glims_test_path_mismatch");
  if (strcmp (p->phase, "create") == 0)
    phase_create (p);
  else
    phase_verify (p);
  g_free(p->save_dir); p->save_dir=NULL;
  return failures > 0 ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config;
  GlimsEngine *engine = NULL;
  Probe probe;
  char *error = NULL;
  char work[1024], user_dir[1024], cache_dir[1024];
  GlimsStatus status;

  if (argc != 3 || (strcmp (argv[2], "create") != 0 && strcmp (argv[2], "verify") != 0))
    {
      fprintf (stderr, "usage: %s WORK_DIR create|verify\n", argv[0]);
      return 2;
    }
  snprintf (work, sizeof work, "%s", argv[1]);
  snprintf (user_dir, sizeof user_dir, "%s/user", work);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", work);
  mkdir (work, 0755);
  mkdir (user_dir, 0755);
  mkdir (cache_dir, 0755);
  memset (&probe, 0, sizeof probe);
  probe.work = work;
  probe.phase = argv[2];
  memset (&config, 0, sizeof config);
  config.struct_size = sizeof config;
  config.user_directory = user_dir;
  config.cache_directory = cache_dir;
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (! api || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    {
      fprintf (stderr, "glims_engine_get_api(%u) did not serve the facade\n",
               (unsigned) GLIMS_ENGINE_API_VERSION);
      return 1;
    }
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start failed: %s\n", error ? error : "unknown");
      return 1;
    }
  printf ("gradient-create-tests: phase %s, engine %s, work %s\n",
          argv[2], api->engine_version (engine), work);
  status = glims_engine_call (engine, run_phase, &probe);
  api->stop (engine);
  printf ("%s: %d failure%s\n", failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          failures, failures == 1 ? "" : "s");
  return status == GLIMS_STATUS_OK && failures == 0 ? 0 : 1;
}
