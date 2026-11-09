/*
 * Standalone facade-only tests for resource_create_pixels (facade slot
 * 129), in the style of Engine/tests/engine-tests.c and
 * Engine/tests/metadata-error-tests.c: the adapter is loaded with
 * dlopen() exactly as the app does, and only the public facade in
 * glims_engine.h is used — no GIMP/GLib types, no private struct
 * layouts, no engine object files.
 *
 *   resource-create-tests LIBRARY WORK_DIR PHASE
 *
 * PHASE is "create" or "verify". The engine can only be started once per
 * process, so scripts/test-resource-create.py runs this binary twice on
 * the same isolated WORK_DIR: "create" exercises everything and records
 * the persistent identities in WORK_DIR/restart.txt; "verify" starts a
 * fresh engine on the same directories and checks that the saved
 * resources load back and resolve (true restart persistence).
 *
 * Everything the test touches lives under WORK_DIR: the engine's user
 * and cache directories, the sentinel files and the restart handoff.
 * The writable resource folders are the engine's defaults for a fresh
 * GIMP3_DIRECTORY, <user>/brushes and <user>/patterns (source-confirmed:
 * gimp_config_build_writable_path() + engine.c setting GIMP3_DIRECTORY
 * to the configured user directory); the interposer shim additionally
 * fails closed unless every armed native path is exactly under the
 * harness-supplied folder inside WORK_DIR.
 *
 * Prints one line per check and exits non-zero if any check fails.
 */
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
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

/* ---- Test-control API of the interposer shim (DYLD_INSERT_LIBRARIES) -- */

typedef void        (*ArmFn) (const char *, const char *, const char *);
typedef void        (*VoidFn) (void);
typedef unsigned    (*CountFn) (void);
typedef int         (*IntFn) (void);
typedef const char *(*StrFn) (void);

static ArmFn   t_arm;
static VoidFn  t_disarm, t_reset;
static CountFn t_uuid_calls, t_uuid_replaced, t_mkdir_calls, t_move_calls, t_path_mismatch;
static IntFn   t_last_move_ok, t_armed;
static StrFn   t_last_uuid, t_last_mkdir_path, t_last_move_src, t_last_move_dst;

/* Resolving the controls is not arming: the harness only ever calls
 * t_arm after the engine has started, immediately around ONE resource
 * call. A missing export fails closed. */
static int
resolve_controls (void)
{
  t_arm            = (ArmFn) dlsym (RTLD_DEFAULT, "glims_test_arm");
  t_disarm         = (VoidFn) dlsym (RTLD_DEFAULT, "glims_test_disarm");
  t_reset          = (VoidFn) dlsym (RTLD_DEFAULT, "glims_test_reset");
  t_uuid_calls     = (CountFn) dlsym (RTLD_DEFAULT, "glims_test_uuid_calls");
  t_uuid_replaced  = (CountFn) dlsym (RTLD_DEFAULT, "glims_test_uuid_replaced");
  t_mkdir_calls    = (CountFn) dlsym (RTLD_DEFAULT, "glims_test_mkdir_calls");
  t_move_calls     = (CountFn) dlsym (RTLD_DEFAULT, "glims_test_move_calls");
  t_path_mismatch  = (CountFn) dlsym (RTLD_DEFAULT, "glims_test_path_mismatch");
  t_last_move_ok   = (IntFn) dlsym (RTLD_DEFAULT, "glims_test_last_move_succeeded");
  t_armed          = (IntFn) dlsym (RTLD_DEFAULT, "glims_test_armed");
  t_last_uuid      = (StrFn) dlsym (RTLD_DEFAULT, "glims_test_last_uuid");
  t_last_mkdir_path = (StrFn) dlsym (RTLD_DEFAULT, "glims_test_last_mkdir_path");
  t_last_move_src  = (StrFn) dlsym (RTLD_DEFAULT, "glims_test_last_move_src");
  t_last_move_dst  = (StrFn) dlsym (RTLD_DEFAULT, "glims_test_last_move_dst");

  if (! t_arm || ! t_disarm || ! t_reset || ! t_uuid_calls || ! t_uuid_replaced ||
      ! t_mkdir_calls || ! t_move_calls || ! t_path_mismatch || ! t_last_move_ok ||
      ! t_armed || ! t_last_uuid || ! t_last_mkdir_path || ! t_last_move_src ||
      ! t_last_move_dst)
    {
      fprintf (stderr, "FAIL  interposer test-control exports are missing; "
               "the shim was not inserted or is stale\n");
      return 0;
    }
  return 1;
}

/* ---- Small filesystem helpers, all confined to WORK_DIR --------------- */

static char work[4096];
static char user_dir[4096], cache_dir[4096];
static char brush_dir[4096], pattern_dir[4096];

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
write_all (const char *path, const uint8_t *data, size_t len)
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

static uint32_t
be32 (const uint8_t *p)
{
  return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16) |
         ((uint32_t) p[2] << 8)  |  (uint32_t) p[3];
}

/* Kept small enough that several snapshots stay well inside the default
 * thread stack (2048 * 256 B = 512 KiB each); far above the stock
 * catalog sizes plus the handful of files this test creates. */
#define MAX_DIR_ENTRIES 2048

typedef struct
{
  char names[MAX_DIR_ENTRIES][256];
  int  count;
} DirSnap;

/* A missing directory is an empty snapshot. */
static void
dir_snapshot (const char *dir, DirSnap *snap)
{
  DIR           *d = opendir (dir);
  struct dirent *e;

  snap->count = 0;
  if (! d)
    return;
  while ((e = readdir (d)) && snap->count < MAX_DIR_ENTRIES)
    {
      if (strcmp (e->d_name, ".") == 0 || strcmp (e->d_name, "..") == 0)
        continue;
      snprintf (snap->names[snap->count], sizeof snap->names[0], "%s", e->d_name);
      snap->count++;
    }
  closedir (d);
}

static int
snap_contains (const DirSnap *s, const char *name)
{
  int i;

  for (i = 0; i < s->count; i++)
    if (strcmp (s->names[i], name) == 0)
      return 1;
  return 0;
}

static int
snap_equal (const DirSnap *a, const DirSnap *b)
{
  int i;

  if (a->count != b->count)
    return 0;
  for (i = 0; i < a->count; i++)
    if (! snap_contains (b, a->names[i]))
      return 0;
  return 1;
}

