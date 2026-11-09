/*
 * Standalone facade-only tests for resource_duplicate (facade slot
 * 131), in the style of Engine/tests/resource-create-tests.c: the
 * adapter is loaded with dlopen() exactly as the app does, and only the
 * public facade in glims_engine.h is used — no GIMP/GLib types, no
 * private struct layouts, no engine object files. The armed fault cases
 * reuse Engine/tests/resource-create-interpose.c unchanged: the
 * duplicate path persists through the same staging/promotion calls
 * (g_uuid_string_random, g_file_make_directory, g_file_move).
 *
 *   resource-duplicate-tests LIBRARY WORK_DIR PHASE
 *
 * PHASE is "duplicate" or "verify". The engine can only be started once
 * per process, so scripts/test-resource-duplicate.py runs this binary
 * twice on the same isolated WORK_DIR: "duplicate" exercises everything
 * and records the persistent identities plus thumbnail hashes in
 * WORK_DIR/restart.txt; "verify" starts a fresh engine on the same
 * directories and checks that the saved duplicates load back and
 * resolve (true restart persistence).
 *
 * Everything the test touches lives under WORK_DIR: the engine's user
 * and cache directories, the sentinel files and the restart handoff.
 * The writable resource folders are pinned by the harness gimprc to
 * <user>/brushes, <user>/patterns and <user>/gradients.
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
static char brush_dir[4096], pattern_dir[4096], gradient_dir[4096];

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

#define MAX_DIR_ENTRIES 4096

typedef struct
{
  char names[MAX_DIR_ENTRIES][256];
  int  count;
} DirSnap;

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

static const GlimsResourceInfo *
row_by_id (const GlimsResourceInfo *rows, int32_t n, GlimsResourceID id)
{
  int32_t i;

  for (i = 0; i < n; i++)
    if (rows[i].id == id)
      return &rows[i];
  return NULL;
}

#define OUT_PREFILL ((GlimsResourceID) 0xDEADBEEFDEADBEEFULL)

static GlimsStatus
duplicate (GlimsResourceID source, const char *name, GlimsResourceID *out, char **err)
{
  *out = OUT_PREFILL;
  return api->resource_duplicate (engine, source, name, out, err);
}

/* Every refusal must leave outID at exactly 0, whatever was prefilled. */
static void
expect_refusal (GlimsStatus want, GlimsResourceID source, const char *name, const char *label)
{
  GlimsResourceID out;
  char           *err = NULL;
  GlimsStatus     st  = duplicate (source, name, &out, &err);

  CHECK (st == want && out == 0,
         "%s: status %d outID %llu (want %d, 0)%s%s",
         label, (int) st, (unsigned long long) out, (int) want,
         err ? ", message: " : "", err ? err : "");
  if (err)
    api->free_string (err);
}

static GlimsStatus
identifiers (GlimsResourceID id, char **name, char **collection, bool *internal, char **err)
{
  return api->resource_identifiers (engine, id, name, collection, internal, err);
}

