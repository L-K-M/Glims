/*
 * resource-duplicate-persistence-tests.c — deterministic Core-linked
 * regression harness for saved brush/gradient/pattern duplication.
 *
 *   resource-duplicate-persistence-tests WORK_DIR
 *
 * Test-only file. It links the selected adapter producer objects and GIMP's
 * gimp-console objects directly (no dlopen, no libgimp), includes
 * Engine/engine-private.h, and runs all fixture/test code on the engine
 * thread through one glims_engine_call(). Facade slot 131
 * (api->resource_duplicate) is invoked from that engine-thread callback.
 *
 * Covered oracles:
 *  - generated .vbr brushes and .ggr gradients reject leading/trailing/all
 *    ASCII whitespace names with GLIMS_STATUS_INVALID_ARGUMENT before save;
 *  - canonical generated brushes/gradients duplicate to durable native files
 *    whose private native loaders reproduce name and parameters/segments;
 *  - clipboard-derived .pat patterns reject noncanonical Babl formats with
 *    GLIMS_STATUS_UNSUPPORTED before save;
 *  - canonical Y/Y'A/RGB/RGBA U8 patterns duplicate byte-exact PAT payloads
 *    whose private native loader reproduces name, dimensions, format and
 *    pixels.
 */
#include "engine-private.h"

#include <dirent.h>
#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <babl/babl.h>
#include <gegl-buffer.h>

#include "core/core-enums.h"
#include "core/gimp.h"
#include "core/gimpbuffer.h"
#include "core/gimpbrush.h"
#include "core/gimpbrushgenerated.h"
#include "core/gimpbrushgenerated-load.h"
#include "core/gimpcontainer.h"
#include "core/gimpcontext.h"
#include "core/gimpdata.h"
#include "core/gimpdatafactory.h"
#include "core/gimpgradient.h"
#include "core/gimpgradient-load.h"
#include "core/gimpimage.h"
#include "core/gimpobject.h"
#include "core/gimppattern.h"
#include "core/gimppattern-load.h"
#include "core/gimppatternclipboard.h"
#include "core/gimppattern-header.h"
#include "core/gimptempbuf.h"

int main (int argc, char **argv);

#define MAX_SEGMENTS 8
#define MAX_DIR_ENTRIES 512
#define MAX_CAT_ENTRIES 4096

typedef struct
{
  GlimsEngine            *engine;
  const GlimsEngineAPI   *api;
  Gimp                   *gimp;
  GimpContext            *context;
  const char             *work;
  int                     failures;
} Probe;

typedef enum
{
  SNAP_BRUSH,
  SNAP_GRADIENT,
  SNAP_PATTERN
} SnapKind;

typedef struct
{
  double left, middle, right;
  int    left_color_type, right_color_type;
  int    type, color;
  float  left_rgba[4];
  float  right_rgba[4];
} SegmentSnap;

typedef struct
{
  SnapKind       kind;
  GlimsResourceID id;
  char          *name;
  guint32        resource_kind;
  gboolean       dirty;
  char          *file_path;
  gchar         *file_bytes;
  gsize          file_len;
  gint           thumb_width, thumb_height;
  gsize          thumb_bytes;
  uint64_t       thumb_hash;

  /* Brush payload. */
  int            shape;
  gfloat         radius;
  int            spikes;
  gfloat         hardness;
  gfloat         aspect_ratio;
  gfloat         angle;
  int            spacing;

  /* Gradient payload. */
  int            segment_count;
  SegmentSnap    segments[MAX_SEGMENTS];

  /* Pattern payload. */
  const Babl    *format;
  gint           mask_width, mask_height;
  guchar        *mask_pixels;
  gsize          mask_len;
} SourceSnap;

typedef struct
{
  char     name[512];
  gboolean is_dir;
  gchar   *bytes;
  gsize    len;
} DirEntry;

typedef struct
{
  DirEntry entries[MAX_DIR_ENTRIES];
  int      count;
  gboolean missing;
} DirSnap;

typedef struct
{
  GlimsResourceID id;
  guint32         kind;
  char            name[512];
} CatEntry;

typedef struct
{
  CatEntry *entries;
  int       count;
} CatSnap;

static const GlimsEngineAPI *api;

static void
check (Probe *probe, gboolean condition, const char *fmt, ...)
{
  va_list args;

  printf (condition ? "ok    " : "FAIL  ");
  va_start (args, fmt);
  vprintf (fmt, args);
  va_end (args);
  printf ("\n");
  fflush (stdout);
  if (! condition)
    probe->failures++;
}

static void
fixture_fail (Probe *probe, const char *fmt, ...)
{
  va_list args;

  printf ("FIXTURE-FAIL  ");
  va_start (args, fmt);
  vprintf (fmt, args);
  va_end (args);
  printf ("\n");
  fflush (stdout);
  probe->failures++;
}

#define CHECK(...) check (probe, __VA_ARGS__)
#define FIXTURE(condition, ...)                                       \
  do {                                                                \
    if (! (condition)) {                                              \
      fixture_fail (probe, __VA_ARGS__);                              \
      return;                                                         \
    }                                                                 \
  } while (0)
#define HARD_FAIL(...)                                                \
  do {                                                                \
    fixture_fail (probe, __VA_ARGS__);                                \
  } while (0)

static uint64_t
fnv1a (const void *data, gsize len)
{
  const guchar *p = data;
  uint64_t      h = UINT64_C (14695981039346656037);
  gsize         i;

  for (i = 0; i < len; i++)
    {
      h ^= p[i];
      h *= UINT64_C (1099511628211);
    }
  return h;
}

static guint32
resource_kind_of_data (GimpData *data)
{
  if (GIMP_IS_BRUSH (data))
    return GLIMS_RESOURCE_BRUSH;
  if (GIMP_IS_PATTERN (data))
    return GLIMS_RESOURCE_PATTERN;
  if (GIMP_IS_GRADIENT (data))
    return GLIMS_RESOURCE_GRADIENT;
  return 0;
}

static GimpDataFactory *
factory_for_kind (Gimp *gimp, guint32 kind)
{
  switch (kind)
    {
    case GLIMS_RESOURCE_BRUSH:    return gimp->brush_factory;
    case GLIMS_RESOURCE_PATTERN: return gimp->pattern_factory;
    case GLIMS_RESOURCE_GRADIENT: return gimp->gradient_factory;
    default:                     return NULL;
    }
}

static GimpContainer *
container_for_kind (Gimp *gimp, guint32 kind)
{
  GimpDataFactory *factory = factory_for_kind (gimp, kind);
  return factory ? gimp_data_factory_get_container (factory) : NULL;
}

static const char *
resource_dir_name (guint32 kind)
{
  switch (kind)
    {
    case GLIMS_RESOURCE_BRUSH:    return "brushes";
    case GLIMS_RESOURCE_PATTERN: return "patterns";
    case GLIMS_RESOURCE_GRADIENT: return "gradients";
    default:                     return NULL;
    }
}

static gboolean
read_file_bytes (const gchar *path, gchar **bytes, gsize *len)
{
  return g_file_get_contents (path, bytes, len, NULL);
}

static void
snap_free_common (SourceSnap *snap)
{
  g_free (snap->name);
  g_free (snap->file_path);
  g_free (snap->file_bytes);
  g_free (snap->mask_pixels);
}

