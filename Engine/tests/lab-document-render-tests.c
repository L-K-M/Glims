/* Native Lab render/lifecycle integration. This fixture deliberately shares the
 * separately reviewed Lab->linear-sRGB primitive, but independently decodes
 * literal source samples and derives expected mipmaps before babl encoding.
 * It is not independent validation of the primitive's CIE/colorimetry math.
 * Private writes are fixture setup/Undo probes, not a public Lab editing API. */
#include "plate-preview.h"
#include "lab-transform.h"
#include "core/gimpchannel.h"
#include "core/gimpdrawable.h"
#include "core/gimpimage.h"
#include "core/gimpimage-undo.h"
#include "core/gimpitem.h"
#include "core/gimpundostack.h"
#include <cairo.h>
#include "libgimpcolor/gimpcolor.h"
#include <float.h>
#include <lcms2.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define W 520
#define H 8
#define PIXELS (W * H)
#define RGBA_BYTES (PIXELS * 4)
#define EDIT_X 257
#define EDIT_Y 3
#define EDIT_PIXEL (EDIT_Y * W + EDIT_X)

static const GlimsEngineAPI *api;
static guint checks, failures;
#define CHECK(c, message) do { gboolean pass = !!(c); checks++; \
  printf("%s %s\n", pass ? "ok" : "FAIL", message); \
  if (!pass) failures++; fflush(stdout); } while (0)

typedef union {
  guint8 u8[PIXELS];
  guint16 u16[PIXELS];
  gfloat f32[PIXELS];
} RawPlane;
typedef struct {
  RawPlane plane[3];
  GlimsPlateMap map;
  guint64 revision;
  gint undo, redo;
  gboolean dirty;
} Snapshot;
typedef struct {
  GlimsImageID id;
  guint component, storage;
  gsize bytes;
  RawPlane pattern[3];
  GlimsLabTransform *oracle;
} Scene;

static const Babl *
raw_format (guint storage)
{
  if (storage == GLIMS_PLATE_STORAGE_U8) return babl_format ("Y u8");
  if (storage == GLIMS_PLATE_STORAGE_U16) return babl_format ("Y u16");
  return babl_format ("Y float");
}

static gboolean
storage_for (GlimsEngine *engine, Scene *s, GlimsOpenImage **open,
             GlimsPlateStorage *storage)
{
  *open = glims_lookup_image (engine, s->id);
  return *open && (*open)->component_document &&
         (*open)->component_mode == GLIMS_PLATE_MODE_LAB &&
         glims_plate_storage_read_open (*open, storage) &&
         storage->map.mode == GLIMS_PLATE_MODE_LAB &&
         storage->map.encoding == GLIMS_PLATE_ENCODING_LAB_D50 &&
         storage->map.count == 3 && storage->map.storage == s->storage &&
         !storage->profile && !storage->profile_size;
}