/* Names present in `after` but not in `before`; returns how many. */
static int
snap_new_entries (const DirSnap *before, const DirSnap *after,
                  char out[][256], int max)
{
  int i, n = 0;

  for (i = 0; i < after->count && n < max; i++)
    if (! snap_contains (before, after->names[i]))
      {
        snprintf (out[n], 256, "%s", after->names[i]);
        n++;
      }
  return n;
}

static int
snap_count_prefix (const DirSnap *s, const char *prefix)
{
  int i, n = 0;
  size_t len = strlen (prefix);

  for (i = 0; i < s->count; i++)
    if (strncmp (s->names[i], prefix, len) == 0)
      n++;
  return n;
}

static int
path_is_dir (const char *path)
{
  struct stat st;

  return stat (path, &st) == 0 && S_ISDIR (st.st_mode);
}

static int
path_is_file (const char *path)
{
  struct stat st;

  return stat (path, &st) == 0 && S_ISREG (st.st_mode);
}

/* ---- Facade helpers ---------------------------------------------------- */

static GlimsStatus
get_resources (uint32_t kind, GlimsResourceInfo **rows_out, int32_t *count_out)
{
  GlimsResourceInfo *rows;
  int32_t            n = 0, capacity;
  GlimsStatus        st;

  *rows_out = NULL;
  *count_out = 0;
  st = api->resources (engine, kind, NULL, 0, &n);
  if (st != GLIMS_STATUS_OK || n < 0)
    return st == GLIMS_STATUS_OK ? GLIMS_STATUS_FAILED : st;
  capacity = n;
  rows = calloc (n > 0 ? (size_t) n : 1, sizeof *rows);
  if (! rows)
    return GLIMS_STATUS_FAILED;
  st = api->resources (engine, kind, rows, capacity, &n);
  if (st != GLIMS_STATUS_OK || n < 0 || n > capacity)
    {
      free (rows);
      return st == GLIMS_STATUS_OK ? GLIMS_STATUS_FAILED : st;
    }
  *rows_out  = rows;
  *count_out = n;
  return GLIMS_STATUS_OK;
}

static int
rows_have (const GlimsResourceInfo *rows, int32_t n, GlimsResourceID id, const char *name)
{
  int32_t i;

  for (i = 0; i < n; i++)
    if (rows[i].id == id && strcmp (rows[i].name, name) == 0)
      return 1;
  return 0;
}

/* Same set of (id, name) pairs, order-free. */
static int
rows_equal (const GlimsResourceInfo *a, int32_t na, const GlimsResourceInfo *b, int32_t nb)
{
  int32_t i;

  if (na != nb)
    return 0;
  for (i = 0; i < na; i++)
    if (! rows_have (b, nb, a[i].id, a[i].name))
      return 0;
  return 1;
}

#define OUT_PREFILL ((GlimsResourceID) 0xDEADBEEFDEADBEEFULL)

static GlimsStatus
create_pixels (uint32_t kind, const char *name, int32_t w, int32_t h,
               const uint8_t *pixels, size_t bytes, uint32_t spacing,
               GlimsResourceID *out, char **err)
{
  *out = OUT_PREFILL;
  return api->resource_create_pixels (engine, kind, name, w, h, pixels, bytes,
                                      spacing, out, err);
}

/* Every refusal must leave outID at exactly 0, whatever was prefilled. */
static void
expect_refusal (GlimsStatus want, uint32_t kind, const char *name, int32_t w, int32_t h,
                const uint8_t *pixels, size_t bytes, uint32_t spacing, const char *label)
{
  GlimsResourceID out;
  char           *err = NULL;
  GlimsStatus     st  = create_pixels (kind, name, w, h, pixels, bytes, spacing, &out, &err);

  CHECK (st == want && out == 0,
         "%s: status %d outID %llu (want %d, 0)%s%s",
         label, (int) st, (unsigned long long) out, (int) want,
         err ? ", message: " : "", err ? err : "");
  if (err)
    api->free_string (err);
}

static void
check_identifiers_resolve (uint32_t kind, GlimsResourceID id, const char *name,
                           const char *label)
{
  char            *nm = NULL, *coll = NULL, *err = NULL;
  bool             internal = false;
  GlimsResourceID  rid = 0;
  GlimsStatus      st;

  st = api->resource_identifiers (engine, id, &nm, &coll, &internal, &err);
  CHECK (st == GLIMS_STATUS_OK && nm && strcmp (nm, name) == 0 && internal == false,
         "%s: identifiers name \"%s\" internal %d (want \"%s\", false)",
         label, nm ? nm : "(null)", (int) internal, name);

  st = api->resource_resolve (engine, kind, nm, coll, internal, &rid, &err);
  CHECK (st == GLIMS_STATUS_OK && rid == id,
         "%s: resolve roundtrip id %llu (want %llu)",
         label, (unsigned long long) rid, (unsigned long long) id);

  if (nm)   api->free_string (nm);
  if (coll) api->free_string (coll);
  if (err)  api->free_string (err);
}

static void
check_thumbnail (GlimsResourceID id, int32_t w, int32_t h, const uint8_t *pixels,
                 const char *label)
{
  GlimsPixelBuffer out = { 0 };
  char            *err = NULL;
  GlimsStatus      st  = api->resource_thumbnail (engine, id, 64, NULL, NULL, &out, &err);
  int              ok;

  ok = st == GLIMS_STATUS_OK &&
       out.bounds.x == 0 && out.bounds.y == 0 &&
       out.bounds.width == w && out.bounds.height == h &&
       out.byte_count == (size_t) w * (size_t) h * 4 &&
       out.pixels != NULL &&
       memcmp (out.pixels, pixels, out.byte_count) == 0;
  CHECK (ok, "%s: thumbnail %dx%d, %zu bytes, exact source pixels (want %dx%d, %zu)",
         label, out.bounds.width, out.bounds.height, out.byte_count,
         w, h, (size_t) w * (size_t) h * 4);

  if (out.pixels)
    api->free_pixels (out.pixels);
  if (err)
    api->free_string (err);
}

/* Observe the native clipboard through its built-in pattern resource.
 * image_copy_pixels alone only observes image pixels, not this global.
 * The pinned factory uses this stable internal collection identifier
 * (app/core/gimp-data-factories.c:251-254). */