static gboolean
snap_thumb (Probe *probe, GlimsResourceID id, SourceSnap *snap)
{
  GlimsPixelBuffer thumb = { 0 };
  char             *err   = NULL;
  GlimsStatus       st;

  snap->thumb_width = snap->thumb_height = 0;
  snap->thumb_bytes = 0;
  snap->thumb_hash  = 0;

  st = api->resource_thumbnail (probe->engine, id, 48, NULL, NULL, &thumb, &err);
  if (err)
    api->free_string (err);
  if (st != GLIMS_STATUS_OK || ! thumb.pixels)
    return FALSE;

  snap->thumb_width  = thumb.bounds.width;
  snap->thumb_height = thumb.bounds.height;
  snap->thumb_bytes  = thumb.byte_count;
  snap->thumb_hash   = fnv1a (thumb.pixels, thumb.byte_count);
  api->free_pixels (thumb.pixels);
  return TRUE;
}

static gboolean
source_snap_take_id (Probe *probe, GlimsResourceID id, SnapKind kind,
                     SourceSnap *snap)
{
  GimpData *data = NULL;
  GlimsStatus status;
  GFile     *file;

  memset (snap, 0, sizeof *snap);
  snap->kind = kind;
  snap->id   = id;

  status = glims_lookup_resource_data (probe->engine, id, &data);
  {
    guint32 want = kind == SNAP_BRUSH ? GLIMS_RESOURCE_BRUSH :
                   kind == SNAP_PATTERN ? GLIMS_RESOURCE_PATTERN :
                   GLIMS_RESOURCE_GRADIENT;
    if (status != GLIMS_STATUS_OK || ! data || resource_kind_of_data (data) != want)
      {
        HARD_FAIL ("resource snapshot id %llu is not the expected native kind",
                   (unsigned long long) id);
        return FALSE;
      }
  }

  snap->resource_kind = resource_kind_of_data (data);
  snap->name          = g_strdup (gimp_object_get_name (GIMP_OBJECT (data)));
  snap->dirty         = gimp_data_is_dirty (data);

  file = gimp_data_get_file (data);
  if (file)
    {
      snap->file_path = g_file_get_path (file);
      if (snap->file_path && ! read_file_bytes (snap->file_path,
                                                &snap->file_bytes,
                                                &snap->file_len))
        {
          snap->file_bytes = NULL;
          snap->file_len   = 0;
        }
    }

  if (! snap_thumb (probe, id, snap))
    {
      HARD_FAIL ("resource snapshot thumbnail failed for id %llu",
                 (unsigned long long) id);
      return FALSE;
    }

  if (kind == SNAP_BRUSH)
    {
      GimpBrushGenerated *brush;
      GimpBrush          *base;

      if (! GIMP_IS_BRUSH_GENERATED (data))
        {
          HARD_FAIL ("brush fixture id %llu is not GIMP_IS_BRUSH_GENERATED",
                     (unsigned long long) id);
          return FALSE;
        }
      brush = GIMP_BRUSH_GENERATED (data);
      base  = GIMP_BRUSH (data);
      snap->shape        = gimp_brush_generated_get_shape (brush);
      snap->radius       = gimp_brush_generated_get_radius (brush);
      snap->spikes       = gimp_brush_generated_get_spikes (brush);
      snap->hardness     = gimp_brush_generated_get_hardness (brush);
      snap->aspect_ratio = gimp_brush_generated_get_aspect_ratio (brush);
      snap->angle        = gimp_brush_generated_get_angle (brush);
      snap->spacing      = gimp_brush_get_spacing (base);
    }
  else if (kind == SNAP_GRADIENT)
    {
      GimpGradient       *gradient = GIMP_GRADIENT (data);
      GimpGradientSegment *seg     = gradient->segments;
      const Babl         *rgba     = babl_format ("R'G'B'A float");

      while (seg && snap->segment_count < MAX_SEGMENTS)
        {
          SegmentSnap *out = &snap->segments[snap->segment_count++];
          GeglColor   *lc  = gimp_gradient_segment_get_left_color (gradient, seg);
          GeglColor   *rc  = gimp_gradient_segment_get_right_color (gradient, seg);

          out->left             = gimp_gradient_segment_get_left_pos (gradient, seg);
          out->middle           = gimp_gradient_segment_get_middle_pos (gradient, seg);
          out->right            = gimp_gradient_segment_get_right_pos (gradient, seg);
          out->left_color_type  = gimp_gradient_segment_get_left_color_type (gradient, seg);
          out->right_color_type = gimp_gradient_segment_get_right_color_type (gradient, seg);
          out->type             = gimp_gradient_segment_get_blending_function (gradient, seg);
          out->color            = gimp_gradient_segment_get_coloring_type (gradient, seg);
          if (lc)
            gegl_color_get_pixel (lc, rgba, out->left_rgba);
          if (rc)
            gegl_color_get_pixel (rc, rgba, out->right_rgba);
          seg = seg->next;
        }
      if (seg)
        {
          HARD_FAIL ("gradient fixture has more than %d segments",
                     MAX_SEGMENTS);
          return FALSE;
        }
    }
  else if (kind == SNAP_PATTERN)
    {
      GimpPattern *pattern = GIMP_PATTERN (data);
      GimpTempBuf *mask    = gimp_pattern_get_mask (pattern);

      if (! mask)
        {
          HARD_FAIL ("pattern fixture id %llu has no mask", (unsigned long long) id);
          return FALSE;
        }
      snap->format      = gimp_temp_buf_get_format (mask);
      snap->mask_width  = gimp_temp_buf_get_width (mask);
      snap->mask_height = gimp_temp_buf_get_height (mask);
      snap->mask_len    = gimp_temp_buf_get_data_size (mask);
      snap->mask_pixels = g_memdup2 (gimp_temp_buf_get_data (mask), snap->mask_len);
    }

  return TRUE;
}

static gboolean
source_snap_take_data (Probe *probe, GimpData *data, SnapKind kind,
                       SourceSnap *snap)
{
  return source_snap_take_id (probe, gimp_data_get_id (data), kind, snap);
}

static gboolean
double_eq (double a, double b)
{
  return fabs (a - b) < 0.000001;
}

static gboolean
float_eq (float a, float b)
{
  return fabsf (a - b) < 0.0001f;
}

static gboolean
source_snap_equal (const SourceSnap *a, const SourceSnap *b)
{
  int i;

  if (a->kind != b->kind || a->id != b->id || a->resource_kind != b->resource_kind ||
      ! a->name || ! b->name || strcmp (a->name, b->name) != 0 ||
      a->dirty != b->dirty ||
      a->thumb_width != b->thumb_width || a->thumb_height != b->thumb_height ||
      a->thumb_bytes != b->thumb_bytes || a->thumb_hash != b->thumb_hash)
    return FALSE;
  if ((a->file_path == NULL) != (b->file_path == NULL) ||
      (a->file_path && strcmp (a->file_path, b->file_path) != 0) ||
      a->file_len != b->file_len ||
      (a->file_len && memcmp (a->file_bytes, b->file_bytes, a->file_len) != 0))
    return FALSE;

  if (a->kind == SNAP_BRUSH)
    return a->shape == b->shape && a->spikes == b->spikes && a->spacing == b->spacing &&
           float_eq (a->radius, b->radius) && float_eq (a->hardness, b->hardness) &&
           float_eq (a->aspect_ratio, b->aspect_ratio) && float_eq (a->angle, b->angle);

  if (a->kind == SNAP_GRADIENT)
    {
      if (a->segment_count != b->segment_count)
        return FALSE;
      for (i = 0; i < a->segment_count; i++)
        {
          const SegmentSnap *sa = &a->segments[i];
          const SegmentSnap *sb = &b->segments[i];
          int                c;

          if (! double_eq (sa->left, sb->left) ||
              ! double_eq (sa->middle, sb->middle) ||
              ! double_eq (sa->right, sb->right) ||
              sa->left_color_type != sb->left_color_type ||
              sa->right_color_type != sb->right_color_type ||
              sa->type != sb->type || sa->color != sb->color)
            return FALSE;
          for (c = 0; c < 4; c++)
            if (! float_eq (sa->left_rgba[c], sb->left_rgba[c]) ||
                ! float_eq (sa->right_rgba[c], sb->right_rgba[c]))
              return FALSE;
        }
      return TRUE;
    }

  if (a->kind == SNAP_PATTERN)
    return a->format == b->format && a->mask_width == b->mask_width &&
           a->mask_height == b->mask_height && a->mask_len == b->mask_len &&
           memcmp (a->mask_pixels, b->mask_pixels, a->mask_len) == 0;

  return FALSE;
}