static void
check_identifiers_resolve (uint32_t kind, GlimsResourceID id, const char *name,
                           const char *label)
{
  char            *nm = NULL, *coll = NULL, *err = NULL;
  bool             internal = false;
  GlimsResourceID  rid = 0;
  GlimsStatus      st;

  st = identifiers (id, &nm, &coll, &internal, &err);
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

/* FNV-1a over the thumbnail pixels, for the restart handoff. */
static uint64_t
fnv1a (const uint8_t *data, size_t len)
{
  uint64_t h = 1469598103934665603ULL;
  size_t   i;

  for (i = 0; i < len; i++)
    {
      h ^= data[i];
      h *= 1099511628211ULL;
    }
  return h;
}

/* Fresh thumbnail with explicit per-call FG/BG (gradients read both).
 * Returns 1 and fills `out` on success; the caller frees out->pixels. */
static int
thumbnail_fg_bg (GlimsResourceID id, const GlimsColor *fg, const GlimsColor *bg,
                 GlimsPixelBuffer *out)
{
  char       *err = NULL;
  GlimsStatus st  = api->resource_thumbnail (engine, id, 48, fg, bg, out, &err);
  int         ok  = st == GLIMS_STATUS_OK && out->pixels && out->byte_count > 0;

  if (err)
    api->free_string (err);
  if (! ok && out->pixels)
    {
      api->free_pixels (out->pixels);
      out->pixels = NULL;
    }
  return ok;
}

static int
thumbnail_equal (const GlimsPixelBuffer *a, const GlimsPixelBuffer *b)
{
  return a->bounds.x == b->bounds.x && a->bounds.y == b->bounds.y &&
         a->bounds.width == b->bounds.width && a->bounds.height == b->bounds.height &&
         a->byte_count == b->byte_count && a->pixels && b->pixels &&
         memcmp (a->pixels, b->pixels, a->byte_count) == 0;
}

/* Observe the native clipboard through its built-in pattern resource
 * (same oracle as the create tests; gimp-data-factories.c:251-254). */
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

/* ---- Image-side snapshot: duplication must not disturb it ------------- */

typedef struct
{
  int32_t       w, h;
  uint8_t      *render;
  GlimsUndoInfo undo;
  bool          sel_empty;
  GlimsRect     sel;
} ImageSnap;

static int
image_snapshot (GlimsImageID image, int32_t w, int32_t h, ImageSnap *s)
{
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
         a->sel.width == b->sel.width && a->sel.height == b->sel.height;
}

static void
image_snap_free (ImageSnap *s)
{
  free (s->render);
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

/* ---- Known pixel content for the created file-backed sources ---------- */

#define SRC_W 3
#define SRC_H 2
static const uint8_t SOURCE_PIXELS[SRC_W * SRC_H * 4] = {
  255, 0,   0,   255,
  0,   255, 0,   128,
  0,   0,   255, 0,
  10,  20,  30,  40,
  200, 100, 50,  255,
  1,   2,   3,   4
};
#define SRC_BYTES ((size_t) (SRC_W * SRC_H * 4))
#define SRC_SPACING 25

/* Native GBR v2 on-disk check for a duplicated bitmap brush: same
 * dimensions, spacing and payload as the pixel-created source, but the
 * requested duplicate name. */
static void
check_gbr_file (const char *path, const char *name, const char *label)
{
  uint8_t *f = NULL;
  size_t   len = 0, name_len = strlen (name), payload_off = 28 + name_len + 1;
  int      ok;

  ok = read_all (path, &f, &len) == 0 &&
       len == 28 + name_len + 1 + SRC_BYTES &&
       be32 (f + 0)  == 28 + name_len + 1 &&
       be32 (f + 4)  == 2 &&
       be32 (f + 8)  == SRC_W &&
       be32 (f + 12) == SRC_H &&
       be32 (f + 16) == 4 &&
       be32 (f + 20) == 0x47494D50u &&
       be32 (f + 24) == SRC_SPACING &&
       memcmp (f + 28, name, name_len + 1) == 0 &&
       memcmp (f + payload_off, SOURCE_PIXELS, SRC_BYTES) == 0;
  CHECK (ok, "%s: %s is native GBR v2 with the requested name and the exact source payload",
         label, path);
  free (f);
}

/* Native GGR on-disk check: text header carrying the requested name. */
static void
check_ggr_file (const char *path, const char *name, const char *label)
{
  uint8_t *f = NULL;
  size_t   len = 0;
  char     prefix[300];
  int      ok;

  snprintf (prefix, sizeof prefix, "GIMP Gradient\nName: %s\n", name);
  ok = read_all (path, &f, &len) == 0 && len > strlen (prefix) &&
       memcmp (f, prefix, strlen (prefix)) == 0;
  CHECK (ok, "%s: %s starts with the native GGR header and the requested name", label, path);
  free (f);
}

static int
extension_is (const char *filename, const char *ext)
{
  size_t n = strlen (filename), m = strlen (ext);

  return n > m && strcmp (filename + n - m, ext) == 0;
}

/* ---- One armed fault case around ONE duplicate call -------------------- */

static void
fault_case (GlimsResourceID source, uint32_t kind, const char *save_dir, const char *ext,
            const char *uuid, int stage_sentinel, const char *name, const char *label)
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

  st = duplicate (source, name, &out, &err);

  t_disarm ();
  CHECK (t_armed () == 0, "%s: shim disarmed immediately after the call", label);

  CHECK (st == GLIMS_STATUS_FAILED && out == 0,
         "%s: colliding duplicate refused with FAILED, outID %llu (want FAILED, 0)%s%s",
         label, (unsigned long long) out, err ? ": " : "", err ? err : "");
  if (err)
    api->free_string (err);

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
      CHECK (path_is_file (final_path), "%s: sentinel final file %s SURVIVES", label, final_path);
      {
        uint8_t *now = NULL;
        size_t now_len = 0;
        int same = read_all (final_path, &now, &now_len) == 0 &&
                   now_len == sentinel_len && memcmp (now, sentinel, sentinel_len) == 0;
        CHECK (same, "%s: sentinel bytes unchanged (%zu bytes)", label, now_len);
        free (now);
      }
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

  if (stage_sentinel)
    rmdir (staging);
  else
    unlink (final_path);
}

/* ---- One full duplicate roundtrip -------------------------------------- */

typedef struct
{
  GlimsResourceID  source;
  uint32_t         kind;
  char             kind_name[16];
  const char      *dir;          /* writable folder of the kind */
  const char      *accept_ext;   /* expected native extension */
  GlimsResourceID  dup;
  char             name[256];
  GlimsPixelBuffer thumb;        /* source thumbnail, for equivalence */
  char             file[256];    /* durable file name found after the call */
} DupCase;

static const GlimsColor FG = { 0.2, 0.4, 0.6, 1.0 };
static const GlimsColor BG = { 0.9, 0.1, 0.3, 1.0 };

/* Native extension set per kind: NULL `accept_ext` accepts any of the
 * kind's native save extensions (.gbr/.vbr/.gih decide the subclass). */
static int
extension_accepted (uint32_t kind, const char *accept_ext, const char *filename)
{
  if (accept_ext)
    return extension_is (filename, accept_ext);
  if (kind == GLIMS_RESOURCE_BRUSH)
    return extension_is (filename, ".gbr") || extension_is (filename, ".vbr") ||
           extension_is (filename, ".gih");
  if (kind == GLIMS_RESOURCE_PATTERN)
    return extension_is (filename, ".pat");
  return extension_is (filename, ".ggr");
}

/* Runs one duplicate of `source` under `name` and checks the whole
 * facade contract: distinct id, exact name, own kind, identity
 * roundtrip, thumbnail/payload equivalence (per-call FG/BG for
 * gradients), exactly one durable file with a native extension, no
 * staging leftovers, and an unchanged source. */
static int
run_dup_case (GlimsResourceID source, uint32_t kind, const char *kind_name,
              const char *dir, const char *accept_ext, const char *name, DupCase *out,
              const char *label)
{
  GlimsResourceInfo *rows = NULL;
  GlimsPixelBuffer   dup_thumb = { 0 };
  char              *err = NULL, *snm = NULL, *scoll = NULL;
  bool               sinternal = false;
  GlimsStatus        st;
  int32_t            n = 0;
  DirSnap            before, after;
  char               new_entries[8][256];
  char               path[4096];
  int                n_new, ok = 1;

  memset (out, 0, sizeof *out);
  out->source = source;
  out->kind = kind;
  snprintf (out->kind_name, sizeof out->kind_name, "%s", kind_name);
  out->dir = dir;
  out->accept_ext = accept_ext;
  snprintf (out->name, sizeof out->name, "%s", name);

  /* Source snapshot: identity + thumbnail (per-call FG/BG so gradient
   * FG/BG segments render identically for source and duplicate). */
  st = identifiers (source, &snm, &scoll, &sinternal, &err);
  CHECK (st == GLIMS_STATUS_OK && snm, "%s: source identifiers readable (%s)",
         label, snm ? snm : "?");
  if (err) api->free_string (err), err = NULL;
  CHECK (thumbnail_fg_bg (source, &FG, &BG, &out->thumb),
         "%s: source thumbnail rendered (%dx%d)", label,
         out->thumb.bounds.width, out->thumb.bounds.height);

  dir_snapshot (dir, &before);
  CHECK (get_resources (kind, &rows, &n) == GLIMS_STATUS_OK, "%s: catalog readable", label);
  free (rows), rows = NULL;

  st = duplicate (source, name, &out->dup, &err);
  CHECK (st == GLIMS_STATUS_OK && out->dup > 0 && out->dup != source,
         "%s: duplicate OK, id %llu (source %llu)%s%s", label,
         (unsigned long long) out->dup, (unsigned long long) source,
         err ? ", message: " : "", err ? err : "");
  if (err) api->free_string (err), err = NULL;
  if (st != GLIMS_STATUS_OK || out->dup == 0)
    {
      ok = 0;
      goto done;
    }

  /* Catalog: exactly one new row, own kind, exact requested name. */
  {
    GlimsResourceInfo *after_rows = NULL;
    int32_t            after_n = 0;
    GlimsStatus        st2 = get_resources (kind, &after_rows, &after_n);

    CHECK (st2 == GLIMS_STATUS_OK && after_n == n + 1 &&
           rows_have (after_rows, after_n, out->dup, name),
           "%s: catalog gained exactly one row, id+exact name (count %d -> %d)",
           label, n, after_n);
    free (after_rows);
  }

  check_identifiers_resolve (kind, out->dup, name, label);

  /* Thumbnail/payload equivalence with the same per-call colors. */
  CHECK (thumbnail_fg_bg (out->dup, &FG, &BG, &dup_thumb) &&
         thumbnail_equal (&out->thumb, &dup_thumb),
         "%s: duplicate thumbnail equals the source's under the same per-call FG/BG "
         "(%dx%d, %zu bytes)", label, dup_thumb.bounds.width, dup_thumb.bounds.height,
         dup_thumb.byte_count);
  if (dup_thumb.pixels)
    api->free_pixels (dup_thumb.pixels);

  /* Durable file: exactly one new non-hidden entry with the native
   * extension; no staging leftovers. */
  dir_snapshot (dir, &after);
  n_new = snap_new_entries (&before, &after, new_entries, 8);
  CHECK (n_new == 1 && extension_accepted (kind, accept_ext, new_entries[0]) &&
         strncmp (new_entries[0], ".glims-stage-", 13) != 0,
         "%s: exactly one new durable native-extension file in the writable %s folder (%d new)",
         label, kind_name, n_new);
  if (n_new == 1)
    {
      snprintf (out->file, sizeof out->file, "%s", new_entries[0]);
      path_join (path, sizeof path, dir, out->file);
      if (kind == GLIMS_RESOURCE_BRUSH && accept_ext && strcmp (accept_ext, ".gbr") == 0)
        check_gbr_file (path, name, label);
      else if (kind == GLIMS_RESOURCE_GRADIENT)
        check_ggr_file (path, name, label);
    }
  CHECK (snap_count_prefix (&after, ".glims-stage-") == 0,
         "%s: no staging leftovers in the %s folder", label, kind_name);

  /* Source unchanged: same identity, same thumbnail, same catalog row. */
  {
    char    *nm2 = NULL, *coll2 = NULL;
    bool     internal2 = false;
    GlimsPixelBuffer thumb2 = { 0 };
    GlimsResourceInfo *rows2 = NULL;
    int32_t            n2 = 0;

    st = identifiers (source, &nm2, &coll2, &internal2, &err);
    CHECK (st == GLIMS_STATUS_OK && nm2 && strcmp (nm2, snm ? snm : "") == 0 &&
           internal2 == sinternal &&
           (scoll == NULL ? coll2 == NULL : coll2 && strcmp (coll2, scoll) == 0),
           "%s: source identity unchanged (name \"%s\", internal %d)",
           label, nm2 ? nm2 : "?", (int) internal2);
    if (nm2)   api->free_string (nm2);
    if (coll2) api->free_string (coll2);
    if (err)   api->free_string (err), err = NULL;

    CHECK (thumbnail_fg_bg (source, &FG, &BG, &thumb2) &&
           thumbnail_equal (&out->thumb, &thumb2),
           "%s: source thumbnail unchanged by the duplication", label);
    if (thumb2.pixels)
      api->free_pixels (thumb2.pixels);

    CHECK (get_resources (kind, &rows2, &n2) == GLIMS_STATUS_OK &&
           n2 == n + 1 && row_by_id (rows2, n2, source) != NULL,
           "%s: source row still present in the catalog", label);
    free (rows2);
  }

done:
  if (snm)   api->free_string (snm);
  if (scoll) api->free_string (scoll);
  return ok;
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
  path_join (gradient_dir, sizeof gradient_dir, user_dir, "gradients");

  if (strncmp (brush_dir, work, strlen (work)) != 0 ||
      strncmp (pattern_dir, work, strlen (work)) != 0 ||
      strncmp (gradient_dir, work, strlen (work)) != 0)
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

/* Finds the first catalog row of `kind` with the wanted internal flag. */
static GlimsResourceID
find_row (uint32_t kind, int want_internal, int want_noninternal)
{
  GlimsResourceInfo *rows = NULL;
  int32_t            n = 0, i;
  GlimsResourceID    found = 0;

  if (get_resources (kind, &rows, &n) != GLIMS_STATUS_OK)
    {
      free (rows);
      return 0;
    }
  for (i = 0; i < n && ! found; i++)
    {
      char    *nm = NULL, *coll = NULL, *err = NULL;
      bool     internal = false;

      if (identifiers (rows[i].id, &nm, &coll, &internal, &err) != GLIMS_STATUS_OK)
        {
          if (nm) api->free_string (nm);
          if (coll) api->free_string (coll);
          if (err) api->free_string (err);
          continue;
        }
      if (nm) api->free_string (nm);
      if (coll) api->free_string (coll);
      if (err) api->free_string (err);
      if ((want_internal && internal) || (want_noninternal && ! internal))
        found = rows[i].id;
    }
  free (rows);
  return found;
}

#define MAX_CASES 8

static int
phase_duplicate (void)
{
  GlimsResourceInfo *rows = NULL;
  int32_t            n = 0;
  GlimsResourceID    pixel_brush = 0, pixel_pattern = 0;
  GlimsResourceID    stock_brush = 0, internal_brush = 0;
  GlimsResourceID    stock_pattern = 0, stock_gradient = 0, internal_gradient = 0;
  DupCase            cases[MAX_CASES];
  int                ncases = 0;
  ImageSnap          snap0, snap1;
  GlimsPixelBuffer   clipboard_before = { 0 }, clipboard_after = { 0 };
  GlimsImageID       image = 0;
  GlimsItemID        layer = 0;
  char              *err = NULL;
  int                i;

  {
    GlimsResourceID id = 123;
    CHECK (api->resource_duplicate (NULL, 1, "not-running", &id, &err)
           == GLIMS_STATUS_NOT_RUNNING && id == 0,
           "a call without a running engine clears its prefilled output handle");
    if (err) api->free_string (err), err = NULL;
  }

  CHECK (start_engine (), "engine started on the isolated directories");
  if (! engine)
    return 1;

  /* Meaningful stock baselines. */
  CHECK (get_resources (GLIMS_RESOURCE_BRUSH, &rows, &n) == GLIMS_STATUS_OK && n > 0,
         "stock brush baseline is meaningful (%d rows)", n);
  free (rows), rows = NULL;
  CHECK (get_resources (GLIMS_RESOURCE_PATTERN, &rows, &n) == GLIMS_STATUS_OK && n > 0,
         "stock pattern baseline is meaningful (%d rows)", n);
  free (rows), rows = NULL;
  CHECK (get_resources (GLIMS_RESOURCE_GRADIENT, &rows, &n) == GLIMS_STATUS_OK && n > 0,
         "stock gradient baseline is meaningful (%d rows)", n);
  free (rows), rows = NULL;

  /* Known file-backed sources with fully known content. */
  CHECK (api->resource_create_pixels (engine, GLIMS_RESOURCE_BRUSH, "glims-dup-src-brush",
                                      SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, SRC_SPACING,
                                      &pixel_brush, &err) == GLIMS_STATUS_OK && pixel_brush > 0,
         "file-backed source brush created, id %llu", (unsigned long long) pixel_brush);
  if (err) api->free_string (err), err = NULL;
  CHECK (api->resource_create_pixels (engine, GLIMS_RESOURCE_PATTERN, "glims-dup-src-pattern",
                                      SRC_W, SRC_H, SOURCE_PIXELS, SRC_BYTES, 0,
                                      &pixel_pattern, &err) == GLIMS_STATUS_OK && pixel_pattern > 0,
         "file-backed source pattern created, id %llu", (unsigned long long) pixel_pattern);
  if (err) api->free_string (err), err = NULL;

  /* Stock sources: file-backed brush/pattern/gradient plus the internal
   * read-only parametric brush and internal read-only gradient, where
   * the shipped catalogs provide them. */
  stock_brush        = find_row (GLIMS_RESOURCE_BRUSH, 0, 1);
  internal_brush     = find_row (GLIMS_RESOURCE_BRUSH, 1, 0);
  stock_pattern      = find_row (GLIMS_RESOURCE_PATTERN, 0, 1);
  stock_gradient     = find_row (GLIMS_RESOURCE_GRADIENT, 0, 1);
  internal_gradient  = find_row (GLIMS_RESOURCE_GRADIENT, 1, 0);
  CHECK (stock_brush != 0, "a file-backed stock brush is available (id %llu)",
         (unsigned long long) stock_brush);
  CHECK (stock_pattern != 0, "a file-backed stock pattern is available (id %llu)",
         (unsigned long long) stock_pattern);
  CHECK (stock_gradient != 0, "a file-backed stock gradient is available (id %llu)",
         (unsigned long long) stock_gradient);
  CHECK (internal_brush != 0, "an internal read-only brush is available (id %llu)",
         (unsigned long long) internal_brush);
  CHECK (internal_gradient != 0, "an internal read-only gradient is available (id %llu)",
         (unsigned long long) internal_gradient);

  /* An image with full snapshots: duplication takes no image and must
   * not disturb render, history or selection. */
  CHECK (api->image_new (engine, 16, 12, &image, &err) == GLIMS_STATUS_OK, "image_new 16x12");
  layer = first_layer (image);
  CHECK (layer != 0, "the new image has a layer");
  CHECK (image_snapshot (image, 16, 12, &snap0) == 0, "baseline image snapshot taken");
  CHECK (clipboard_snapshot (&clipboard_before), "native clipboard pattern snapshot taken");

  mkdir_p (brush_dir);
  mkdir_p (pattern_dir);
  mkdir_p (gradient_dir);

  /* ---- Happy-path duplicate cases ------------------------------------ */
  CHECK (run_dup_case (pixel_brush, GLIMS_RESOURCE_BRUSH, "brush", brush_dir, ".gbr",
                      "glims-dup-brush-pixels", &cases[ncases++], "pixel brush"),
         "pixel brush duplicated end to end");
  CHECK (run_dup_case (pixel_pattern, GLIMS_RESOURCE_PATTERN, "pattern", pattern_dir, ".pat",
                      "glims-dup-pattern-pixels", &cases[ncases++], "pixel pattern"),
         "pixel pattern duplicated end to end");
  if (stock_brush)
    /* accept_ext NULL: the stock brush's subclass decides the native
     * extension (.gbr/.vbr/.gih), accepted as a set. */
    CHECK (run_dup_case (stock_brush, GLIMS_RESOURCE_BRUSH, "brush", brush_dir, NULL,
                        "glims-dup-stock-brush", &cases[ncases++], "stock brush"),
           "file-backed stock brush duplicated end to end");
  if (internal_brush)
    CHECK (run_dup_case (internal_brush, GLIMS_RESOURCE_BRUSH, "brush", brush_dir, NULL,
                        "glims-dup-internal-brush", &cases[ncases++], "internal parametric brush"),
           "internal read-only parametric brush duplicated end to end");
  if (stock_pattern)
    CHECK (run_dup_case (stock_pattern, GLIMS_RESOURCE_PATTERN, "pattern", pattern_dir, ".pat",
                        "glims-dup-stock-pattern", &cases[ncases++], "stock pattern"),
           "file-backed stock pattern duplicated end to end");
  if (stock_gradient)
    CHECK (run_dup_case (stock_gradient, GLIMS_RESOURCE_GRADIENT, "gradient", gradient_dir, ".ggr",
                        "glims-dup-stock-gradient", &cases[ncases++], "stock gradient"),
           "file-backed stock gradient duplicated end to end");
  if (internal_gradient)
    CHECK (run_dup_case (internal_gradient, GLIMS_RESOURCE_GRADIENT, "gradient", gradient_dir, ".ggr",
                        "glims-dup-internal-gradient", &cases[ncases++], "internal gradient"),
           "internal read-only gradient duplicated end to end");

  /* ---- Refusal battery: every failure zeroes the prefilled outID ----- */
  {
    char long_name[257];
    char *e2 = NULL;

    memset (long_name, 'a', 256);
    long_name[256] = '\0';

    CHECK (api->resource_duplicate (engine, pixel_brush, "x", NULL, &e2)
           == GLIMS_STATUS_INVALID_ARGUMENT, "missing outID output is INVALID_ARGUMENT");
    if (e2) api->free_string (e2), e2 = NULL;

    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, pixel_brush, NULL, "NULL name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, pixel_brush, "", "empty name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, pixel_brush, long_name, "256-byte name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, pixel_brush, "a\nb", "C0 control in name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, pixel_brush, "a\xC2\x80""b", "C1 control in name");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, pixel_brush, "a\xC3\x28""b", "invalid UTF-8 name");

    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, 0, "k", "source id 0");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, 0xFFFFFFFFFFFFFFFFULL, "k", "all-high-bits source");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, 1ULL << 40, "k", "high-bit source");
    expect_refusal (GLIMS_STATUS_INVALID_ARGUMENT, 0x8000000000000000ULL, "k", "sign-bit source");
    expect_refusal (GLIMS_STATUS_NOT_FOUND, 2147483647LL, "k", "in-range but unresolvable source (G_MAXINT)");
    expect_refusal (GLIMS_STATUS_NOT_FOUND, 2000000000LL, "k", "stale-looking in-range source");

    /* Exact same-kind name collision: FAILED, never uniquified. */
    expect_refusal (GLIMS_STATUS_FAILED, pixel_brush, "glims-dup-brush-pixels",
                    "same-kind exact name collision (brush)");
    expect_refusal (GLIMS_STATUS_FAILED, pixel_pattern, "glims-dup-pattern-pixels",
                    "same-kind exact name collision (pattern)");

    /* A different kind may reuse the name: not a collision. */
    {
      GlimsResourceID out = 0;
      GlimsStatus st = duplicate (pixel_pattern, "glims-dup-brush-pixels", &out, &err);
      CHECK (st == GLIMS_STATUS_OK && out > 0,
             "pattern may reuse a brush's name (kinds are separate catalogs), id %llu",
             (unsigned long long) out);
      if (err) api->free_string (err), err = NULL;
    }
  }

  /* Catalog/files/image unchanged by the battery except the intended
   * cross-kind success. */
  CHECK (image_snapshot (image, 16, 12, &snap1) == 0 && image_snap_equal (&snap0, &snap1),
         "render, undo and selection unchanged by the whole duplication battery");
  image_snap_free (&snap1);
  CHECK (clipboard_snapshot (&clipboard_after) &&
         thumbnail_equal (&clipboard_before, &clipboard_after),
         "native clipboard pattern unchanged by resource duplication");
  if (clipboard_before.pixels) api->free_pixels (clipboard_before.pixels);
  if (clipboard_after.pixels)  api->free_pixels (clipboard_after.pixels);

  /* ---- BUSY while a stroke or a filter session is active ------------- */
  {
    GlimsBrushSettings brush;
    GlimsStrokePoint   first = { 4.0, 4.0, 1.0, 0.0, 0.0, 0 };
    GlimsStrokeID      stroke = 0;
    GlimsFilterID      filter = 0;
    GlimsUndoInfo      undo_a, undo_b;

    memset (&brush, 0, sizeof brush);
    brush.struct_size = sizeof brush;
    brush.size        = 9.0;
    brush.opacity     = 1.0;
    brush.tool        = GLIMS_PAINT_PAINTBRUSH;
    brush.hardness    = -1.0;
    brush.rate        = -1.0;
    brush.flow        = -1.0;
    brush.exposure    = -1.0;

    CHECK (api->stroke_begin (engine, image, layer, &brush, &first, &stroke, &err)
           == GLIMS_STATUS_OK && stroke != 0, "stroke begun for the BUSY check");
    if (err) api->free_string (err), err = NULL;
    CHECK (api->image_undo_info (engine, image, &undo_a) == GLIMS_STATUS_OK,
           "undo readable during stroke");
    expect_refusal (GLIMS_STATUS_BUSY, pixel_brush, "glims-dup-busy-stroke",
                    "duplicate during an open stroke is BUSY");
    CHECK (api->stroke_end (engine, stroke) == GLIMS_STATUS_OK, "stroke ended");
    CHECK (api->image_undo_info (engine, image, &undo_b) == GLIMS_STATUS_OK &&
           undo_b.undo_count == undo_a.undo_count + 1,
           "the refused duplicate added no undo step (undo %d -> %d)",
           undo_a.undo_count, undo_b.undo_count);

    CHECK (api->filter_begin (engine, image, layer, "gegl:gaussian-blur", &filter, &err)
           == GLIMS_STATUS_OK && filter != 0, "filter session begun for the BUSY check");
    if (err) api->free_string (err), err = NULL;
    expect_refusal (GLIMS_STATUS_BUSY, pixel_brush, "glims-dup-busy-filter",
                    "duplicate during an open filter session is BUSY");
    CHECK (api->filter_abort (engine, filter) == GLIMS_STATUS_OK, "filter aborted");
    CHECK (api->image_undo_info (engine, image, &undo_a) == GLIMS_STATUS_OK &&
           undo_a.undo_count == undo_b.undo_count,
           "the refused duplicate and the aborted filter added no undo step (undo %d)",
           undo_a.undo_count);

    CHECK (duplicate (pixel_brush, "glims-dup-after-busy", &cases[ncases].dup, &err)
           == GLIMS_STATUS_OK && cases[ncases].dup > 0,
           "duplicate works again once nothing is busy, id %llu",
           (unsigned long long) cases[ncases].dup);
    if (err) api->free_string (err), err = NULL;
    if (cases[ncases].dup > 0)
      {
        cases[ncases].source = pixel_brush;
        cases[ncases].kind = GLIMS_RESOURCE_BRUSH;
        snprintf (cases[ncases].kind_name, sizeof cases[ncases].kind_name, "brush");
        cases[ncases].dir = brush_dir;
        cases[ncases].accept_ext = ".gbr";
        snprintf (cases[ncases].name, sizeof cases[ncases].name, "glims-dup-after-busy");
        CHECK (thumbnail_fg_bg (pixel_brush, &FG, &BG, &cases[ncases].thumb),
               "after-busy source thumbnail rendered");
        ncases++;
      }
  }

  /* ---- Armed deterministic fault cases -------------------------------- */
  fault_case (pixel_brush, GLIMS_RESOURCE_BRUSH, brush_dir, ".gbr",
              "20000000-0000-4000-8000-000000000001", 1, "glims-dup-fault-stage",
              "staging collision (brush duplicate)");
  fault_case (pixel_brush, GLIMS_RESOURCE_BRUSH, brush_dir, ".gbr",
              "20000000-0000-4000-8000-000000000002", 0, "glims-dup-fault-final",
              "final collision (brush duplicate)");
  fault_case (stock_gradient ? stock_gradient : pixel_pattern,
              stock_gradient ? GLIMS_RESOURCE_GRADIENT : GLIMS_RESOURCE_PATTERN,
              stock_gradient ? gradient_dir : pattern_dir,
              stock_gradient ? ".ggr" : ".pat",
              "20000000-0000-4000-8000-000000000003", 0, "glims-dup-fault-final-2",
              "final collision (gradient/pattern duplicate)");

  /* ---- Unarmed after the faults: the shim forwards and stays inert ---- */
  {
    unsigned rep_before = t_uuid_replaced ();
    GlimsResourceID out = 0;

    CHECK (duplicate (pixel_brush, "glims-dup-unarmed", &out, &err) == GLIMS_STATUS_OK && out > 0,
           "normal duplicate succeeds after the fault cases, id %llu",
           (unsigned long long) out);
    if (err) api->free_string (err), err = NULL;
    CHECK (t_uuid_replaced () == rep_before,
           "shim replaced no uuid while disarmed (arming is isolated to the armed call)");
    if (out > 0)
      check_identifiers_resolve (GLIMS_RESOURCE_BRUSH, out, "glims-dup-unarmed", "unarmed dup");
    {
      DirSnap d;
      dir_snapshot (brush_dir, &d);
      CHECK (snap_count_prefix (&d, ".glims-stage-") == 0, "no staging leftovers after faults");
      {
        int i2, stray = 0;
        for (i2 = 0; i2 < d.count; i2++)
          if (strstr (d.names[i2], "20000000-0000-4000-8000-00000000000") != NULL)
            stray = 1;
        CHECK (! stray, "no file from an armed deterministic uuid leaked into the folder");
      }
    }
  }

  /* ---- Restart handoff -------------------------------------------------- */
  {
    char handoff[4096];
    FILE *f;

    path_join (handoff, sizeof handoff, work, "restart.txt");
    f = fopen (handoff, "w");
    CHECK (f != NULL, "restart handoff file opened");
    if (f)
      {
        for (i = 0; i < ncases; i++)
          {
            char *nm = NULL, *coll = NULL, *e2 = NULL;
            bool internal = false;
            char fpath[4096];

            if (! cases[i].file[0] || ! cases[i].thumb.pixels)
              continue;
            if (identifiers (cases[i].dup, &nm, &coll, &internal, &e2) == GLIMS_STATUS_OK)
              {
                path_join (fpath, sizeof fpath, cases[i].dir, cases[i].file);
                fprintf (f, "resource %u %s %s %d %s %llu %d %d %zu\n",
                         cases[i].kind, nm, coll ? coll : "-", internal ? 1 : 0, fpath,
                         (unsigned long long) fnv1a (cases[i].thumb.pixels, cases[i].thumb.byte_count),
                         cases[i].thumb.bounds.width, cases[i].thumb.bounds.height,
                         cases[i].thumb.byte_count);
                api->free_string (nm);
                if (coll) api->free_string (coll);
              }
            if (e2) api->free_string (e2);
          }
        fclose (f);
      }
  }

  for (i = 0; i < ncases; i++)
    if (cases[i].thumb.pixels)
      api->free_pixels (cases[i].thumb.pixels);

  image_snap_free (&snap0);
  api->image_close (engine, image);
  api->stop (engine);
  engine = NULL;
  return 0;
}