static int
clipboard_snapshot (GlimsPixelBuffer *out)
{
  GlimsResourceID id = 0;
  char *error = NULL;
  GlimsStatus status;

  memset (out, 0, sizeof *out);
  status = api->resource_resolve (engine, GLIMS_RESOURCE_PATTERN, "Clipboard",
                                  "gimp-pattern-clipboard-image", true, &id, &error);
  if (status == GLIMS_STATUS_OK)
    status = api->resource_thumbnail (engine, id, 32, NULL, NULL, out, &error);
  if (error) api->free_string (error);
  return status == GLIMS_STATUS_OK && out->pixels && out->byte_count > 0;
}

static int
clipboard_equal (const GlimsPixelBuffer *a, const GlimsPixelBuffer *b)
{
  return a->bounds.x == b->bounds.x && a->bounds.y == b->bounds.y &&
         a->bounds.width == b->bounds.width && a->bounds.height == b->bounds.height &&
         a->byte_count == b->byte_count && a->pixels && b->pixels &&
         memcmp (a->pixels, b->pixels, a->byte_count) == 0;
}

/* Native GBR v2 on-disk checks: 7 big-endian uint32 fields, NUL-terminated
 * name, then the tightly packed straight RGBA payload. */
static void
check_gbr_file (const char *path, const char *name, int32_t w, int32_t h,
                uint32_t spacing, const uint8_t *pixels, size_t bytes, const char *label)
{
  uint8_t *f = NULL;
  size_t   len = 0, name_len = strlen (name), payload_off = 28 + name_len + 1;
  int      ok;

  ok = read_all (path, &f, &len) == 0 &&
       len == 28 + name_len + 1 + bytes &&
       be32 (f + 0)  == 28 + name_len + 1 &&   /* header_size */
       be32 (f + 4)  == 2 &&                    /* version */
       be32 (f + 8)  == (uint32_t) w &&
       be32 (f + 12) == (uint32_t) h &&
       be32 (f + 16) == 4 &&                    /* bytes per pixel */
       be32 (f + 20) == 0x47494D50u &&          /* 'GIMP' magic */
       be32 (f + 24) == spacing &&
       memcmp (f + 28, name, name_len + 1) == 0 &&
       memcmp (f + payload_off, pixels, bytes) == 0;
  CHECK (ok, "%s: %s is a native GBR v2 header+name+exact pixels (%zu bytes)",
         label, path, len);
  free (f);
}

/* Native PAT on-disk checks: 6 big-endian uint32 fields, NUL-terminated
 * name, then the RGBA payload. */
static void
check_pat_file (const char *path, const char *name, int32_t w, int32_t h,
                const uint8_t *pixels, size_t bytes, const char *label)
{
  uint8_t *f = NULL;
  size_t   len = 0, name_len = strlen (name), payload_off = 24 + name_len + 1;
  int      ok;

  ok = read_all (path, &f, &len) == 0 &&
       len == 24 + name_len + 1 + bytes &&
       be32 (f + 0)  == 24 + name_len + 1 &&   /* header_size */
       be32 (f + 4)  == 1 &&                    /* version */
       be32 (f + 8)  == (uint32_t) w &&
       be32 (f + 12) == (uint32_t) h &&
       be32 (f + 16) == 4 &&                    /* bytes per pixel */
       be32 (f + 20) == 0x47504154u &&          /* 'GPAT' magic */
       memcmp (f + 24, name, name_len + 1) == 0 &&
       memcmp (f + payload_off, pixels, bytes) == 0;
  CHECK (ok, "%s: %s is a native PAT v1 header+name+exact pixels (%zu bytes)",
         label, path, len);
  free (f);
}

/* ---- Image-side snapshots: creation must not disturb them -------------- */

typedef struct
{
  int32_t           w, h;
  uint8_t          *render;
  GlimsUndoInfo     undo;
  bool              sel_empty;
  GlimsRect         sel;
  GlimsPixelBuffer  clip;
} ImageSnap;

static int
image_snapshot (GlimsImageID image, int32_t w, int32_t h, ImageSnap *s)
{
  char *err = NULL;

  memset (s, 0, sizeof *s);
  s->w = w;
  s->h = h;
  s->render = malloc ((size_t) w * (size_t) h * 4);
  if (! s->render)
    return -1;
  if (api->image_render (engine, image, 1.0, (GlimsRect) { 0, 0, w, h },
                         s->render, (size_t) w * 4) != GLIMS_STATUS_OK)
    return -1;
  if (api->image_undo_info (engine, image, &s->undo) != GLIMS_STATUS_OK)
    return -1;
  if (api->selection_bounds (engine, image, &s->sel_empty, &s->sel) != GLIMS_STATUS_OK)
    return -1;
  if (api->image_copy_pixels (engine, image, false, &s->clip, &err) != GLIMS_STATUS_OK)
    {
      if (err)
        api->free_string (err);
      return -1;
    }
  return 0;
}

static int
image_snap_equal (const ImageSnap *a, const ImageSnap *b)
{
  return a->w == b->w && a->h == b->h &&
         memcmp (a->render, b->render, (size_t) a->w * (size_t) a->h * 4) == 0 &&
         a->undo.undo_count == b->undo.undo_count &&
         a->undo.redo_count == b->undo.redo_count &&
         strcmp (a->undo.next_undo, b->undo.next_undo) == 0 &&
         strcmp (a->undo.next_redo, b->undo.next_redo) == 0 &&
         a->sel_empty == b->sel_empty &&
         a->sel.x == b->sel.x && a->sel.y == b->sel.y &&
         a->sel.width == b->sel.width && a->sel.height == b->sel.height &&
         a->clip.bounds.x == b->clip.bounds.x && a->clip.bounds.y == b->clip.bounds.y &&
         a->clip.bounds.width == b->clip.bounds.width &&
         a->clip.bounds.height == b->clip.bounds.height &&
         a->clip.byte_count == b->clip.byte_count &&
         (a->clip.byte_count == 0 ||
          memcmp (a->clip.pixels, b->clip.pixels, a->clip.byte_count) == 0);
}

static void
image_snap_free (ImageSnap *s)
{
  free (s->render);
  if (s->clip.pixels)
    api->free_pixels (s->clip.pixels);
  memset (s, 0, sizeof *s);
}

static GlimsItemID
first_layer (GlimsImageID image)
{
  GlimsLayerInfo row;
  int32_t        count = 0;

  if (api->image_layers (engine, image, &row, 1, &count) != GLIMS_STATUS_OK || count < 1)
    return 0;
  return row.id;
}

/* ---- The known independent source pixels ------------------------------- */