static void
dir_snap_free (DirSnap *snap)
{
  int i;
  for (i = 0; i < snap->count; i++)
    g_free (snap->entries[i].bytes);
  snap->count = 0;
}

static void
dir_snapshot (const char *path, DirSnap *snap)
{
  DIR           *dir;
  struct dirent *ent;

  memset (snap, 0, sizeof *snap);
  dir = opendir (path);
  if (! dir)
    {
      snap->missing = errno == ENOENT;
      return;
    }

  while ((ent = readdir (dir)) != NULL && snap->count < MAX_DIR_ENTRIES)
    {
      char       child[1024];
      struct stat st;
      DirEntry  *e;

      if (! strcmp (ent->d_name, ".") || ! strcmp (ent->d_name, ".."))
        continue;
      e = &snap->entries[snap->count++];
      snprintf (e->name, sizeof e->name, "%s", ent->d_name);
      snprintf (child, sizeof child, "%s/%s", path, ent->d_name);
      e->is_dir = stat (child, &st) == 0 && S_ISDIR (st.st_mode);
      if (! e->is_dir && stat (child, &st) == 0 && S_ISREG (st.st_mode))
        read_file_bytes (child, &e->bytes, &e->len);
    }
  closedir (dir);
}

static DirEntry *
dir_find (DirSnap *snap, const char *name)
{
  int i;
  for (i = 0; i < snap->count; i++)
    if (! strcmp (snap->entries[i].name, name))
      return &snap->entries[i];
  return NULL;
}

static gboolean
dir_snap_equal (DirSnap *a, DirSnap *b)
{
  int i;
  if (a->missing != b->missing || a->count != b->count)
    return FALSE;
  for (i = 0; i < a->count; i++)
    {
      DirEntry *ea = &a->entries[i];
      DirEntry *eb = dir_find (b, ea->name);
      if (! eb || ea->is_dir != eb->is_dir || ea->len != eb->len ||
          (ea->len && memcmp (ea->bytes, eb->bytes, ea->len) != 0))
        return FALSE;
    }
  return TRUE;
}

static gboolean
dir_has_stage (DirSnap *snap)
{
  int i;
  for (i = 0; i < snap->count; i++)
    if (! strncmp (snap->entries[i].name, ".glims-stage-", 13))
      return TRUE;
  return FALSE;
}

static void
cat_snap_free (CatSnap *snap)
{
  g_free (snap->entries);
  snap->entries = NULL;
  snap->count   = 0;
}

static void
container_snapshot (GimpContainer *container, CatSnap *snap)
{
  gint i;

  memset (snap, 0, sizeof *snap);
  snap->count   = gimp_container_get_n_children (container);
  snap->entries = g_new0 (CatEntry, MAX (snap->count, 1));
  for (i = 0; i < snap->count && i < MAX_CAT_ENTRIES; i++)
    {
      GimpObject *child = gimp_container_get_child_by_index (container, i);
      GimpData   *data  = GIMP_IS_DATA (child) ? GIMP_DATA (child) : NULL;
      guint32     kind  = data ? resource_kind_of_data (data) : 0;

      snap->entries[i].id   = data ? gimp_data_get_id (data) : 0;
      snap->entries[i].kind = kind;
      snprintf (snap->entries[i].name, sizeof snap->entries[i].name, "%s",
                gimp_object_get_name (child));
    }
  if (snap->count > MAX_CAT_ENTRIES)
    snap->count = MAX_CAT_ENTRIES;
}

static gboolean
cat_entry_equal (const CatEntry *a, const CatEntry *b)
{
  return a->id == b->id && a->kind == b->kind && strcmp (a->name, b->name) == 0;
}

static gboolean
cat_snap_equal (CatSnap *a, CatSnap *b)
{
  gboolean *used;
  int       i, j, found;

  if (a->count != b->count)
    return FALSE;
  used = g_new0 (gboolean, MAX (b->count, 1));
  for (i = 0; i < a->count; i++)
    {
      found = FALSE;
      for (j = 0; j < b->count; j++)
        if (! used[j] && cat_entry_equal (&a->entries[i], &b->entries[j]))
          {
            used[j] = TRUE;
            found   = TRUE;
            break;
          }
      if (! found)
        {
          g_free (used);
          return FALSE;
        }
    }
  g_free (used);
  return TRUE;
}

static void
expect_refusal (Probe *probe, const char *label, GlimsResourceID id,
                SnapKind snap_kind, SourceSnap *before,
                GimpContainer *container, const char *bad_name,
                GlimsStatus expected)
{
  char      dir_path[1024];
  const char *rel = resource_dir_name (
    snap_kind == SNAP_BRUSH ? GLIMS_RESOURCE_BRUSH :
    snap_kind == SNAP_PATTERN ? GLIMS_RESOURCE_PATTERN : GLIMS_RESOURCE_GRADIENT);
  DirSnap   *dir_before = g_new0 (DirSnap, 1);
  DirSnap   *dir_after = g_new0 (DirSnap, 1);
  CatSnap    cat_before, cat_after;
  SourceSnap after;
  GlimsResourceID out_id = UINT64_C (0xDEADBEEFDEADBEEF);
  char       *err = NULL;
  GlimsStatus status;

  snprintf (dir_path, sizeof dir_path, "%s/user/%s", probe->work, rel);
  dir_snapshot (dir_path, dir_before);
  container_snapshot (container, &cat_before);

  status = api->resource_duplicate (probe->engine, id, bad_name, &out_id, &err);

  check (probe, status == expected,
         "%s: %s returns status %d (got %d)", label, bad_name, expected, status);
  check (probe, out_id == 0, "%s: %s leaves out id 0", label, bad_name);
  check (probe, err != NULL && err[0] != '\0',
         "%s: %s returns an actionable error", label, bad_name);
  if (err)
    api->free_string (err);

  dir_snapshot (dir_path, dir_after);
  container_snapshot (container, &cat_after);
  if (! source_snap_take_id (probe, id, snap_kind, &after))
    {
      cat_snap_free (&cat_before);
      cat_snap_free (&cat_after);
      dir_snap_free (dir_before);
      dir_snap_free (dir_after);
      g_free (dir_before);
      g_free (dir_after);
      return;
    }

  check (probe, source_snap_equal (before, &after),
         "%s: %s leaves source name/id/kind/dirty/file/thumbnail/payload unchanged",
         label, bad_name);
  check (probe, dir_snap_equal (dir_before, dir_after) && ! dir_has_stage (dir_after),
         "%s: %s leaves %s and has no .glims-stage-* remnant", label, bad_name, rel);
  check (probe, cat_snap_equal (&cat_before, &cat_after),
         "%s: %s leaves factory rows/ids unchanged", label, bad_name);

  snap_free_common (&after);
  cat_snap_free (&cat_before);
  cat_snap_free (&cat_after);
  dir_snap_free (dir_before);
  dir_snap_free (dir_after);
  g_free (dir_before);
  g_free (dir_after);
}