static gboolean
capture (GlimsEngine *engine, Scene *s, Snapshot *out)
{
  GlimsOpenImage *open;
  GlimsPlateStorage storage;
  memset (out, 0, sizeof *out);
  if (!storage_for (engine, s, &open, &storage)) return FALSE;
  out->map = storage.map;
  for (guint c = 0; c < 3; c++)
    {
      GimpDrawable *d = GIMP_DRAWABLE (storage.planes[c]);
      if (!storage.visible[c] || gimp_drawable_get_format (d) != raw_format (s->storage))
        return FALSE;
      gegl_buffer_get (gimp_drawable_get_buffer (d), GEGL_RECTANGLE (0, 0, W, H),
                       1, raw_format (s->storage), &out->plane[c],
                       GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
    }
  out->revision = open->history_revision;
  out->undo = gimp_undo_stack_get_depth (gimp_image_get_undo_stack (open->image));
  out->redo = gimp_undo_stack_get_depth (gimp_image_get_redo_stack (open->image));
  out->dirty = gimp_image_is_dirty (open->image);
  return TRUE;
}

static gboolean
same_raw (const Scene *s, const RawPlane a[3], const RawPlane b[3])
{
  for (guint c = 0; c < 3; c++)
    if (memcmp (&a[c], &b[c], s->bytes)) return FALSE;
  return TRUE;
}

static gboolean
same_snapshot (const Scene *s, const Snapshot *a, const Snapshot *b)
{
  return same_raw (s, a->plane, b->plane) &&
         !memcmp (&a->map, &b->map, sizeof a->map) &&
         a->revision == b->revision && a->undo == b->undo &&
         a->redo == b->redo && a->dirty == b->dirty;
}

/* Literal encoded samples, not glims_lab_encode/decode_row. Neighboring pixels
 * differ so averaging Lab before conversion cannot pass the mipmap oracle. */
static void
make_pattern (Scene *s)
{
  static const guint8 l8[] = { 0, 64, 128, 192, 255, 96, 160, 224 };
  static const guint8 ab8[] = { 0, 96, 127, 128, 129, 160, 192, 255 };
  static const guint16 l16[] = { 0, 16384, 32768, 49152, 65535, 24000, 40000, 56000 };
  static const guint16 ab16[] = { 0, 24672, 32639, 32896, 33153, 41120, 49344, 65535 };
  static const float lf[] = { -5, 0, 8, 35, 50, 80, 100, 110 };
  static const float abf[] = { -160, -128, -1, -0.0f, 0.0f, 1, 127, 160 };
  for (guint p = 0; p < PIXELS; p++)
    for (guint c = 0; c < 3; c++)
      {
        guint index = (p + (p / W) * 3 + c * 3) % 8;
        if (s->storage == GLIMS_PLATE_STORAGE_U8)
          s->pattern[c].u8[p] = c ? ab8[index] : l8[index];
        else if (s->storage == GLIMS_PLATE_STORAGE_U16)
          s->pattern[c].u16[p] = c ? ab16[index] : l16[index];
        else
          s->pattern[c].f32[p] = c ? abf[index] : lf[index];
      }
}

static gboolean
expected_linear (Scene *s, const RawPlane source[3], gfloat rgba[PIXELS * 4])
{
  gfloat lab[W * 3];
  for (guint y = 0; y < H; y++)
    {
      for (guint x = 0; x < W; x++)
        for (guint c = 0; c < 3; c++)
          {
            guint p = y * W + x;
            double physical;
            if (s->storage == GLIMS_PLATE_STORAGE_U8)
              physical = c ? (double) source[c].u8[p] - 128.0
                           : (double) source[c].u8[p] * 100.0 / 255.0;
            else if (s->storage == GLIMS_PLATE_STORAGE_U16)
              physical = c ? (double) source[c].u16[p] / 257.0 - 128.0
                           : (double) source[c].u16[p] * 100.0 / 65535.0;
            else
              physical = source[c].f32[p];
            lab[x * 3 + c] = (gfloat) physical;
          }
      if (!glims_lab_transform_pixels (s->oracle, lab, W, rgba + y * W * 4))
        return FALSE;
    }
  return TRUE;
}

static guint
maximum_difference (const guint8 *a, const guint8 *b, gsize bytes)
{
  guint maximum = 0;
  for (gsize i = 0; i < bytes; i++) maximum = MAX (maximum, (guint) abs ((int) a[i] - b[i]));
  return maximum;
}

static gboolean
opaque (const guint8 *pixels, gsize count)
{
  for (gsize i = 0; i < count; i++) if (pixels[i * 4 + 3] != 255) return FALSE;
  return TRUE;
}

static gboolean
profile_check (GlimsEngine *engine, Scene *s, const gfloat *linear,
               const guint8 *default_render)
{
  GimpColorProfile *source = gimp_color_profile_new_rgb_srgb ();
  GimpColorProfile *destination = gimp_color_profile_new_rgb_srgb_linear ();
  cmsHTRANSFORM transform = NULL;
  gboolean ok = FALSE;
  char *error = NULL;
  guint8 output[RGBA_BYTES], expected[RGBA_BYTES];
  gfloat encoded[PIXELS * 4], converted[PIXELS * 4];
  gsize length = 0;
  if (!source || !destination) goto done;
  const guint8 *icc = gimp_color_profile_get_icc_profile (destination, &length);
  transform = cmsCreateTransform (gimp_color_profile_get_lcms_profile (source), TYPE_RGBA_FLT,
                                  gimp_color_profile_get_lcms_profile (destination), TYPE_RGBA_FLT,
                                  INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_COPY_ALPHA | cmsFLAGS_NOCACHE);
  if (!icc || !length || !transform) goto done;
  babl_process (babl_fish ("RGBA float", "R'G'B'A float"), linear, encoded, PIXELS);
  cmsDoTransform (transform, encoded, converted, PIXELS);
  /* LCMS output is already encoded for the destination profile. This final
   * babl conversion only quantizes/premultiplies, without another TRC. */
  babl_process (babl_fish ("R'G'B'A float", "R'aG'aB'aA u8"), converted, expected, PIXELS);
  GlimsStatus status = api->image_render_to_profile (engine, s->id, 1,
    (GlimsRect) { 0, 0, W, H }, icc, length, output, W * 4, &error);
  guint difference = status == GLIMS_STATUS_OK ? maximum_difference (output, expected, RGBA_BYTES) : 256;
  printf ("PROFILE storage=%u status=%d max-byte-error=%u\n", s->storage, status, difference);
  ok = status == GLIMS_STATUS_OK && difference <= 2 && opaque (output, PIXELS) &&
       memcmp (output, default_render, RGBA_BYTES) != 0;
done:
  if (error) fprintf (stderr, "profile: %s\n", error);
  api->free_string (error);
  if (transform) cmsDeleteTransform (transform);
  g_clear_object (&source);
  g_clear_object (&destination);
  return ok;
}

static GlimsStatus
check_render (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  g_autofree Snapshot *snapshots = g_new0 (Snapshot, 2);
  Snapshot *before = &snapshots[0], *after = &snapshots[1];
  GlimsOpenImage *open;
  GlimsPlateStorage storage;
  gfloat linear[PIXELS * 4], actual_linear[PIXELS * 4], mipmap[PIXELS];
  guint8 expected[RGBA_BYTES], actual[RGBA_BYTES], expected_small[PIXELS], actual_small[PIXELS];
  if (!capture (engine, s, before) || !storage_for (engine, s, &open, &storage) ||
      !expected_linear (s, before->plane, linear)) return GLIMS_STATUS_FAILED;
  babl_process (babl_fish ("RGBA float", "R'aG'aB'aA u8"), linear, expected, PIXELS);
  /* Read the hot pixel before any full-area read can repair stale cache data. */
  guint8 pixel[4] = { 0 };
  CHECK (api->image_render (engine, s->id, 1, (GlimsRect) { EDIT_X, EDIT_Y, 1, 1 }, pixel, 4) == GLIMS_STATUS_OK &&
         maximum_difference (pixel, expected + EDIT_PIXEL * 4, 4) <= 1,
         "single-pixel nonzero-origin read agrees with current source");
  GlimsStatus status = api->image_render (engine, s->id, 1, (GlimsRect) { 0, 0, W, H }, actual, W * 4);
  guint difference = status == GLIMS_STATUS_OK ? maximum_difference (actual, expected, RGBA_BYTES) : 256;
  CHECK (status == GLIMS_STATUS_OK && difference <= 1 && opaque (actual, PIXELS),
         "public Lab render matches decoded samples plus reviewed transform/babl oracle");
  if (status != GLIMS_STATUS_OK) return status;

  GeglBuffer *buffer = NULL;
  status = glims_projection_prepare_read (open, 1, (GlimsRect) { 0, 0, W, H }, &buffer);
  if (status != GLIMS_STATUS_OK || !buffer) return GLIMS_STATUS_FAILED;
  gegl_buffer_get (buffer, GEGL_RECTANGLE (0, 0, W, H), 1, babl_format ("RGBA float"),
                   actual_linear, GEGL_AUTO_ROWSTRIDE, GEGL_ABYSS_NONE);
  double float_error = 0;
  gboolean finite = TRUE;
  for (guint p = 0; p < PIXELS * 4; p++)
    {
      finite &= isfinite (actual_linear[p]);
      float_error = MAX (float_error, fabs ((double) actual_linear[p] - linear[p]));
    }
  CHECK (finite && float_error <= 1e-6 && glims_plate_preview_succeeded (open->component_preview),
         "derived linear float cache preserves the unclipped full-resolution transform");

  for (guint y = 0; y < H / 2; y++)
    for (guint x = 0; x < W / 2; x++)
      for (guint c = 0; c < 4; c++)
        {
          double value = 0;
          for (guint dy = 0; dy < 2; dy++) for (guint dx = 0; dx < 2; dx++)
            value += (double) linear[((2 * y + dy) * W + 2 * x + dx) * 4 + c] / 4;
          mipmap[(y * (W / 2) + x) * 4 + c] = (gfloat) value;
        }
  babl_process (babl_fish ("RGBA float", "R'aG'aB'aA u8"), mipmap, expected_small, PIXELS / 4);
  status = api->image_render (engine, s->id, .5, (GlimsRect) { 0, 0, W / 2, H / 2 }, actual_small, W * 2);
  guint mip_difference = status == GLIMS_STATUS_OK ? maximum_difference (actual_small, expected_small, PIXELS) : 256;
  CHECK (status == GLIMS_STATUS_OK && mip_difference <= 1 && opaque (actual_small, PIXELS / 4),
         "half-scale public render averages linear RGB after Lab conversion");

  guint8 crop[7 * 2 * 4], expected_crop[sizeof crop];
  for (guint y = 0; y < 2; y++) memcpy (expected_crop + y * 7 * 4, expected + ((y + 2) * W + 253) * 4, 7 * 4);
  CHECK (api->image_render (engine, s->id, 1, (GlimsRect) { 253, 2, 7, 2 }, crop, 7 * 4) == GLIMS_STATUS_OK &&
         maximum_difference (crop, expected_crop, sizeof crop) <= 1,
         "small crop crossing a chunk boundary agrees with the full oracle");
  CHECK (profile_check (engine, s, linear, actual),
         "linear destination-profile render agrees with independent LCMS and changes encoded output");
  CHECK (capture (engine, s, after) && same_snapshot (s, before, after),
         "all render paths preserve source bits, map, dirty state and Undo/Redo/revision");
  printf ("LAB storage=%u byte=%u linear=%.9g mip-byte=%u\n",
          s->storage, difference, float_error, mip_difference);
  return GLIMS_STATUS_OK;
}

static GlimsStatus
check_white (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  Snapshot snap;
  if (!capture (engine, s, &snap)) return GLIMS_STATUS_FAILED;
  gboolean white = TRUE;
  for (guint c = 0; c < 3; c++) for (guint p = 0; p < PIXELS; p++)
    {
      if (s->storage == GLIMS_PLATE_STORAGE_U8)
        white &= snap.plane[c].u8[p] == (c ? 128 : 255);
      else if (s->storage == GLIMS_PLATE_STORAGE_U16)
        white &= snap.plane[c].u16[p] == (c ? 32896 : 65535);
      else
        white &= snap.plane[c].f32[p] == (c ? 0.0f : 100.0f);
    }
  CHECK (white, "new Lab has exact white L and neutral chroma at its native precision");
  guint8 pixels[RGBA_BYTES];
  GlimsStatus status = api->image_render (engine, s->id, 1, (GlimsRect) { 0, 0, W, H }, pixels, W * 4);
  gboolean rendered_white = status == GLIMS_STATUS_OK;
  for (guint p = 0; p < RGBA_BYTES && rendered_white; p++) rendered_white &= pixels[p] == 255;
  CHECK (rendered_white, "new Lab displays opaque white");
  return GLIMS_STATUS_OK;
}

static GlimsStatus
seed (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  GlimsOpenImage *open;
  GlimsPlateStorage storage;
  if (!storage_for (engine, s, &open, &storage)) return GLIMS_STATUS_FAILED;
  for (guint c = 0; c < 3; c++)
    {
      GimpDrawable *d = GIMP_DRAWABLE (storage.planes[c]);
      gegl_buffer_set (gimp_drawable_get_buffer (d), GEGL_RECTANGLE (0, 0, W, H),
                       0, raw_format (s->storage), &s->pattern[c], GEGL_AUTO_ROWSTRIDE);
      gimp_drawable_update (d, 0, 0, W, H);
    }
  gimp_image_undo_free (open->image);
  gimp_image_clean_all (open->image);
  Snapshot snap;
  return capture (engine, s, &snap) && same_raw (s, s->pattern, snap.plane)
           ? GLIMS_STATUS_OK : GLIMS_STATUS_FAILED;
}

static GlimsStatus
edit_and_undo (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  GlimsOpenImage *open;
  GlimsPlateStorage storage;
  g_autofree Snapshot *snapshots = g_new0 (Snapshot, 3);
  Snapshot *before = &snapshots[0], *after = &snapshots[1], *restored = &snapshots[2];
  if (!storage_for (engine, s, &open, &storage) || !capture (engine, s, before))
    return GLIMS_STATUS_FAILED;
  GimpDrawable *d = GIMP_DRAWABLE (storage.planes[0]);
  union { guint8 u8; guint16 u16; float f32; } value;
  if (s->storage == GLIMS_PLATE_STORAGE_U8) value.u8 = 32;
  else if (s->storage == GLIMS_PLATE_STORAGE_U16) value.u16 = 8192;
  else value.f32 = 12.5f;
  gimp_drawable_push_undo (d, "Lab render fixture change", NULL, EDIT_X, EDIT_Y, 1, 1);
  gegl_buffer_set (gimp_drawable_get_buffer (d), GEGL_RECTANGLE (EDIT_X, EDIT_Y, 1, 1),
                   0, raw_format (s->storage), &value, GEGL_AUTO_ROWSTRIDE);
  gimp_drawable_update (d, EDIT_X, EDIT_Y, 1, 1);
  if (!capture (engine, s, after)) return GLIMS_STATUS_FAILED;
  CHECK (after->undo == before->undo + 1 && !same_raw (s, before->plane, after->plane),
         "private one-pixel mutation creates one real native drawable Undo");
  CHECK (!memcmp (&after->plane[1], &before->plane[1], s->bytes) &&
         !memcmp (&after->plane[2], &before->plane[2], s->bytes), "mutation leaves both chroma planes exact");
  CHECK (check_render (engine, s) == GLIMS_STATUS_OK, "dirty cached full, small and mipmap renders are checked");
  CHECK (api->image_undo (engine, s->id) == GLIMS_STATUS_OK && capture (engine, s, restored) &&
         same_raw (s, before->plane, restored->plane), "public Undo restores all raw Lab samples exactly");
  CHECK (check_render (engine, s) == GLIMS_STATUS_OK, "Undo refreshes derived Lab cache");
  CHECK (api->image_redo (engine, s->id) == GLIMS_STATUS_OK && capture (engine, s, restored) &&
         same_raw (s, after->plane, restored->plane), "public Redo restores all edited Lab samples exactly");
  CHECK (check_render (engine, s) == GLIMS_STATUS_OK, "Redo refreshes derived Lab cache");
  return GLIMS_STATUS_OK;
}

static GlimsStatus
failure_recovery (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  GlimsOpenImage *open;
  GlimsPlateStorage storage;
  if (s->storage != GLIMS_PLATE_STORAGE_FLOAT || !storage_for (engine, s, &open, &storage))
    return GLIMS_STATUS_FAILED;
  const struct { guint axis; float sample; } bad[] = {
    { 0, NAN }, { 1, INFINITY }, { 2, -INFINITY },
    { 0, FLT_MAX }, { 1, FLT_MAX }, { 2, -FLT_MAX }
  };
  guint8 output[RGBA_BYTES];
  for (guint i = 0; i < G_N_ELEMENTS (bad); i++)
    {
      g_autofree Snapshot *snapshots = g_new0 (Snapshot, 3);
      Snapshot *original = &snapshots[0], *corrupt = &snapshots[1], *after = &snapshots[2];
      if (!capture (engine, s, original)) return GLIMS_STATUS_FAILED;
      GimpDrawable *d = GIMP_DRAWABLE (storage.planes[bad[i].axis]);
      GeglBuffer *buffer = gimp_drawable_get_buffer (d);
      gegl_buffer_set (buffer, GEGL_RECTANGLE (EDIT_X, EDIT_Y, 1, 1), 0, babl_format ("Y float"),
                       &bad[i].sample, GEGL_AUTO_ROWSTRIDE);
      gimp_drawable_update (d, EDIT_X, EDIT_Y, 1, 1);
      if (!capture (engine, s, corrupt)) return GLIMS_STATUS_FAILED;
      CHECK (api->image_render (engine, s->id, 1, (GlimsRect) { EDIT_X, EDIT_Y, 1, 1 }, output, 4) == GLIMS_STATUS_FAILED,
             "invalid Lab cannot escape through the hot single-pixel cache");
      CHECK (api->image_render (engine, s->id, 1, (GlimsRect) { 0, 0, W, H }, output, W * 4) == GLIMS_STATUS_FAILED,
             "nonfinite or unrenderable finite Lab refuses the public full render");
      CHECK (api->image_render (engine, s->id, .5, (GlimsRect) { 0, 0, W / 2, H / 2 }, output, W * 2) == GLIMS_STATUS_FAILED,
             "failure placeholders cannot make a later mipmap render succeed");
      CHECK (capture (engine, s, after) && same_snapshot (s, corrupt, after),
             "failed render preserves even invalid source bits and native history");
      gegl_buffer_set (buffer, GEGL_RECTANGLE (EDIT_X, EDIT_Y, 1, 1), 0, babl_format ("Y float"),
                       &original->plane[bad[i].axis].f32[EDIT_PIXEL], GEGL_AUTO_ROWSTRIDE);
      gimp_drawable_update (d, EDIT_X, EDIT_Y, 1, 1);
      CHECK (check_render (engine, s) == GLIMS_STATUS_OK, "repair retries the complete failed derived cache");
      CHECK (capture (engine, s, after) && same_raw (s, original->plane, after->plane),
             "repair restores every authoritative sample exactly");
    }
  return GLIMS_STATUS_OK;
}

static GlimsStatus
close_and_check (GlimsEngine *engine, gpointer data)
{
  Scene *s = data;
  GlimsOpenImage *open = glims_lookup_image (engine, s->id);
  GeglBuffer *buffer = NULL;
  if (!open || glims_projection_prepare_read (open, 1, (GlimsRect) { 0, 0, W, H }, &buffer) != GLIMS_STATUS_OK || !buffer)
    return GLIMS_STATUS_FAILED;
  GWeakRef source, derived;
  g_weak_ref_init (&source, G_OBJECT (open->image));
  g_weak_ref_init (&derived, G_OBJECT (buffer));
  GlimsStatus status = api->image_close (engine, s->id);
  GObject *remaining_source = g_weak_ref_get (&source);
  GObject *remaining_derived = g_weak_ref_get (&derived);
  CHECK (status == GLIMS_STATUS_OK, "Lab render document closes");
  CHECK (!remaining_source && !remaining_derived, "close releases source and derived preview objects");
  g_clear_object (&remaining_source);
  g_clear_object (&remaining_derived);
  g_weak_ref_clear (&source);
  g_weak_ref_clear (&derived);
  return status;
}

int
main (int argc, char **argv)
{
  if (argc != 2) { fprintf (stderr, "usage: %s WORK\n", argv[0]); return 2; }
  api = glims_engine_get_api (GLIMS_ENGINE_API_VERSION);
  if (!api || api->struct_size < offsetof (GlimsEngineAPI, image_new_lab) + sizeof api->image_new_lab ||
      !api->image_new_lab) { fprintf (stderr, "adapter needs image_new_lab slot190\n"); return 2; }
  gchar *user = g_build_filename (argv[1], "user", NULL);
  gchar *cache = g_build_filename (argv[1], "cache", NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config, .user_directory = user, .cache_directory = cache };
  GlimsEngine *engine = NULL;
  char *error = NULL;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK)
    { fprintf (stderr, "start: %s\n", error ? error : "failed"); api->free_string (error); g_free (user); g_free (cache); return 2; }
  api->free_string (error); error = NULL;
  GlimsLabTransform *oracle = glims_lab_transform_new ();
  if (!oracle) { api->stop (engine); g_free (user); g_free (cache); return 2; }
  const guint components[] = { GLIMS_COLOR_COMPONENT_U8, GLIMS_COLOR_COMPONENT_U16, GLIMS_COLOR_COMPONENT_FLOAT };
  for (guint i = 0; i < G_N_ELEMENTS (components); i++)
    {
      Scene s = { .component = components[i], .storage = i + 1, .bytes = PIXELS * (i == 0 ? 1 : i == 1 ? 2 : 4), .oracle = oracle };
      GlimsStatus status = api->image_new_lab (engine, W, H, s.component, &s.id, &error);
      CHECK (status == GLIMS_STATUS_OK && s.id, "public factory creates a Lab document for render checks");
      api->free_string (error); error = NULL;
      if (!s.id) continue;
      GlimsColorInfo info = {0};
      CHECK (api->image_color_info (engine, s.id, &info) == GLIMS_STATUS_OK &&
             info.mode == GLIMS_COLOR_MODE_LAB && info.component == s.component,
             "public color metadata reports actual Lab precision");
      CHECK (glims_engine_call (engine, check_white, &s) == GLIMS_STATUS_OK, "new-document white render checks complete");
      make_pattern (&s);
      gboolean seeded = glims_engine_call (engine, seed, &s) == GLIMS_STATUS_OK;
      CHECK (seeded, "fixture seeds exact mixed-sign native samples after caching white");
      if (seeded)
        {
          CHECK (glims_engine_call (engine, check_render, &s) == GLIMS_STATUS_OK, "seeded render oracle checks complete");
          CHECK (glims_engine_call (engine, edit_and_undo, &s) == GLIMS_STATUS_OK, "dirty-cache and Undo/Redo checks complete");
          if (s.storage == GLIMS_PLATE_STORAGE_FLOAT)
            CHECK (glims_engine_call (engine, failure_recovery, &s) == GLIMS_STATUS_OK, "float failure/recovery checks complete");
        }
      gboolean closed = glims_engine_call (engine, close_and_check, &s) == GLIMS_STATUS_OK;
      CHECK (closed, "native close/lifetime checks complete");
      if (!closed) api->image_close (engine, s.id);
      guint8 pixel[4];
      CHECK (api->image_render (engine, s.id, 1, (GlimsRect) { 0, 0, 1, 1 }, pixel, 4) == GLIMS_STATUS_NOT_FOUND,
             "closed Lab image cannot render through a stale handle");
    }
  glims_lab_transform_free (oracle);
  api->stop (engine);
  g_free (user); g_free (cache);
  printf ("%u Lab document render checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}