#define SRC_W 3
#define SRC_H 2
static const uint8_t SOURCE_PIXELS[SRC_W * SRC_H * 4] = {
  255, 0,   0,   255,  /* opaque red */
  0,   255, 0,   128,  /* partial-alpha green */
  0,   0,   255, 0,    /* fully transparent blue */
  10,  20,  30,  40,   /* dark partial alpha */
  200, 100, 50,  255,  /* opaque, distinct RGB */
  1,   2,   3,   4     /* tiny values */
};
#define SRC_BYTES ((size_t) (SRC_W * SRC_H * 4))

#define FAULT_W 2
#define FAULT_H 2
static const uint8_t FAULT_PIXELS[FAULT_W * FAULT_H * 4] = {
  9, 8, 7, 6, 5, 4, 3, 200, 11, 12, 13, 14, 90, 80, 70, 60
};
#define FAULT_BYTES ((size_t) (FAULT_W * FAULT_H * 4))

static const char BRUSH_NAME[]   = "glims-test-brush-\xCE\xB1"; /* UTF-8 label */
static const char PATTERN_NAME[] = "glims-test-pattern";

/* ---- One armed fault case ---------------------------------------------- */

static void
fault_case (uint32_t kind, const char *save_dir, const char *ext, const char *uuid,
            int stage_sentinel, const char *name, uint32_t spacing, const char *label)
{
  char staging[4096], final_path[4096], staging_file[4096];
  char new_entries[8][256];
  DirSnap before, after;
  GlimsResourceInfo *rows_before = NULL, *rows_after = NULL;
  int32_t count_before = 0, count_after = 0;
  unsigned rep0, mkdir0, move0;
  GlimsResourceID out;
  char *err = NULL;
  GlimsStatus st;
  uint8_t *sentinel = NULL;
  size_t sentinel_len = 0;
  int i, n_new;

  snprintf (staging, sizeof staging, "%s/.glims-stage-%s", save_dir, uuid);
  snprintf (final_path, sizeof final_path, "%s/%s%s", save_dir, uuid, ext);
  snprintf (staging_file, sizeof staging_file, "%s/staging%s", staging, ext);

  /* Sentinel, owned by this test and inside WORK_DIR only. */
  if (stage_sentinel)
    {
      CHECK (mkdir_p (staging) == 0, "%s: pre-created empty hidden staging sentinel %s",
             label, staging);
    }
  else
    {
      sentinel_len = 64;
      sentinel = malloc (sentinel_len);
      for (i = 0; i < (int) sentinel_len; i++)
        sentinel[i] = (uint8_t) ('A' + (i % 26));
      memcpy (sentinel, "GLIMS-FINAL-SENTINEL", 20);
      CHECK (write_all (final_path, sentinel, sentinel_len) == 0,
             "%s: pre-created sentinel final file %s with unique bytes", label, final_path);
    }

  dir_snapshot (save_dir, &before);
  CHECK (get_resources (kind, &rows_before, &count_before) == GLIMS_STATUS_OK,
         "%s: catalog readable before the armed call", label);

  t_reset ();
  t_arm (uuid, save_dir, ext);
  CHECK (t_armed () == 1, "%s: shim armed around exactly this call", label);
  rep0 = t_uuid_replaced ();
  mkdir0 = t_mkdir_calls ();
  move0 = t_move_calls ();

  st = create_pixels (kind, name, FAULT_W, FAULT_H, FAULT_PIXELS, FAULT_BYTES,
                      spacing, &out, &err);

  t_disarm ();
  CHECK (t_armed () == 0, "%s: shim disarmed immediately after the call", label);

  CHECK (st == GLIMS_STATUS_FAILED && out == 0,
         "%s: colliding create refused with FAILED, outID %llu (want FAILED, 0)%s%s",
         label, (unsigned long long) out, err ? ": " : "", err ? err : "");
  if (err)
    api->free_string (err);

  /* The hook must have fired exactly once and matched the expected
   * operation and paths; any miss fails closed. */
  CHECK (t_uuid_replaced () - rep0 == 1 && t_last_uuid () &&
         strcmp (t_last_uuid (), uuid) == 0,
         "%s: deterministic uuid hook fired once and returned the armed uuid", label);
  CHECK (t_mkdir_calls () - mkdir0 >= 1 && t_last_mkdir_path () &&
         strcmp (t_last_mkdir_path (), staging) == 0,
         "%s: staging mkdir hook fired on the expected path %s", label, staging);
  CHECK (t_path_mismatch () == 0,
         "%s: every armed native path matched the harness-supplied folder under WORK_DIR",
         label);

  if (stage_sentinel)
    {
      CHECK (t_move_calls () - move0 == 0, "%s: no promotion attempted after staging collision",
             label);
      /* Baseline-RED oracle: buggy cleanup deletes this unowned empty
       * directory; correct cleanup must leave the sentinel in place. */
      CHECK (path_is_dir (staging), "%s: unowned empty staging sentinel %s SURVIVES",
             label, staging);
      dir_snapshot (staging, &after);
      CHECK (after.count == 0, "%s: surviving sentinel is still empty (%d entries)",
             label, after.count);
      CHECK (! path_is_file (final_path), "%s: no final file %s was created", label, final_path);
    }
  else
    {
      CHECK (t_move_calls () - move0 == 1 && t_last_move_dst () &&
             strcmp (t_last_move_dst (), final_path) == 0 &&
             t_last_move_src () && strcmp (t_last_move_src (), staging_file) == 0,
             "%s: promotion hook fired on the expected staged-to-final paths", label);
      CHECK (t_last_move_ok () == 0,
             "%s: native no-overwrite move refused the existing target (no forged success)",
             label);
      /* Baseline-RED oracle: buggy cleanup deletes the pre-existing
       * target; correct cleanup must leave the sentinel bytes intact. */
      CHECK (path_is_file (final_path), "%s: sentinel final file %s SURVIVES", label, final_path);
      {
        uint8_t *now = NULL;
        size_t now_len = 0;
        int same = read_all (final_path, &now, &now_len) == 0 &&
                   now_len == sentinel_len && memcmp (now, sentinel, sentinel_len) == 0;
        CHECK (same, "%s: sentinel bytes unchanged (%zu bytes)", label, now_len);
        free (now);
      }
      /* Owned leftovers of the failed call must be gone. */
      CHECK (! path_is_dir (staging), "%s: own staging directory %s removed", label, staging);
      CHECK (! path_is_file (staging_file), "%s: own staging file removed", label);
    }

  dir_snapshot (save_dir, &after);
  n_new = snap_new_entries (&before, &after, new_entries, 8);
  CHECK (n_new == 0 && snap_equal (&before, &after),
         "%s: save folder unchanged by the refused call (%d unexpected entries)", label, n_new);

  CHECK (get_resources (kind, &rows_after, &count_after) == GLIMS_STATUS_OK &&
         count_after == count_before && rows_equal (rows_before, count_before, rows_after, count_after),
         "%s: catalog unchanged (count %d -> %d)", label, count_before, count_after);

  free (rows_before);
  free (rows_after);
  free (sentinel);

  /* Remove only this test's own sentinel. */
  if (stage_sentinel)
    rmdir (staging);
  else
    unlink (final_path);
}