static gboolean
dup_check_common (Probe *probe, const char *label, GlimsResourceID source_id,
                  const char *name, guint32 kind, GlimsResourceID *out_id)
{
  GlimsResourceID new_id = 0;
  char            *err = NULL;
  GlimsStatus      status;
  GimpData        *data = NULL;
  GFile           *file;
  const char      *path;

  status = api->resource_duplicate (probe->engine, source_id, name, &new_id, &err);
  if (err)
    api->free_string (err);
  check (probe, status == GLIMS_STATUS_OK,
         "%s: canonical duplicate returns OK (got %d)", label, status);
  check (probe, new_id != 0 && new_id != source_id,
         "%s: duplicate has a distinct positive id", label);
  if (status != GLIMS_STATUS_OK || new_id == 0)
    return FALSE;

  if (glims_lookup_resource_data (probe->engine, new_id, &data) != GLIMS_STATUS_OK || ! data)
    {
      check (probe, FALSE, "%s: duplicate id resolves", label);
      return FALSE;
    }
  check (probe, resource_kind_of_data (data) == kind,
         "%s: duplicate keeps resource kind %u", label, kind);
  check (probe, strcmp (gimp_object_get_name (GIMP_OBJECT (data)), name) == 0,
         "%s: duplicate name is exactly %s", label, name);

  file = gimp_data_get_file (data);
  path = file ? g_file_get_path (file) : NULL;
  check (probe, path != NULL, "%s: duplicate has a backing file", label);
  if (path)
    printf ("info  %s: backing file %s\n", label, path);

  *out_id = new_id;
  return TRUE;
}

static GList *
load_first (Probe *probe, const char *label, GFile *file,
            GList *(*loader) (GimpContext *, GFile *, GInputStream *, GError **))
{
  GError       *error = NULL;
  GInputStream *input;
  GList        *loaded;

  input = G_INPUT_STREAM (g_file_read (file, NULL, &error));
  if (! input)
    {
      check (probe, FALSE, "%s: private native loader input opens (%s)",
             label, error ? error->message : "unknown");
      if (error)
        g_error_free (error);
      return NULL;
    }
  loaded = loader (probe->context, file, input, &error);
  g_object_unref (input);
  if (! loaded || ! loaded->data)
    {
      check (probe, FALSE, "%s: private native loader returns one object (%s)",
             label, error ? error->message : "empty list");
      if (error)
        g_error_free (error);
      return NULL;
    }
  if (error)
    g_error_free (error);
  return loaded;
}

static void
free_loaded_list (GList *list)
{
  GList *l;
  for (l = list; l; l = l->next)
    if (l->data)
      g_object_unref (l->data);
  g_list_free (list);
}

static gboolean
brush_params_equal (GimpBrushGenerated *a, GimpBrushGenerated *b)
{
  GimpTempBuf *mask_a = gimp_brush_get_mask (GIMP_BRUSH (a));
  GimpTempBuf *mask_b = gimp_brush_get_mask (GIMP_BRUSH (b));

  return mask_a && mask_b &&
         gimp_temp_buf_get_width (mask_a) == gimp_temp_buf_get_width (mask_b) &&
         gimp_temp_buf_get_height (mask_a) == gimp_temp_buf_get_height (mask_b) &&
         gimp_temp_buf_get_data_size (mask_a) == gimp_temp_buf_get_data_size (mask_b) &&
         memcmp (gimp_temp_buf_get_data (mask_a), gimp_temp_buf_get_data (mask_b),
                 gimp_temp_buf_get_data_size (mask_a)) == 0 &&
         gimp_brush_generated_get_shape (a) == gimp_brush_generated_get_shape (b) &&
         float_eq (gimp_brush_generated_get_radius (a),
                   gimp_brush_generated_get_radius (b)) &&
         gimp_brush_generated_get_spikes (a) == gimp_brush_generated_get_spikes (b) &&
         float_eq (gimp_brush_generated_get_hardness (a),
                   gimp_brush_generated_get_hardness (b)) &&
         float_eq (gimp_brush_generated_get_aspect_ratio (a),
                   gimp_brush_generated_get_aspect_ratio (b)) &&
         float_eq (gimp_brush_generated_get_angle (a),
                   gimp_brush_generated_get_angle (b)) &&
         gimp_brush_get_spacing (GIMP_BRUSH (a)) == gimp_brush_get_spacing (GIMP_BRUSH (b));
}

static void
test_generated_brush (Probe *probe)
{
  GimpDataFactory    *factory  = probe->gimp->brush_factory;
  GimpContainer      *container = gimp_data_factory_get_container (factory);
  const char         *source_name = "glims-persist-src-generated-brush";
  const char         *copy_name   = "glims-persist-copy-generated-brush";
  GimpData           *created    = NULL;
  GimpObject         *found      = NULL;
  GimpData           *source     = NULL;
  GlimsResourceID     source_id  = 0;
  GlimsResourceID     copy_id    = 0;
  SourceSnap          before, after;
  GFile              *file;
  const char         *path;
  GList              *loaded;
  static const char  *bad_names[] = {
    " glims-persist-copy-generated-brush",
    "glims-persist-copy-generated-brush ",
    "   ",
    "\tglims-persist-copy-generated-brush",
    "glims-persist-copy-generated-brush\r"
  };
  gsize i;

  created = gimp_brush_generated_new (source_name,
                                      GIMP_BRUSH_GENERATED_DIAMOND,
                                      17.5f, 7, 0.625f, 1.75f, 30.0f);
  FIXTURE (created != NULL, "generated brush fixture constructs");
  FIXTURE (GIMP_IS_BRUSH_GENERATED (created),
           "generated brush fixture is GIMP_IS_BRUSH_GENERATED");
  gimp_brush_set_spacing (GIMP_BRUSH (created), 19);

  /* gimpdata.c:gimp_data_make_internal gives unsaved fixtures a stable
   * collection identity and makes the source read-only before publication. */
  gimp_data_make_internal (created,
                           "ch.lkmc.Glims.tests.resource-duplicate.generated-brush");
  FIXTURE (gimp_data_is_internal (created) && ! gimp_data_is_writable (created) &&
           gimp_data_is_duplicatable (created),
           "generated brush source is internal, read-only and duplicatable");

  FIXTURE (gimp_container_add (container, GIMP_OBJECT (created)),
           "generated brush fixture enters brush factory");
  g_object_unref (created);

  found = gimp_container_get_child_by_name (container, source_name);
  FIXTURE (found != NULL && GIMP_IS_DATA (found),
           "generated brush fixture reacquires by canonical name");
  source = GIMP_DATA (found);
  source_id = gimp_data_get_id (source);
  FIXTURE (source_id > 0, "generated brush fixture has positive native id");

  FIXTURE (source_snap_take_data (probe, source, SNAP_BRUSH, &before),
           "generated brush source snapshot");

  if (! dup_check_common (probe, "generated brush", source_id, copy_name,
                          GLIMS_RESOURCE_BRUSH, &copy_id))
    {
      snap_free_common (&before);
      return;
    }

  if (glims_lookup_resource_data (probe->engine, copy_id, &source) == GLIMS_STATUS_OK &&
      GIMP_IS_BRUSH_GENERATED (source))
    {
      file = gimp_data_get_file (source);
      path = file ? g_file_get_path (file) : NULL;
      check (probe, path != NULL && g_str_has_suffix (path, ".vbr"),
             "generated brush duplicate persists a .vbr file");
      if (path)
        {
          GFile *gfile = g_file_new_for_path (path);
          loaded = load_first (probe, "generated brush .vbr",
                               gfile, gimp_brush_generated_load);
          g_object_unref (gfile);
          if (loaded)
            {
              GimpData *loaded_data = GIMP_DATA (loaded->data);
              GimpObject *original = gimp_container_get_child_by_name (container, source_name);
              check (probe, original && GIMP_IS_BRUSH_GENERATED (original) &&
                     GIMP_IS_BRUSH_GENERATED (loaded_data) &&
                     strcmp (gimp_object_get_name (GIMP_OBJECT (loaded_data)), copy_name) == 0 &&
                     brush_params_equal (GIMP_BRUSH_GENERATED (original),
                                         GIMP_BRUSH_GENERATED (loaded_data)),
                     "generated brush .vbr reload preserves name, source parameters and mask pixels");
              free_loaded_list (loaded);
            }
        }
    }
  else
    check (probe, FALSE, "generated brush duplicate resolves as generated brush");

  found = gimp_container_get_child_by_name (container, source_name);
  FIXTURE (found != NULL, "generated brush source still present after success");
  FIXTURE (source_snap_take_data (probe, GIMP_DATA (found), SNAP_BRUSH, &after),
           "generated brush post-success source snapshot");
  check (probe, source_snap_equal (&before, &after),
         "generated brush canonical success leaves source unchanged");
  snap_free_common (&after);
  snap_free_common (&before);

  source = GIMP_DATA (found);
  source_id = gimp_data_get_id (source);
  FIXTURE (source_snap_take_data (probe, source, SNAP_BRUSH, &before),
           "generated brush refusal baseline snapshot");

  for (i = 0; i < G_N_ELEMENTS (bad_names); i++)
    expect_refusal (probe, "generated brush whitespace", source_id, SNAP_BRUSH,
                    &before, container, bad_names[i], GLIMS_STATUS_INVALID_ARGUMENT);
  snap_free_common (&before);
}