static int
phase_verify (void)
{
  char handoff[4096], line[8192];
  FILE *f;
  int   entries = 0;

  CHECK (start_engine (), "engine restarted on the same isolated directories");
  if (! engine)
    return 1;

  path_join (handoff, sizeof handoff, work, "restart.txt");
  f = fopen (handoff, "r");
  CHECK (f != NULL, "restart handoff from the duplicate phase exists");
  if (! f)
    return 1;

  while (fgets (line, sizeof line, f))
    {
      char kind_s[64], name[256], coll_s[512], internal_s[16], path[4096];
      unsigned long long hash;
      int w, h;
      size_t bytes;
      unsigned kind;
      char    *err = NULL;
      bool     internal = false;
      GlimsResourceID id = 0;
      GlimsResourceInfo *rows = NULL;
      int32_t n = 0;
      GlimsPixelBuffer thumb = { 0 };

      if (sscanf (line, "resource %63s %255s %511s %15s %4095[^ ] %llu %d %d %zu",
                  kind_s, name, coll_s, internal_s, path, &hash, &w, &h, &bytes) != 9)
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
             "after restart: resolve(%u, \"%s\") -> id %llu", kind, name,
             (unsigned long long) id);
      if (err) api->free_string (err), err = NULL;
      CHECK (get_resources (kind, &rows, &n) == GLIMS_STATUS_OK && rows_have (rows, n, id, name),
             "after restart: catalog of kind %u contains the resolved row \"%s\"", kind, name);
      free (rows), rows = NULL;
      if (id > 0)
        {
          check_identifiers_resolve (kind, id, name, "restarted duplicate");
          CHECK (thumbnail_fg_bg (id, &FG, &BG, &thumb),
                 "after restart: thumbnail of \"%s\" rendered (%dx%d)", name,
                 thumb.bounds.width, thumb.bounds.height);
          CHECK (thumb.pixels && thumb.bounds.width == w && thumb.bounds.height == h &&
                 thumb.byte_count == bytes &&
                 fnv1a (thumb.pixels, thumb.byte_count) == hash,
                 "after restart: thumbnail of \"%s\" is byte-identical to the pre-restart one",
                 name);
          if (thumb.pixels)
            api->free_pixels (thumb.pixels);
        }
      CHECK (path_is_file (path), "after restart: durable file %s still on disk", path);
      if (path_is_file (path))
        {
          if (kind == GLIMS_RESOURCE_BRUSH &&
              (strcmp (name, "glims-dup-brush-pixels") == 0 ||
               strcmp (name, "glims-dup-after-busy") == 0))
            /* The pixel-created source's duplicate: exact payload oracle. */
            check_gbr_file (path, name, "restarted pixel-brush duplicate file");
          else if (kind == GLIMS_RESOURCE_BRUSH)
            {
              /* Any brush subclass: at least a native GBR/GIH/VBR header
               * check — GBR magic for bitmaps, text header for the rest. */
              uint8_t *fb = NULL;
              size_t   fl = 0;
              int      ok = read_all (path, &fb, &fl) == 0 && fl > 28 &&
                           (be32 (fb + 20) == 0x47494D50u || /* 'GIMP' (gbr) */
                            memcmp (fb, name, strlen (name)) == 0); /* gih text starts with the name */
              CHECK (ok, "after restart: brush duplicate file %s has a native header", path);
              free (fb);
            }
          else if (kind == GLIMS_RESOURCE_GRADIENT)
            check_ggr_file (path, name, "restarted gradient duplicate file");
        }
    }
  fclose (f);
  CHECK (entries >= 4, "the handed-over duplicates are checked after restart (%d entries)", entries);

  {
    DirSnap d;
    dir_snapshot (brush_dir, &d);
    CHECK (snap_count_prefix (&d, ".glims-stage-") == 0, "no staging leftovers after restart (brush)");
    dir_snapshot (pattern_dir, &d);
    CHECK (snap_count_prefix (&d, ".glims-stage-") == 0, "no staging leftovers after restart (pattern)");
    dir_snapshot (gradient_dir, &d);
    CHECK (snap_count_prefix (&d, ".glims-stage-") == 0, "no staging leftovers after restart (gradient)");
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

  if (argc != 4 || (strcmp (argv[3], "duplicate") != 0 && strcmp (argv[3], "verify") != 0))
    {
      fprintf (stderr, "usage: %s LIBRARY WORK_DIR duplicate|verify\n", argv[0]);
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

  if (! resolve_controls ())
    return 2;
  t_reset ();

  {
    int rc = strcmp (argv[3], "duplicate") == 0 ? phase_duplicate () : phase_verify ();

    if (rc != 0)
      failures++;
  }

  dlclose (library);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures ? 1 : 0;
}