/* ---- Phases ------------------------------------------------------------- */

static int
start_engine (void)
{
  GlimsEngineConfig config = { 0 };
  char             *error = NULL;

  path_join (user_dir, sizeof user_dir, work, "user");
  path_join (cache_dir, sizeof cache_dir, work, "cache");
  path_join (brush_dir, sizeof brush_dir, user_dir, "brushes");
  path_join (pattern_dir, sizeof pattern_dir, user_dir, "patterns");

  /* Isolation: every native resource path the harness reasons about must
   * sit under the work directory. */
  if (strncmp (brush_dir, work, strlen (work)) != 0 ||
      strncmp (pattern_dir, work, strlen (work)) != 0)
    {
      fprintf (stderr, "FAIL  derived resource folders escape WORK_DIR\n");
      return 0;
    }

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

static int
phase_create (void)
{
  GlimsResourceInfo *base_brush = NULL, *base_pattern = NULL, *rows = NULL;
  int32_t            base_brush_n = 0, base_pattern_n = 0, n = 0;
  int32_t            created_brush = 0, created_pattern = 0;
  DirSnap            brush_before, brush_after, pattern_before, pattern_after;
  ImageSnap          snap0, snap1;
  GlimsPixelBuffer   clipboard_before = { 0 }, clipboard_after = { 0 };
  GlimsImageID       image = 0;
  GlimsItemID        layer = 0;
  GlimsResourceID    brush_id = 0, pattern_id = 0, id = 0;
  char              *err = NULL;
  uint8_t            source_copy[SRC_BYTES];
  char               new_entries[8][256];
  char               path[4096];
  char               brush_file[256] = "", pattern_file[256] = "";
  int                n_new, i;
  GlimsBrushSettings brush;
  GlimsStrokePoint   first = { 4.0, 4.0, 1.0, 0.0, 0.0, 0 };
  GlimsStrokeID      stroke = 0;
  GlimsFilterID      filter = 0;
  GlimsUndoInfo      undo_a, undo_b;

  CHECK (start_engine (), "engine started on the isolated directories");
  if (! engine)
    return 1;

  /* Meaningful stock baseline: the engine loads its own shipped data,
   * so the catalogs are non-empty before anything is created — the
   * "catalog unchanged" guards below are not vacuous. */
  CHECK (get_resources (GLIMS_RESOURCE_BRUSH, &base_brush, &base_brush_n) == GLIMS_STATUS_OK &&
         base_brush_n > 0, "stock brush baseline is meaningful (%d rows)", base_brush_n);
  CHECK (get_resources (GLIMS_RESOURCE_PATTERN, &base_pattern, &base_pattern_n) == GLIMS_STATUS_OK &&
         base_pattern_n > 0, "stock pattern baseline is meaningful (%d rows)", base_pattern_n);

  dir_snapshot (brush_dir, &brush_before);
  dir_snapshot (pattern_dir, &pattern_before);

  /* An image with full snapshots: creation takes no image and must not
   * disturb render, history, selection or the owned clipboard copy. */
  CHECK (api->image_new (engine, 16, 12, &image, &err) == GLIMS_STATUS_OK, "image_new 16x12");
  layer = first_layer (image);
  CHECK (layer != 0, "the new image has a layer");
  CHECK (image_snapshot (image, 16, 12, &snap0) == 0, "baseline image snapshot taken");
  CHECK (clipboard_snapshot (&clipboard_before), "native clipboard pattern snapshot taken");

  memcpy (source_copy, SOURCE_PIXELS, SRC_BYTES);

  /* ---- Happy path: brush ------------------------------------------- */
  CHECK (create_pixels (GLIMS_RESOURCE_BRUSH, BRUSH_NAME, SRC_W, SRC_H, source_copy,
                        SRC_BYTES, 25, &brush_id, &err) == GLIMS_STATUS_OK && brush_id > 0,
         "brush created from owned pixels, id %llu", (unsigned long long) brush_id);
  if (err) api->free_string (err), err = NULL;
  created_brush++;
  CHECK (memcmp (source_copy, SOURCE_PIXELS, SRC_BYTES) == 0,
         "the caller's RGBA buffer is unchanged by the call");
  memset (source_copy, 0xA5, sizeof source_copy);
  CHECK (get_resources (GLIMS_RESOURCE_BRUSH, &rows, &n) == GLIMS_STATUS_OK &&
         n == base_brush_n + 1 && rows_have (rows, n, brush_id, BRUSH_NAME),
         "brush catalog has exactly one new row with the exact name (count %d -> %d)",
         base_brush_n, n);
  free (rows), rows = NULL;
  check_identifiers_resolve (GLIMS_RESOURCE_BRUSH, brush_id, BRUSH_NAME, "brush");
  check_thumbnail (brush_id, SRC_W, SRC_H, SOURCE_PIXELS, "brush");

  dir_snapshot (brush_dir, &brush_after);
  n_new = snap_new_entries (&brush_before, &brush_after, new_entries, 8);
  CHECK (n_new == 1 && strlen (new_entries[0]) > 4 &&
         strcmp (new_entries[0] + strlen (new_entries[0]) - 4, ".gbr") == 0 &&
         strncmp (new_entries[0], ".glims-stage-", 13) != 0,
         "exactly one new durable .gbr file in the writable brush folder (%d new)", n_new);
  if (n_new == 1)
    {
      snprintf (brush_file, sizeof brush_file, "%s", new_entries[0]);
      path_join (path, sizeof path, brush_dir, brush_file);
      check_gbr_file (path, BRUSH_NAME, SRC_W, SRC_H, 25, SOURCE_PIXELS, SRC_BYTES,
                      "brush file");
    }
  CHECK (snap_count_prefix (&brush_after, ".glims-stage-") == 0,
         "no staging leftovers in the brush folder");

  CHECK (image_snapshot (image, 16, 12, &snap1) == 0 && image_snap_equal (&snap0, &snap1),
         "render, undo, selection and owned clipboard copy unchanged by the brush creation");
  image_snap_free (&snap1);

  /* ---- Happy path: pattern ------------------------------------------ */
  memcpy (source_copy, SOURCE_PIXELS, SRC_BYTES);
  CHECK (create_pixels (GLIMS_RESOURCE_PATTERN, PATTERN_NAME, SRC_W, SRC_H, source_copy,
                        SRC_BYTES, 0, &pattern_id, &err) == GLIMS_STATUS_OK && pattern_id > 0 &&
         pattern_id != brush_id,
         "pattern created from owned pixels, id %llu", (unsigned long long) pattern_id);
  if (err) api->free_string (err), err = NULL;
  created_pattern++;
  CHECK (memcmp (source_copy, SOURCE_PIXELS, SRC_BYTES) == 0,
         "pattern creation leaves the caller's RGBA buffer unchanged");
  memset (source_copy, 0x3C, sizeof source_copy);
  CHECK (get_resources (GLIMS_RESOURCE_PATTERN, &rows, &n) == GLIMS_STATUS_OK &&
         n == base_pattern_n + 1 && rows_have (rows, n, pattern_id, PATTERN_NAME),
         "pattern catalog has exactly one new row with the exact name (count %d -> %d)",
         base_pattern_n, n);
  free (rows), rows = NULL;
  check_identifiers_resolve (GLIMS_RESOURCE_PATTERN, pattern_id, PATTERN_NAME, "pattern");
  check_thumbnail (pattern_id, SRC_W, SRC_H, SOURCE_PIXELS, "pattern");

  dir_snapshot (pattern_dir, &pattern_after);
  n_new = snap_new_entries (&pattern_before, &pattern_after, new_entries, 8);
  CHECK (n_new == 1 && strlen (new_entries[0]) > 4 &&
         strcmp (new_entries[0] + strlen (new_entries[0]) - 4, ".pat") == 0 &&
         strncmp (new_entries[0], ".glims-stage-", 13) != 0,
         "exactly one new durable .pat file in the writable pattern folder (%d new)", n_new);
  if (n_new == 1)
    {
      snprintf (pattern_file, sizeof pattern_file, "%s", new_entries[0]);
      path_join (path, sizeof path, pattern_dir, pattern_file);
      check_pat_file (path, PATTERN_NAME, SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, "pattern file");
    }
  CHECK (snap_count_prefix (&pattern_after, ".glims-stage-") == 0,
         "no staging leftovers in the pattern folder");
  CHECK (image_snapshot (image, 16, 12, &snap1) == 0 && image_snap_equal (&snap0, &snap1),
         "image snapshots unchanged by the pattern creation");
  image_snap_free (&snap1);

  /* ---- Refusal battery: every failure zeroes the prefilled outID ----- */
  {
    char long_name[257];
    char *e2 = NULL;

    memset (long_name, 'a', 256);
    long_name[256] = '\0';

    CHECK (api->resource_create_pixels (engine, GLIMS_RESOURCE_BRUSH, "x", SRC_W, SRC_H,
                                        SOURCE_PIXELS, SRC_BYTES, 1, NULL, &e2)
           == GLIMS_STATUS_INVALID_ARGUMENT, "missing outID output is INVALID_ARGUMENT");
    if (e2) api->free_string (e2), e2 = NULL;

    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, 99, "k", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "unknown kind 99");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, 0, "k", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "kind 0");
    /* Baseline-RED oracle: the contract says gradient is UNSUPPORTED;
     * the current adapter answers FAILED. */
    expect_refusal (GLIMS_STATUS_UNSUPPORTED, GLIMS_RESOURCE_GRADIENT, "g", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 0, "gradient kind");

    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, NULL, SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "NULL name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "empty name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, long_name, SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "256-byte name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "a\nb", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "C0 control in name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "a\xC2\x80""b", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "C1 control in name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "a\xC3\x28""b", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "invalid UTF-8 name");

    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", 0, SRC_H, SOURCE_PIXELS, 0, 1, "width 0");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", -3, SRC_H, SOURCE_PIXELS, 0, 1, "negative width");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", 10001, SRC_H, SOURCE_PIXELS, 0, 1, "width over 10000");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, 0, SOURCE_PIXELS, 0, 1, "height 0");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, -1, SOURCE_PIXELS, 0, 1, "negative height");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, 10001, SOURCE_PIXELS, 0, 1, "height over 10000");

    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES - 1, 1, "byte count one short");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES + 1, 1, "byte count one over");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, SRC_H, NULL, SRC_BYTES, 1, "NULL pixels");

    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 0, "brush spacing 0");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1001, "brush spacing 1001");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_BRUSH, "d", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 0xFFFFFFFFu, "brush spacing huge");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_RESOURCE_PATTERN, "d", SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 1, "pattern spacing nonzero");

    expect_refusal (GLIMS_STATUS_FAILED, GLIMS_RESOURCE_BRUSH, BRUSH_NAME, SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 25, "duplicate brush name refused, never uniquified");
  }

  /* Catalog, files and image unchanged by the whole battery. */
  CHECK (get_resources (GLIMS_RESOURCE_BRUSH, &rows, &n) == GLIMS_STATUS_OK &&
         n == base_brush_n + created_brush && rows_have (rows, n, brush_id, BRUSH_NAME),
         "brush catalog after battery: %d rows (baseline %d + %d created, happy row intact)",
         n, base_brush_n, created_brush);
  free (rows), rows = NULL;
  CHECK (get_resources (GLIMS_RESOURCE_PATTERN, &rows, &n) == GLIMS_STATUS_OK &&
         n == base_pattern_n + created_pattern && rows_have (rows, n, pattern_id, PATTERN_NAME),
         "pattern catalog after battery: %d rows (baseline %d + %d created, happy row intact)",
         n, base_pattern_n, created_pattern);
  free (rows), rows = NULL;
  dir_snapshot (brush_dir, &brush_after);
  dir_snapshot (pattern_dir, &pattern_after);
  n_new = snap_new_entries (&brush_before, &brush_after, new_entries, 8);
  CHECK (n_new == 1, "exactly one file added to the brush folder by the battery phase (%d)", n_new);
  n_new = snap_new_entries (&pattern_before, &pattern_after, new_entries, 8);
  CHECK (n_new == 1, "exactly one file added to the pattern folder by the battery phase (%d)", n_new);
  CHECK (image_snapshot (image, 16, 12, &snap1) == 0 && image_snap_equal (&snap0, &snap1),
         "image snapshots unchanged by the refusal battery");
  image_snap_free (&snap1);

  /* ---- BUSY while a stroke or a filter session is active ------------- */
  memset (&brush, 0, sizeof brush);
  brush.struct_size = sizeof brush;
  brush.size        = 9.0;
  brush.opacity     = 1.0;
  brush.tool        = GLIMS_PAINT_PAINTBRUSH;
  brush.hardness    = -1.0;
  brush.rate        = -1.0;
  brush.flow        = -1.0;
  brush.exposure    = -1.0;

  CHECK (api->stroke_begin (engine, image, layer, &brush, &first, &stroke, &err) == GLIMS_STATUS_OK && stroke != 0,
         "stroke begun for the BUSY check");
  if (err) api->free_string (err), err = NULL;
  CHECK (api->image_undo_info (engine, image, &undo_a) == GLIMS_STATUS_OK, "undo readable during stroke");
  expect_refusal (GLIMS_STATUS_BUSY, GLIMS_RESOURCE_BRUSH, "glims-busy-stroke", SRC_W, SRC_H,
                  SOURCE_PIXELS, SRC_BYTES, 1, "create during an open stroke is BUSY");
  CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "stroke ended");
  CHECK (api->image_undo_info (engine, image, &undo_b) == GLIMS_STATUS_OK &&
         undo_b.undo_count == undo_a.undo_count + 1,
         "the refused create added no undo step (undo %d -> %d)", undo_a.undo_count, undo_b.undo_count);

  CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, &err) == GLIMS_STATUS_OK && filter != 0,
         "filter session begun for the BUSY check");
  if (err) api->free_string (err), err = NULL;
  expect_refusal (GLIMS_STATUS_BUSY, GLIMS_RESOURCE_BRUSH, "glims-busy-filter", SRC_W, SRC_H,
                  SOURCE_PIXELS, SRC_BYTES, 1, "create during an open filter session is BUSY");
  CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "filter aborted");
  CHECK (api->image_undo_info (engine, image, &undo_a) == GLIMS_STATUS_OK &&
         undo_a.undo_count == undo_b.undo_count,
         "the refused create and the aborted filter added no undo step (undo %d)", undo_a.undo_count);

  CHECK (create_pixels (GLIMS_RESOURCE_BRUSH, "glims-after-busy", SRC_W, SRC_H, SOURCE_PIXELS,
                        SRC_BYTES, 10, &id, &err) == GLIMS_STATUS_OK && id > 0,
         "create works again once nothing is busy, id %llu", (unsigned long long) id);
  if (err) api->free_string (err), err = NULL;
  created_brush++;
  CHECK (api->image_undo_info (engine, image, &undo_a) == GLIMS_STATUS_OK &&
         undo_a.undo_count == undo_b.undo_count,
         "a successful create adds no undo step (undo %d)", undo_a.undo_count);
  check_thumbnail (id, SRC_W, SRC_H, SOURCE_PIXELS, "after-busy brush");

  /* ---- Armed deterministic fault cases ------------------------------- */
  mkdir_p (brush_dir);
  mkdir_p (pattern_dir);
  fault_case (GLIMS_RESOURCE_BRUSH, brush_dir, ".gbr",
              "10000000-0000-4000-8000-000000000001", 1, "glims-fault-stage", 1,
              "staging collision (brush)");
  fault_case (GLIMS_RESOURCE_BRUSH, brush_dir, ".gbr",
              "10000000-0000-4000-8000-000000000002", 0, "glims-fault-final", 7,
              "final collision (brush)");
  fault_case (GLIMS_RESOURCE_PATTERN, pattern_dir, ".pat",
              "10000000-0000-4000-8000-000000000003", 0, "glims-fault-final-pat", 0,
              "final collision (pattern)");

  /* ---- Unarmed after the faults: the shim forwards and stays inert ---- */
  {
    unsigned rep_before = t_uuid_replaced ();

    CHECK (create_pixels (GLIMS_RESOURCE_BRUSH, "glims-unarmed", SRC_W, SRC_H, SOURCE_PIXELS,
                          SRC_BYTES, 3, &id, &err) == GLIMS_STATUS_OK && id > 0,
           "normal create succeeds after the fault cases, id %llu", (unsigned long long) id);
    if (err) api->free_string (err), err = NULL;
    created_brush++;
    CHECK (t_uuid_replaced () == rep_before,
           "shim replaced no uuid while disarmed (arming is isolated to the armed call)");
    check_identifiers_resolve (GLIMS_RESOURCE_BRUSH, id, "glims-unarmed", "unarmed brush");
    check_thumbnail (id, SRC_W, SRC_H, SOURCE_PIXELS, "unarmed brush");
    dir_snapshot (brush_dir, &brush_after);
    n_new = snap_new_entries (&brush_before, &brush_after, new_entries, 8);
    {
      int stray = 0;
      for (i = 0; i < n_new; i++)
        if (strstr (new_entries[i], "10000000-0000-4000-8000-00000000000") != NULL)
          stray = 1;
      CHECK (! stray, "no file from an armed deterministic uuid leaked into the folder");
    }
  }

  /* ---- Final state and restart handoff -------------------------------- */
  CHECK (get_resources (GLIMS_RESOURCE_BRUSH, &rows, &n) == GLIMS_STATUS_OK &&
         n == base_brush_n + created_brush,
         "final brush catalog: %d rows (baseline %d + %d created)", n, base_brush_n, created_brush);
  free (rows), rows = NULL;
  CHECK (get_resources (GLIMS_RESOURCE_PATTERN, &rows, &n) == GLIMS_STATUS_OK &&
         n == base_pattern_n + created_pattern,
         "final pattern catalog: %d rows (baseline %d + %d created)", n, base_pattern_n, created_pattern);
  free (rows), rows = NULL;
  dir_snapshot (brush_dir, &brush_after);
  dir_snapshot (pattern_dir, &pattern_after);
  CHECK (snap_count_prefix (&brush_after, ".glims-stage-") == 0 &&
         snap_count_prefix (&pattern_after, ".glims-stage-") == 0,
         "no staging leftovers anywhere at the end");
  CHECK (clipboard_snapshot (&clipboard_after) &&
         clipboard_equal (&clipboard_before, &clipboard_after),
         "native clipboard pattern pixels and dimensions unchanged by resource calls");
  if (clipboard_before.pixels) api->free_pixels (clipboard_before.pixels);
  if (clipboard_after.pixels) api->free_pixels (clipboard_after.pixels);

  {
    char handoff[4096], fpath[4096];
    FILE *f;

    path_join (handoff, sizeof handoff, work, "restart.txt");
    f = fopen (handoff, "w");
    CHECK (f != NULL, "restart handoff file opened");
    if (f)
      {
        char *nm = NULL, *coll = NULL, *e2 = NULL;
        bool internal = false;

        /* Record the happy brush and pattern identities plus their
         * durable file paths (captured at creation time). */
        if (api->resource_identifiers (engine, brush_id, &nm, &coll, &internal, &e2) == GLIMS_STATUS_OK &&
            brush_file[0])
          {
            path_join (fpath, sizeof fpath, brush_dir, brush_file);
            fprintf (f, "resource %u %s %s %d %s\n", GLIMS_RESOURCE_BRUSH, nm,
                     coll ? coll : "-", internal ? 1 : 0, fpath);
            api->free_string (nm);
            if (coll) api->free_string (coll);
          }
        if (e2) api->free_string (e2), e2 = NULL;
        if (api->resource_identifiers (engine, pattern_id, &nm, &coll, &internal, &e2) == GLIMS_STATUS_OK &&
            pattern_file[0])
          {
            path_join (fpath, sizeof fpath, pattern_dir, pattern_file);
            fprintf (f, "resource %u %s %s %d %s\n", GLIMS_RESOURCE_PATTERN, nm,
                     coll ? coll : "-", internal ? 1 : 0, fpath);
            api->free_string (nm);
            if (coll) api->free_string (coll);
          }
        if (e2) api->free_string (e2);
        fclose (f);
      }
  }

  free (base_brush);
  free (base_pattern);
  image_snap_free (&snap0);
  api->image_close (engine, image);
  api->stop (engine);
  engine = NULL;
  return 0;
}