static void
test_gradient (Probe *probe)
{
  GimpDataFactory    *factory   = probe->gimp->gradient_factory;
  GimpContainer      *container = gimp_data_factory_get_container (factory);
  const char         *source_name = "glims-persist-src-gradient";
  const char         *copy_name   = "glims-persist-copy-gradient";
  GimpData           *created    = NULL;
  GimpData           *source     = NULL;
  GlimsResourceID     source_id  = 0;
  GlimsResourceID     copy_id    = 0;
  SourceSnap          before, after;
  GimpGradientSegment *seg;
  GFile              *file;
  const char         *path;
  GList              *loaded;
  static const char  *bad_names[] = {
    " glims-persist-copy-gradient",
    "glims-persist-copy-gradient ",
    "   ",
    "\tglims-persist-copy-gradient",
    "glims-persist-copy-gradient\n"
  };
  gsize i;

  created = gimp_gradient_new (probe->context, source_name);
  FIXTURE (created != NULL, "gradient fixture constructs");
  FIXTURE (GIMP_IS_GRADIENT (created), "gradient fixture is GIMP_IS_GRADIENT");

  seg = GIMP_GRADIENT (created)->segments;
  FIXTURE (seg != NULL, "gradient fixture has a native segment");
  gimp_gradient_segment_set_right_pos (GIMP_GRADIENT (created), seg, 0.75);
  gimp_gradient_segment_set_middle_pos (GIMP_GRADIENT (created), seg, 0.35);
  gimp_gradient_segment_range_set_blending_function (GIMP_GRADIENT (created), seg, seg,
                                                     GIMP_GRADIENT_SEGMENT_CURVED);
  gimp_gradient_segment_range_set_coloring_type (GIMP_GRADIENT (created), seg, seg,
                                                 GIMP_GRADIENT_SEGMENT_HSV_CW);

  {
    GeglColor *left = gegl_color_new ("#336699");
    FIXTURE (left != NULL, "gradient fixture color constructs");
    gimp_gradient_segment_set_left_color (GIMP_GRADIENT (created), seg, left);
    g_object_unref (left);
  }

  gimp_data_make_internal (created,
                           "ch.lkmc.Glims.tests.resource-duplicate.gradient");
  FIXTURE (gimp_data_is_internal (created) && ! gimp_data_is_writable (created) &&
           gimp_data_is_duplicatable (created),
           "gradient source is internal, read-only and duplicatable");

  FIXTURE (gimp_container_add (container, GIMP_OBJECT (created)),
           "gradient fixture enters gradient factory");
  g_object_unref (created);

  source = GIMP_DATA (gimp_container_get_child_by_name (container, source_name));
  FIXTURE (source != NULL, "gradient fixture reacquires by canonical name");
  source_id = gimp_data_get_id (source);
  FIXTURE (source_id > 0, "gradient fixture has positive native id");
  FIXTURE (source_snap_take_data (probe, source, SNAP_GRADIENT, &before),
           "gradient source snapshot");

  if (! dup_check_common (probe, "gradient", source_id, copy_name,
                          GLIMS_RESOURCE_GRADIENT, &copy_id))
    {
      snap_free_common (&before);
      return;
    }

  if (glims_lookup_resource_data (probe->engine, copy_id, &source) == GLIMS_STATUS_OK &&
      GIMP_IS_GRADIENT (source))
    {
      file = gimp_data_get_file (source);
      path = file ? g_file_get_path (file) : NULL;
      check (probe, path != NULL && g_str_has_suffix (path, ".ggr"),
             "gradient duplicate persists a .ggr file");
      if (path)
        {
          GFile *gfile = g_file_new_for_path (path);
          loaded = load_first (probe, "gradient .ggr", gfile, gimp_gradient_load);
          g_object_unref (gfile);
          if (loaded)
            {
              GimpData           *loaded_data = GIMP_DATA (loaded->data);
              GimpGradient       *loaded_grad = GIMP_GRADIENT (loaded_data);
              SourceSnap          loaded_snap;

              check (probe, GIMP_IS_GRADIENT (loaded_data) &&
                     strcmp (gimp_object_get_name (GIMP_OBJECT (loaded_data)), copy_name) == 0,
                     "gradient .ggr reload preserves requested name");
              /* Compare the private loader result to the independently
               * snapshotted source segment list by wrapping it in the same
               * snapshot representation. */
              memset (&loaded_snap, 0, sizeof loaded_snap);
              loaded_snap.kind          = SNAP_GRADIENT;
              loaded_snap.resource_kind = GLIMS_RESOURCE_GRADIENT;
              loaded_snap.name          = g_strdup (gimp_object_get_name (GIMP_OBJECT (loaded_data)));
              {
                GimpGradientSegment *lseg = loaded_grad->segments;
                const Babl         *rgba  = babl_format ("R'G'B'A float");
                while (lseg && loaded_snap.segment_count < MAX_SEGMENTS)
                  {
                    SegmentSnap *out = &loaded_snap.segments[loaded_snap.segment_count++];
                    GeglColor   *lc  = gimp_gradient_segment_get_left_color (loaded_grad, lseg);
                    GeglColor   *rc  = gimp_gradient_segment_get_right_color (loaded_grad, lseg);
                    out->left             = gimp_gradient_segment_get_left_pos (loaded_grad, lseg);
                    out->middle           = gimp_gradient_segment_get_middle_pos (loaded_grad, lseg);
                    out->right            = gimp_gradient_segment_get_right_pos (loaded_grad, lseg);
                    out->left_color_type  = gimp_gradient_segment_get_left_color_type (loaded_grad, lseg);
                    out->right_color_type = gimp_gradient_segment_get_right_color_type (loaded_grad, lseg);
                    out->type             = gimp_gradient_segment_get_blending_function (loaded_grad, lseg);
                    out->color            = gimp_gradient_segment_get_coloring_type (loaded_grad, lseg);
                    if (lc) gegl_color_get_pixel (lc, rgba, out->left_rgba);
                    if (rc) gegl_color_get_pixel (rc, rgba, out->right_rgba);
                    lseg = lseg->next;
                  }
              }
              /* Compare segment payload against the source snapshot's segment
               * payload, ignoring facade-only base fields that do not apply to
               * the private loader object. */
              {
                gboolean same = loaded_snap.segment_count == before.segment_count;
                int      i;
                for (i = 0; same && i < loaded_snap.segment_count; i++)
                  {
                    const SegmentSnap *a = &before.segments[i];
                    const SegmentSnap *b = &loaded_snap.segments[i];
                    int                c;
                    same = double_eq (a->left, b->left) &&
                           double_eq (a->middle, b->middle) &&
                           double_eq (a->right, b->right) &&
                           a->left_color_type == b->left_color_type &&
                           a->right_color_type == b->right_color_type &&
                           a->type == b->type && a->color == b->color;
                    for (c = 0; same && c < 4; c++)
                      same = float_eq (a->left_rgba[c], b->left_rgba[c]) &&
                             float_eq (a->right_rgba[c], b->right_rgba[c]);
                  }
                check (probe, same,
                       "gradient .ggr reload preserves segment positions, types and colors");
              }
              g_free (loaded_snap.name);
              free_loaded_list (loaded);
            }
        }
    }
  else
    check (probe, FALSE, "gradient duplicate resolves as gradient");

  source = GIMP_DATA (gimp_container_get_child_by_name (container, source_name));
  FIXTURE (source != NULL, "gradient source still present after success");
  FIXTURE (source_snap_take_data (probe, source, SNAP_GRADIENT, &after),
           "gradient post-success source snapshot");
  check (probe, source_snap_equal (&before, &after),
         "gradient canonical success leaves source unchanged");
  snap_free_common (&after);
  snap_free_common (&before);

  source = GIMP_DATA (gimp_container_get_child_by_name (container, source_name));
  source_id = gimp_data_get_id (source);
  FIXTURE (source_snap_take_data (probe, source, SNAP_GRADIENT, &before),
           "gradient refusal baseline snapshot");
  for (i = 0; i < G_N_ELEMENTS (bad_names); i++)
    expect_refusal (probe, "gradient whitespace", source_id, SNAP_GRADIENT,
                    &before, container, bad_names[i], GLIMS_STATUS_INVALID_ARGUMENT);
  snap_free_common (&before);
}

typedef struct
{
  const Babl *format;
  int         width;
  int         height;
  int         bpp;
  guchar     *pixels;
  gsize       len;
  const char *label;
} PatFixture;

static void
fill_pattern_pixels (const Babl *format, guchar *pixels, gsize len)
{
  const char *encoding = babl_format_get_encoding (format);
  gsize       i;

  if (encoding && strstr (encoding, "float"))
    {
      static const float values[] = { 0.25f, 0.5f, 0.75f, 1.0f };
      gsize n = len / sizeof (float);
      for (i = 0; i < n; i++)
        memcpy (pixels + i * sizeof (float), &values[i % G_N_ELEMENTS (values)],
                sizeof (float));
      return;
    }
  if (encoding && strstr (encoding, "u16"))
    {
      static const guint16 values[] = { 0x1111, 0x2222, 0x3333, 0x7fff };
      gsize n = len / sizeof (guint16);
      for (i = 0; i < n; i++)
        {
          guint16 v = values[i % G_N_ELEMENTS (values)];
          memcpy (pixels + i * sizeof (guint16), &v, sizeof v);
        }
      return;
    }
  for (i = 0; i < len; i++)
    pixels[i] = (guchar) ((i * 37 + 11) & 0xff);
}

static gboolean
pat_fixture_make (const Babl *format, int width, int height,
                  const char *label, PatFixture *out)
{
  int bpp = babl_format_get_bytes_per_pixel (format);

  memset (out, 0, sizeof *out);
  out->format = format;
  out->width  = width;
  out->height = height;
  out->bpp    = bpp;
  out->len    = (gsize) width * (gsize) height * (gsize) bpp;
  out->label  = label;
  out->pixels = g_new (guchar, out->len);
  fill_pattern_pixels (format, out->pixels, out->len);
  return TRUE;
}

static gboolean
pat_fixture_clipboard (Probe *probe, PatFixture *fixture, GlimsResourceID *source_id,
                       SourceSnap *snap)
{
  GeglBuffer  *gegl_buf;
  GimpBuffer  *gimp_buf;
  GimpObject  *child;
  gint         i, n;
  GimpPattern *pattern = NULL;
  GimpTempBuf *mask;

  gegl_buf = gegl_buffer_new (GEGL_RECTANGLE (0, 0, fixture->width, fixture->height),
                              fixture->format);
  if (! gegl_buf)
    {
      HARD_FAIL ("%s: GeglBuffer construction failed", fixture->label);
      return FALSE;
    }
  gegl_buffer_set (gegl_buf, GEGL_RECTANGLE (0, 0, fixture->width, fixture->height),
                   0, fixture->format, fixture->pixels, GEGL_AUTO_ROWSTRIDE);

  gimp_buf = gimp_buffer_new (gegl_buf, fixture->label, 0, 0, TRUE);
  g_object_unref (gegl_buf);
  if (! gimp_buf)
    {
      HARD_FAIL ("%s: gimp_buffer_new failed", fixture->label);
      return FALSE;
    }

  gimp_set_clipboard_buffer (probe->gimp, gimp_buf);
  g_object_unref (gimp_buf);

  n = gimp_container_get_n_children (container_for_kind (probe->gimp, GLIMS_RESOURCE_PATTERN));
  for (i = 0; i < n; i++)
    {
      child = gimp_container_get_child_by_index (
        container_for_kind (probe->gimp, GLIMS_RESOURCE_PATTERN), i);
      if (GIMP_IS_PATTERN_CLIPBOARD (child))
        {
          pattern = GIMP_PATTERN (child);
          break;
        }
    }
  if (! pattern)
    {
      HARD_FAIL ("%s: clipboard pattern factory object missing", fixture->label);
      return FALSE;
    }

  mask = gimp_pattern_get_mask (pattern);
  if (! mask || gimp_temp_buf_get_format (mask) != fixture->format ||
      gimp_temp_buf_get_width (mask) != fixture->width ||
      gimp_temp_buf_get_height (mask) != fixture->height ||
      gimp_temp_buf_get_data_size (mask) != fixture->len ||
      memcmp (gimp_temp_buf_get_data (mask), fixture->pixels, fixture->len) != 0)
    {
      HARD_FAIL ("%s: clipboard pattern mask does not preserve exact Babl format/pixels",
                 fixture->label);
      return FALSE;
    }

  *source_id = gimp_data_get_id (GIMP_DATA (pattern));
  if (*source_id == 0)
    {
      HARD_FAIL ("%s: clipboard pattern has no positive id", fixture->label);
      return FALSE;
    }
  return source_snap_take_id (probe, *source_id, SNAP_PATTERN, snap);
}