static int
phase_verify (void)
{
  char handoff[4096], line[4096];
  FILE *f;
  int   entries = 0;

  CHECK (start_engine (), "engine restarted on the same isolated directories");
  if (! engine)
    return 1;

  path_join (handoff, sizeof handoff, work, "restart.txt");
  f = fopen (handoff, "r");
  CHECK (f != NULL, "restart handoff from the create phase exists");
  if (! f)
    return 1;

  while (fgets (line, sizeof line, f))
    {
      char kind_s[64], name[256], coll_s[512], internal_s[16], path[4096];
      unsigned kind;
      char    *err = NULL;
      bool     internal = false;
      GlimsResourceID id = 0;
      GlimsResourceInfo *rows = NULL;
      int32_t n = 0;

      if (sscanf (line, "resource %63s %255s %511s %15s %4095[^\n]",
                  kind_s, name, coll_s, internal_s, path) != 5)
        {
          CHECK (0, "handoff line parseable: %s", line);
          continue;
        }
      kind = (unsigned) strtoul (kind_s, NULL, 10);
      internal = strcmp (internal_s, "1") == 0;
      entries++;

      CHECK (api->resource_resolve (engine, kind, name,
                                    strcmp (coll_s, "-") == 0 ? NULL : coll_s,
                                    internal, &id, &err) == GLIMS_STATUS_OK && id > 0,
             "after restart: resolve(%u, \"%s\") -> id %llu", kind, name, (unsigned long long) id);
      if (err) api->free_string (err), err = NULL;
      CHECK (get_resources (kind, &rows, &n) == GLIMS_STATUS_OK && rows_have (rows, n, id, name),
             "after restart: catalog of kind %u contains the resolved row", kind);
      free (rows), rows = NULL;
      if (id > 0)
        {
          check_identifiers_resolve (kind, id, name, "restarted resource");
          check_thumbnail (id, SRC_W, SRC_H, SOURCE_PIXELS, "restarted thumbnail");
        }
      CHECK (path_is_file (path), "after restart: durable file %s still on disk", path);
      if (path_is_file (path))
        {
          if (kind == GLIMS_RESOURCE_BRUSH)
            check_gbr_file (path, name, SRC_W, SRC_H, 25, SOURCE_PIXELS, SRC_BYTES, "restarted brush file");
          else
            check_pat_file (path, name, SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, "restarted pattern file");
        }
    }
  fclose (f);
  CHECK (entries == 2, "both happy resources handed over for the restart check (%d)", entries);

  {
    DirSnap d;
    dir_snapshot (brush_dir, &d);
    CHECK (snap_count_prefix (&d, ".glims-stage-") == 0, "no staging leftovers after restart (brush)");
    dir_snapshot (pattern_dir, &d);
    CHECK (snap_count_prefix (&d, ".glims-stage-") == 0, "no staging leftovers after restart (pattern)");
  }

  {
    GlimsResourceID id = 0;
    char *err = NULL;
    CHECK (create_pixels (GLIMS_RESOURCE_PATTERN, "glims-restart-create", SRC_W, SRC_H,
                          SOURCE_PIXELS, SRC_BYTES, 0, &id, &err) == GLIMS_STATUS_OK && id > 0,
           "the restarted engine still creates into the durable folder, id %llu",
           (unsigned long long) id);
    if (err) api->free_string (err);
    if (id > 0)
      check_thumbnail (id, SRC_W, SRC_H, SOURCE_PIXELS, "restart-create thumbnail");
  }

  api->stop (engine);
  engine = NULL;
  return 0;
}

int
main (int argc, char **argv)
{
  void                 *library;
  GlimsEngineGetAPIFunction get_api;

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
  CHECK (api && api->api_version == GLIMS_ENGINE_API_VERSION &&
         api->struct_size >= sizeof (GlimsEngineAPI),
         "library serves facade version %u", GLIMS_ENGINE_API_VERSION);
  if (! api || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    return 2;

  /* Fail closed when the interposer controls are not exported. */
  if (! resolve_controls ())
    return 2;
  t_reset ();

  {
    int rc = strcmp (argv[3], "create") == 0 ? phase_create () : phase_verify ();

    if (rc != 0)
      failures++;
  }

  dlclose (library);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures ? 1 : 0;
}