static guint32
pat_be32 (const gchar *bytes, gsize offset)
{
  guint32 v;
  memcpy (&v, bytes + offset, sizeof v);
  return GUINT32_FROM_BE (v);
}

static gboolean
pat_file_check (Probe *probe, const char *label, const char *path,
                const char *name, int width, int height, int bpp,
                const guchar *expected, gsize expected_len)
{
  gchar *bytes = NULL;
  gsize  len = 0;
  guint32 header_size, version, w, h, bytes_per_pixel, magic;
  gsize payload_offset, name_len;

  if (! read_file_bytes (path, &bytes, &len) || len < 24)
    {
      check (probe, FALSE, "%s: .pat file reads (%s)", label,
             bytes ? "too small" : "missing");
      g_free (bytes);
      return FALSE;
    }
  header_size     = pat_be32 (bytes, 0);
  version         = pat_be32 (bytes, 4);
  w               = pat_be32 (bytes, 8);
  h               = pat_be32 (bytes, 12);
  bytes_per_pixel = pat_be32 (bytes, 16);
  magic           = pat_be32 (bytes, 20);

  check (probe, magic == GIMP_PATTERN_MAGIC && version == 1,
         "%s: .pat header magic/version", label);
  check (probe, w == (guint32) width && h == (guint32) height &&
         bytes_per_pixel == (guint32) bpp,
         "%s: .pat header dimensions and bytes/pixel", label);
  name_len = header_size >= 24 ? header_size - 24 : 0;
  check (probe, name_len == strlen (name) + 1 &&
         memcmp (bytes + 24, name, name_len) == 0,
         "%s: .pat header stores exact name", label);
  payload_offset = header_size;
  check (probe, len == payload_offset + expected_len &&
         memcmp (bytes + payload_offset, expected, expected_len) == 0,
         "%s: .pat payload bytes equal source mask bytes", label);
  g_free (bytes);
  return TRUE;
}

static void
test_pattern (Probe *probe)
{
  GimpContainer *container = container_for_kind (probe->gimp, GLIMS_RESOURCE_PATTERN);
  GimpObject    *previous  = gimp_get_clipboard_object (probe->gimp);
  PatFixture     fixtures[16];
  int            nfixtures = 0;
  int            i;
  const Babl    *srgb;

  srgb = babl_space ("sRGB");
  FIXTURE (srgb != NULL, "Babl sRGB space exists");

#define ADD_PAT(name, w, h, fmt)                                            \
  do {                                                                      \
    const Babl *f_ = (fmt);                                                 \
    FIXTURE (f_ != NULL, "%s Babl format resolves", name);                  \
    pat_fixture_make (f_, w, h, name, &fixtures[nfixtures]);               \
    fixtures[nfixtures].label = name;                                       \
    nfixtures++;                                                            \
  } while (0)

  ADD_PAT ("Y' u8",              3, 2, babl_format ("Y' u8"));
  ADD_PAT ("Y'A u8",             2, 2, babl_format ("Y'A u8"));
  ADD_PAT ("R'G'B' u8",          3, 2, babl_format ("R'G'B' u8"));
  ADD_PAT ("R'G'B'A u8",         2, 2, babl_format ("R'G'B'A u8"));
  ADD_PAT ("R'G'B'A float",      2, 2, babl_format ("R'G'B'A float"));
  ADD_PAT ("R'G'B'A u16",        2, 2, babl_format ("R'G'B'A u16"));
  ADD_PAT ("RGB u8",             3, 2, babl_format ("RGB u8"));
  ADD_PAT ("RGBA u8",            2, 2, babl_format ("RGBA u8"));
  ADD_PAT ("R'aG'aB'aA u8",      2, 2, babl_format ("R'aG'aB'aA u8"));
  ADD_PAT ("ProPhoto R'G'B'A u8", 2, 2,
          babl_format_with_space ("R'G'B'A u8", babl_space ("ProPhoto")));
#undef ADD_PAT

  /* Verify the fixture matrix itself, not just its BPP. */
  /* The RGB canonical encodings must be the default sRGB space, not merely
   * any same-BPP format. Gray Y/Y'A formats have no RGB primaries to confuse. */
  for (i = 2; i < 4; i++)
    {
      const Babl *f = fixtures[i].format;
      check (probe, babl_format_get_space (f) == srgb,
             "canonical PAT format %s uses default sRGB space",
             babl_format_get_encoding (f));
    }
  check (probe, fixtures[4].format && babl_format_get_bytes_per_pixel (fixtures[4].format) == 16 &&
         strcmp (babl_format_get_encoding (fixtures[4].format), "R'G'B'A float") == 0,
         "high-precision fixture is R'G'B'A float");
  check (probe, fixtures[5].format && babl_format_get_bytes_per_pixel (fixtures[5].format) == 8 &&
         strcmp (babl_format_get_encoding (fixtures[5].format), "R'G'B'A u16") == 0,
         "high-precision fixture is R'G'B'A u16");
  check (probe, fixtures[6].format && babl_format_get_bytes_per_pixel (fixtures[6].format) == 3 &&
         strcmp (babl_format_get_encoding (fixtures[6].format), "RGB u8") == 0,
         "linear fixture is RGB u8");
  check (probe, fixtures[7].format && babl_format_get_bytes_per_pixel (fixtures[7].format) == 4 &&
         strcmp (babl_format_get_encoding (fixtures[7].format), "RGBA u8") == 0,
         "linear fixture is RGBA u8");
  check (probe, fixtures[8].format && babl_format_get_bytes_per_pixel (fixtures[8].format) == 4 &&
         strcmp (babl_format_get_encoding (fixtures[8].format), "R'aG'aB'aA u8") == 0,
         "premultiplied fixture is R'aG'aB'aA u8");
  check (probe, fixtures[9].format && babl_format_get_bytes_per_pixel (fixtures[9].format) == 4 &&
         babl_format_get_space (fixtures[9].format) == babl_space ("ProPhoto") &&
         babl_format_get_space (fixtures[9].format) != srgb &&
         strcmp (babl_format_get_encoding (fixtures[9].format), "R'G'B'A u8") == 0,
         "custom-space fixture is ProPhoto R'G'B'A u8");

  if (previous)
    g_object_ref (previous);

  for (i = 0; i < nfixtures; i++)
    {
      PatFixture   *fixture = &fixtures[i];
      GlimsResourceID source_id = 0;
      GlimsResourceID copy_id   = 0;
      SourceSnap     snap;
      char           copy_name[256];

      if (! pat_fixture_clipboard (probe, fixture, &source_id, &snap))
        break;

      if (i < 4)
        {
          GimpData *source_data = NULL;
          if (glims_lookup_resource_data (probe->engine, source_id, &source_data) == GLIMS_STATUS_OK &&
              source_data)
            {
              snprintf (copy_name, sizeof copy_name, "glims-persist-pat-%d", i);
              if (! dup_check_common (probe, fixture->label, source_id, copy_name,
                                      GLIMS_RESOURCE_PATTERN, &copy_id))
                {
                  snap_free_common (&snap);
                  break;
                }
              if (glims_lookup_resource_data (probe->engine, copy_id, &source_data) == GLIMS_STATUS_OK &&
                  source_data && GIMP_IS_PATTERN (source_data))
                {
                  GimpPattern *copy_pattern = GIMP_PATTERN (source_data);
                  GimpTempBuf *copy_mask    = gimp_pattern_get_mask (copy_pattern);
                  GFile       *gfile;
                  const char  *path;
                  GList       *loaded;

                  check (probe, G_TYPE_FROM_INSTANCE (source_data) == GIMP_TYPE_PATTERN,
                         "%s: duplicate is a plain saved pattern", fixture->label);
                  check (probe, copy_mask && gimp_temp_buf_get_format (copy_mask) == fixture->format &&
                         gimp_temp_buf_get_width (copy_mask) == fixture->width &&
                         gimp_temp_buf_get_height (copy_mask) == fixture->height &&
                         gimp_temp_buf_get_data_size (copy_mask) == snap.mask_len &&
                         memcmp (gimp_temp_buf_get_data (copy_mask), snap.mask_pixels,
                                 snap.mask_len) == 0,
                         "%s: duplicate mask preserves exact canonical format/pixels",
                         fixture->label);
                  gfile = gimp_data_get_file (source_data);
                  path  = gfile ? g_file_get_path (gfile) : NULL;
                  check (probe, path && g_str_has_suffix (path, ".pat"),
                         "%s: duplicate persists .pat", fixture->label);
                  if (path)
                    {
                      gfile = g_file_new_for_path (path);
                      pat_file_check (probe, fixture->label, path, copy_name,
                                      fixture->width, fixture->height, fixture->bpp,
                                      snap.mask_pixels, snap.mask_len);
                      loaded = load_first (probe, fixture->label, gfile,
                                           gimp_pattern_load);
                      if (loaded)
                        {
                          GimpData    *ld   = GIMP_DATA (loaded->data);
                          GimpPattern *lpat = GIMP_PATTERN (ld);
                          GimpTempBuf *lmask = gimp_pattern_get_mask (lpat);
                          check (probe, GIMP_IS_PATTERN (ld) &&
                                 strcmp (gimp_object_get_name (GIMP_OBJECT (ld)), copy_name) == 0 &&
                                 lmask && gimp_temp_buf_get_format (lmask) == fixture->format &&
                                 gimp_temp_buf_get_width (lmask) == fixture->width &&
                                 gimp_temp_buf_get_height (lmask) == fixture->height &&
                                 gimp_temp_buf_get_data_size (lmask) == snap.mask_len &&
                                 memcmp (gimp_temp_buf_get_data (lmask), snap.mask_pixels,
                                         snap.mask_len) == 0,
                                 "%s: .pat native reload preserves name/format/pixels",
                                 fixture->label);
                          free_loaded_list (loaded);
                        }
                      g_object_unref (gfile);
                    }
                }
              else
                check (probe, FALSE, "%s: duplicate resolves as pattern", fixture->label);

              {
                SourceSnap after;
                if (source_snap_take_id (probe, source_id, SNAP_PATTERN, &after))
                  {
                    check (probe, source_snap_equal (&snap, &after),
                           "%s: canonical success leaves clipboard source unchanged",
                           fixture->label);
                    snap_free_common (&after);
                  }
              }
            }
          else
            check (probe, FALSE, "%s: clipboard source resolves", fixture->label);
        }
      else
        {
          char refusal_name[256];
          snprintf (refusal_name, sizeof refusal_name, "glims-persist-pat-%d-copy", i);
          expect_refusal (probe, fixture->label, source_id, SNAP_PATTERN, &snap,
                          container, refusal_name, GLIMS_STATUS_UNSUPPORTED);
        }

      snap_free_common (&snap);
    }

  /* Restore the clipboard object captured before fixture setup. */
  if (previous)
    {
      if (GIMP_IS_IMAGE (previous))
        gimp_set_clipboard_image (probe->gimp, GIMP_IMAGE (previous));
      else if (GIMP_IS_BUFFER (previous))
        gimp_set_clipboard_buffer (probe->gimp, GIMP_BUFFER (previous));
      else
        check (probe, FALSE, "previous clipboard object has unsupported type");
      g_object_unref (previous);
    }
  else
    gimp_set_clipboard_buffer (probe->gimp, NULL);

  for (i = 0; i < nfixtures; i++)
    g_free (fixtures[i].pixels);
}

static GlimsStatus
run_all (GlimsEngine *engine, gpointer user_data)
{
  Probe *probe = user_data;

  probe->engine  = engine;
  probe->api     = api;
  probe->gimp    = engine->gimp;
  probe->context = gimp_context_new (probe->gimp,
                                     "Glims resource duplicate persistence", NULL);
  if (! probe->context)
    {
      fixture_fail (probe, "private GimpContext constructs");
      return GLIMS_STATUS_FAILED;
    }

  test_generated_brush (probe);
  test_gradient (probe);
  test_pattern (probe);

  g_object_unref (probe->context);
  return probe->failures > 0 ? GLIMS_STATUS_FAILED : GLIMS_STATUS_OK;
}

int
main (int argc, char **argv)
{
  GlimsEngineConfig config;
  GlimsEngine     *engine = NULL;
  Probe            probe;
  char            *error = NULL;
  char             work[1024], home_dir[1024], user_dir[1024], cache_dir[1024];
  GlimsStatus      status;

  if (argc != 2)
    {
      fprintf (stderr, "usage: %s WORK_DIR\n", argv[0]);
      return 2;
    }

  snprintf (work, sizeof work, "%s", argv[1]);
  snprintf (home_dir, sizeof home_dir, "%s/home", work);
  snprintf (user_dir, sizeof user_dir, "%s/user", work);
  snprintf (cache_dir, sizeof cache_dir, "%s/cache", work);
  if ((mkdir (work, 0755) < 0 && errno != EEXIST) ||
      (mkdir (home_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (user_dir, 0755) < 0 && errno != EEXIST) ||
      (mkdir (cache_dir, 0755) < 0 && errno != EEXIST))
    {
      fprintf (stderr, "cannot create work dirs under %s: %s\n", work, strerror (errno));
      return 1;
    }

  memset (&probe, 0, sizeof probe);
  probe.work = work;
  memset (&config, 0, sizeof config);
  config.struct_size     = sizeof config;
  config.user_directory  = user_dir;
  config.cache_directory = cache_dir;
  config.on_event        = NULL;

  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (api == NULL || api->api_version != GLIMS_ENGINE_API_VERSION ||
      api->struct_size < sizeof (GlimsEngineAPI))
    {
      fprintf (stderr, "glims_engine_get_api(%u) did not serve the facade\n",
               (unsigned) GLIMS_ENGINE_API_VERSION);
      return 1;
    }

  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    {
      fprintf (stderr, "engine start failed: %s\n", error ? error : "unknown error");
      if (error)
        api->free_string (error);
      return 1;
    }
  if (error)
    {
      api->free_string (error);
      error = NULL;
    }

  printf ("resource-duplicate-persistence-tests: engine %s, work %s\n",
          api->engine_version (engine), work);

  status = glims_engine_call (engine, run_all, &probe);

  api->stop (engine);
  printf ("%s: %d failure%s\n",
          probe.failures > 0 || status != GLIMS_STATUS_OK ? "FAILED" : "PASSED",
          probe.failures, probe.failures == 1 ? "" : "s");
  return status == GLIMS_STATUS_OK && probe.failures == 0 ? 0 : 1;
}
