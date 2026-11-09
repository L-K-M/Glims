/* Public-facade-only image_duplicate_layers (slot 142) checks. */
#include "glims_engine.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const GlimsEngineAPI *api;
static GlimsEngine *engine;
static int failures;
static GlimsItemID outbuf[4];

#define CHECK(c, text) do { printf ("%s %s\n", (c) ? "ok  " : (failures++, "FAIL"), text); fflush (stdout); } while (0)

static void clear_error (char **error) { if (*error) api->free_string (*error); *error = NULL; }

static int get_layers (GlimsImageID image, GlimsLayerInfo *out, int cap)
{
  int32_t count = 0;
  if (api->image_layers (engine, image, out, cap, &count) != GLIMS_STATUS_OK || count > cap) return -1;
  return count;
}

static int get_selected (GlimsImageID image, GlimsItemID *out, int cap)
{
  int32_t count = 0;
  if (api->image_selected_layers (engine, image, out, cap, &count) != GLIMS_STATUS_OK || count > cap) return -1;
  return count;
}

static int layers_equal (GlimsImageID image, const GlimsLayerInfo *base, int base_count)
{
  GlimsLayerInfo now[16];
  int n = get_layers (image, now, 16);
  int i;
  if (n != base_count) return 0;
  for (i = 0; i < n; i++)
    {
      if (now[i].id != base[i].id) return 0;
      if (now[i].parent != base[i].parent) return 0;
    }
  return 1;
}

static int all_pixels (const GlimsPixelBuffer *buf, unsigned char r, unsigned char g,
                       unsigned char b, unsigned char a)
{
  size_t i;
  if (!buf || !buf->pixels || buf->byte_count == 0 || buf->byte_count % 4) return 0;
  for (i = 0; i < buf->byte_count; i += 4)
    {
      if (buf->pixels[i] != r || buf->pixels[i + 1] != g ||
          buf->pixels[i + 2] != b || buf->pixels[i + 3] != a) return 0;
    }
  return 1;
}

static int find_index (const GlimsLayerInfo *layers, int count, GlimsItemID id)
{
  int i;
  for (i = 0; i < count; i++)
    if (layers[i].id == id) return i;
  return -1;
}

typedef struct {
  GlimsImageInfo info;
  GlimsUndoInfo undo;
  GlimsLayerInfo layers[16];
  GlimsItemID selected[16];
  int layer_count, selected_count;
  uint8_t pixels[32 * 24 * 4];
} ImageSnapshot;

static int snapshot (GlimsImageID image, ImageSnapshot *out)
{
  memset (out, 0, sizeof *out);
  out->layer_count = get_layers (image, out->layers, 16);
  out->selected_count = get_selected (image, out->selected, 16);
  return out->layer_count >= 0 && out->selected_count >= 0 &&
    api->image_info (engine, image, &out->info) == GLIMS_STATUS_OK &&
    api->image_undo_info (engine, image, &out->undo) == GLIMS_STATUS_OK &&
    api->image_render (engine, image, 1, (GlimsRect) {0, 0, 32, 24}, out->pixels, 32 * 4) == GLIMS_STATUS_OK;
}

static int snapshot_equal (const ImageSnapshot *a, const ImageSnapshot *b)
{
  if (memcmp (&a->info, &b->info, sizeof a->info) || memcmp (&a->undo, &b->undo, sizeof a->undo) ||
      a->layer_count != b->layer_count || a->selected_count != b->selected_count ||
      memcmp (a->selected, b->selected, sizeof a->selected) || memcmp (a->pixels, b->pixels, sizeof a->pixels)) return 0;
  for (int i = 0; i < a->layer_count; i++) {
    const GlimsLayerInfo *x = &a->layers[i], *y = &b->layers[i];
    if (x->id != y->id || x->parent != y->parent || x->depth != y->depth || x->kind != y->kind ||
        strcmp (x->name, y->name) || strcmp (x->mode, y->mode) || x->visible != y->visible ||
        x->has_mask != y->has_mask || x->selected != y->selected || x->opacity != y->opacity ||
        memcmp (&x->bounds, &y->bounds, sizeof x->bounds) || x->filter_count != y->filter_count) return 0;
  }
  return 1;
}

static GlimsStatus checked_duplicate (GlimsEngine *e, GlimsImageID image, const GlimsItemID *ids,
                                      int32_t count, GlimsItemID *output, char **error)
{
  ImageSnapshot before, after;
  int readable = snapshot (image, &before);
  GlimsStatus status = api->image_duplicate_layers (e, image, ids, count, output, error);
  if (status != GLIMS_STATUS_OK) {
    CHECK (readable && snapshot (image, &after) && snapshot_equal (&before, &after),
           "each ordinary refusal preserves the complete tree, selection, image facts, rendered pixels and history");
  }
  if (output == outbuf) {
    static const uint32_t canaries[] = { 0xAAAAAAAAu, 0xBBBBBBBBu, 0xCCCCCCCCu, 0xDDDDDDDDu };
    for (int i = count > 0 && count <= 3 ? count : 0; i < 4; i++)
      CHECK ((uint32_t) outbuf[i] == canaries[i], "output storage beyond the requested count is untouched");
  }
  return status;
}

static void extra_public_cases (void)
{
  GlimsImageID image = 0;
  GlimsItemID A = 0, B = 0, outer = 0, inner = 0, unrelated = 0, mask = 0;
  uint8_t red[32 * 24 * 4], blue[8 * 8 * 4];
  char *error = NULL;
  GlimsLayerInfo layers[16], baseline[16];
  int baseline_count;
#define NEED(expr, text) do { int ok_ = (expr); CHECK (ok_, text); if (!ok_) goto cleanup; } while (0)
  for (size_t i = 0; i < sizeof red; i += 4) { red[i] = 255; red[i+1] = red[i+2] = 0; red[i+3] = 255; }
  for (size_t i = 0; i < sizeof blue; i += 4) { blue[i] = blue[i+1] = 0; blue[i+2] = blue[i+3] = 255; }
  NEED (api->image_from_pixels (engine, 32, 24, red, sizeof red, &image, &error) == GLIMS_STATUS_OK,
        "extra fixtures create the known red image");
  NEED (get_layers (image, layers, 16) == 1, "extra red fixture has one source");
  A = layers[0].id;
  NEED (api->image_paste_pixels (engine, image, (GlimsRect) {12, 5, 8, 8}, blue, sizeof blue, &B, &error) == GLIMS_STATUS_OK,
        "extra fixtures paste the known blue layer");
  baseline_count = get_layers (image, baseline, 16);
  for (int alias = 0; alias < 3; alias++) {
    GlimsItemID arena[6] = { 0x11223344, 0, 0, 0, 0x55667788, 0x12345678 };
    GlimsItemID *input = arena + (alias == 2 ? 2 : 1);
    GlimsItemID *output = arena + (alias == 1 ? 2 : 1);
    input[0] = B; input[1] = A;
    NEED (api->image_duplicate_layers (engine, image, input, 2, output, &error) == GLIMS_STATUS_OK,
          "exact or shifted input/output overlap duplicates successfully");
    CHECK (output[0] > 0 && output[1] > 0 && output[0] != output[1] &&
           output[0] != A && output[0] != B && output[1] != A && output[1] != B,
           "overlapping buffers return distinct new ids independently of overwritten inputs");
    CHECK (arena[0] == 0x11223344 && arena[4] == 0x55667788 && arena[5] == 0x12345678,
           "overlapping buffers preserve outer canaries");
    GlimsItemID selected[4];
    CHECK (get_selected (image, selected, 4) == 2 && selected[0] == output[0] && selected[1] == output[1],
           "overlapping buffers preserve the requested blue/red selected order");
    for (int i = 0; i < 2; i++) {
      uint8_t pixels[8 * 8 * 4] = {0}; int32_t w = 0, h = 0;
      GlimsStatus status = api->drawable_thumbnail (engine, image, output[i], 8, pixels, sizeof pixels, &w, &h);
      GlimsPixelBuffer view = { .pixels = pixels, .byte_count = 0 };
      view.byte_count = w > 0 && h > 0 ? (size_t) w * h * 4 : 0;
      CHECK (status == GLIMS_STATUS_OK && w == 8 && h == (i == 0 ? 8 : 6) &&
             all_pixels (&view, i == 0 ? 0 : 255, 0, i == 0 ? 255 : 0, 255),
             "each aliased result has all independently expected blue or red pixels");
    }
    NEED (api->image_undo (engine, image) == GLIMS_STATUS_OK, "aliased duplicate is undoable");
    CHECK (layers_equal (image, baseline, baseline_count), "aliased Undo restores the original tree");
  }
  NEED (api->create_group (engine, image, 0, 0, "Outer", &outer, &error) == GLIMS_STATUS_OK &&
        api->create_group (engine, image, outer, 0, "Inner", &inner, &error) == GLIMS_STATUS_OK &&
        api->create_group (engine, image, 0, 0, "Unrelated", &unrelated, &error) == GLIMS_STATUS_OK &&
        api->reparent_layer (engine, image, A, outer, 1, &error) == GLIMS_STATUS_OK &&
        api->reparent_layer (engine, image, B, inner, 0, &error) == GLIMS_STATUS_OK,
        "nested fixture places explicit red and blue sources in different actual parents");
  NEED (api->image_select_layers (engine, image, &unrelated, 1, &error) == GLIMS_STATUS_OK,
        "an unrelated group is selected before the explicit nested batch");
  GlimsItemID inputs[2] = { B, A }, outputs[2] = {0};
  GlimsUndoInfo before = {0}, after = {0};
  NEED (api->image_undo_info (engine, image, &before) == GLIMS_STATUS_OK &&
        api->image_duplicate_layers (engine, image, inputs, 2, outputs, &error) == GLIMS_STATUS_OK &&
        api->image_undo_info (engine, image, &after) == GLIMS_STATUS_OK,
        "nested batch succeeds using explicit captured sources");
  int n = get_layers (image, layers, 16);
  int a = find_index (layers, n, A), b = find_index (layers, n, B);
  int ac = find_index (layers, n, outputs[1]), bc = find_index (layers, n, outputs[0]);
  CHECK (a >= 0 && b >= 0 && ac >= 0 && bc >= 0 && ac + 1 == a && bc + 1 == b &&
         layers[a].parent == outer && layers[ac].parent == outer &&
         layers[b].parent == inner && layers[bc].parent == inner,
         "copies land immediately above each explicit source in its known actual parent");
  CHECK (after.undo_count == before.undo_count + 1, "nested batch adds one native Undo group");
  NEED (api->image_undo (engine, image) == GLIMS_STATUS_OK, "nested batch Undo succeeds");
  GlimsItemID selected[4];
  CHECK (get_selected (image, selected, 4) == 1 && selected[0] == unrelated,
         "nested Undo restores the unrelated pre-command selection");
  /* Binary alpha provides an independent exact mask oracle, without gamma ambiguity. */
  for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) blue[(y * 8 + x) * 4 + 3] = x < 4 ? 255 : 0;
  GlimsItemID masked = 0;
  NEED (api->image_paste_pixels (engine, image, (GlimsRect) {0, 0, 8, 8}, blue, sizeof blue, &masked, &error) == GLIMS_STATUS_OK &&
        api->layer_mask_add (engine, image, masked, GLIMS_MASK_ALPHA, false, &mask, &error) == GLIMS_STATUS_OK &&
        api->layer_mask_set (engine, image, masked, GLIMS_MASK_ENABLED | GLIMS_MASK_SHOWING, GLIMS_MASK_SHOWING, &error) == GLIMS_STATUS_OK,
        "mask fixture creates a known binary-alpha mask with explicit display flags");
  GlimsItemID copy = 0;
  NEED (api->image_duplicate_layers (engine, image, &masked, 1, &copy, &error) == GLIMS_STATUS_OK,
        "a plain layer with an attached mask duplicates");
  GlimsMaskState masks[2] = {{0}};
  NEED (api->layer_mask (engine, image, masked, &masks[0]) == GLIMS_STATUS_OK &&
        api->layer_mask (engine, image, copy, &masks[1]) == GLIMS_STATUS_OK,
        "source and copy expose their owned native mask identities");
  CHECK (masks[0].mask == mask && masks[1].mask > 0 && masks[1].mask != mask &&
         !masks[0].enabled && !masks[1].enabled && masks[0].showing && masks[1].showing &&
         !masks[0].editing && !masks[1].editing,
         "mask copies have independent ids and preserve enabled/showing/editing flags");
  for (int i = 0; i < 2; i++) {
    uint8_t pixels[8 * 8 * 4] = {0}; int32_t w = 0, h = 0;
    int exact = api->drawable_thumbnail (engine, image, masks[i].mask, 8, pixels, sizeof pixels, &w, &h) == GLIMS_STATUS_OK && w == 8 && h == 8;
    for (int y = 0; y < 8 && exact; y++) for (int x = 0; x < 8; x++) {
      const uint8_t *p = pixels + (y * 8 + x) * 4; uint8_t value = x < 4 ? 255 : 0;
      if (p[0] != value || p[1] != value || p[2] != value || p[3] != 255) exact = 0;
    }
    CHECK (exact, "all source/copy mask pixels match the independently known binary alpha pattern");
  }
cleanup:
  clear_error (&error);
  if (image) api->image_close (engine, image);
#undef NEED
}

int
main (int argc, char **argv)
{
  void *library;
  const GlimsEngineAPI *(*get_api) (uint32_t);
  GlimsEngineConfig config = { .struct_size = sizeof config };
  char user[4096], cache[4096], work[4096];
  char *error = NULL;
  uint8_t red_pixels[32 * 24 * 4];
  uint8_t blue_pixels[8 * 8 * 4];
  GlimsImageID image = 0, other_image = 0;
  GlimsLayerInfo layers[16];
  int32_t layer_count = 0;
  GlimsItemID A = 0, B = 0;
  int i;
  int base_layer_count = 0;
  GlimsLayerInfo base_layers[16];
  GlimsUndoInfo base_undo = {0};
  GlimsItemID copies[2];
  GlimsItemID src_order[2];

  if (argc != 3) { fprintf (stderr, "usage: %s LIBRARY WORK_DIR\n", argv[0]); return 2; }
  snprintf (work, sizeof work, "%s", argv[2]);
  snprintf (user, sizeof user, "%s/user", work);
  snprintf (cache, sizeof cache, "%s/cache", work);

  library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf (stderr, "%s\n", dlerror ()); return 2; }
  *(void **) (&get_api) = dlsym (library, "glims_engine_get_api");
  if (!get_api) { dlclose (library); return 2; }
  api = get_api (1);
  if (!api || api->api_version != 1) { dlclose (library); return 2; }
  if (api->struct_size < (uint32_t) (offsetof (GlimsEngineAPI, image_duplicate_layers) +
                                     sizeof (api->image_duplicate_layers))) { dlclose (library); return 2; }
  if (!api->image_duplicate_layers) { dlclose (library); return 2; }

  for (i = 0; i < 32 * 24 * 4; i += 4) { red_pixels[i]=255; red_pixels[i+1]=0; red_pixels[i+2]=0; red_pixels[i+3]=255; }
  for (i = 0; i < 8 * 8 * 4; i += 4) { blue_pixels[i]=0; blue_pixels[i+1]=0; blue_pixels[i+2]=255; blue_pixels[i+3]=255; }

  config.user_directory = user;
  config.cache_directory = cache;
  if (api->start (&config, &engine, &error) != GLIMS_STATUS_OK) { clear_error (&error); dlclose (library); return 2; }
  clear_error (&error);

  /* Create base image. */
  {
    GlimsImageID img = 0;
    char *e = NULL;
    if (api->image_from_pixels (engine, 32, 24, red_pixels, sizeof red_pixels, &img, &e) != GLIMS_STATUS_OK) { clear_error (&e); failures++; goto done; }
    clear_error (&e);
    image = img;
  }
  if (!image) { failures++; goto done; }

  layer_count = get_layers (image, layers, 16);
  if (layer_count < 1) { failures++; goto done; }
  A = layers[0].id;

  /* Paste blue layer B. */
  {
    GlimsRect bounds = { 12, 5, 8, 8 };
    char *e = NULL;
    if (api->image_paste_pixels (engine, image, bounds, blue_pixels, sizeof blue_pixels, &B, &e) != GLIMS_STATUS_OK) { clear_error (&e); failures++; goto done; }
    clear_error (&e);
  }
  if (!B) { failures++; goto done; }

  /* Select [B, A]. */
  {
    GlimsItemID sel[2] = { B, A };
    char *e = NULL;
    api->image_select_layers (engine, image, sel, 2, &e);
    clear_error (&e);
  }

  /* Baseline capture. */
  base_layer_count = get_layers (image, base_layers, 16);
  api->image_undo_info (engine, image, &base_undo);

  CHECK (base_layer_count >= 2, "baseline has at least two layers");

  /* Duplicate with input order [B, A]. */
  src_order[0] = B;
  src_order[1] = A;
  copies[0] = 0x11111111;
  copies[1] = 0x22222222;
  {
    char *e = NULL;
    GlimsStatus st = checked_duplicate (engine, image, src_order, 2, copies, &e);
    CHECK (st == GLIMS_STATUS_OK, "duplicate returns OK");
    if (st != GLIMS_STATUS_OK) fprintf (stderr, "duplicate: %d %s\n", st, e ? e : "no message");
    clear_error (&e);
    if (st != GLIMS_STATUS_OK) goto done;
    CHECK (copies[0] != 0 && copies[1] != 0 && copies[0] != copies[1], "two new distinct copy ids");
    CHECK (copies[0] != B && copies[0] != A && copies[1] != B && copies[1] != A, "copies are new ids");
  }

  /* Selected copies in input order. */
  {
    GlimsItemID now_sel[8];
    int n = get_selected (image, now_sel, 8);
    CHECK (n == 2 && now_sel[0] == copies[0] && now_sel[1] == copies[1], "selected copies [Bcopy, Acopy]");
  }

  /* Copies exactly above each source, same parent. */
  {
    GlimsLayerInfo now[16];
    int n = get_layers (image, now, 16);
    int idxB = find_index (now, n, B);
    int idxBcopy = find_index (now, n, copies[0]);
    int idxA = find_index (now, n, A);
    int idxAcopy = find_index (now, n, copies[1]);
    int parentB = (idxB >= 0) ? now[idxB].parent : -999;
    int parentBcopy = (idxBcopy >= 0) ? now[idxBcopy].parent : -998;
    int parentA = (idxA >= 0) ? now[idxA].parent : -997;
    int parentAcopy = (idxAcopy >= 0) ? now[idxAcopy].parent : -996;
    CHECK (idxBcopy >= 0 && idxB >= 0 && idxBcopy + 1 == idxB, "Bcopy immediately above B");
    CHECK (idxAcopy >= 0 && idxA >= 0 && idxAcopy + 1 == idxA, "Acopy immediately above A");
    CHECK (parentBcopy == parentB && parentAcopy == parentA, "copies share source parent");
  }

  /* Undo count +1. */
  {
    GlimsUndoInfo u;
    api->image_undo_info (engine, image, &u);
    CHECK (u.undo_count == base_undo.undo_count + 1, "undo count +1");
  }

  /* Pixel oracles. */
  {
    GlimsPixelBuffer buf = {0};
    char *e = NULL;
    /* Source A bounds/pixels. */
    {
      GlimsLayerInfo now[16];
      int n = get_layers (image, now, 16);
      int idxA = find_index (now, n, A);
      int idxB = find_index (now, n, B);
      CHECK (idxA >= 0 && now[idxA].bounds.width == 32 && now[idxA].bounds.height == 24 &&
                            now[idxA].bounds.x == 0 && now[idxA].bounds.y == 0, "source A bounds unchanged");
      CHECK (idxB >= 0 && now[idxB].bounds.width == 8 && now[idxB].bounds.height == 8 &&
                            now[idxB].bounds.x == 12 && now[idxB].bounds.y == 5, "source B bounds unchanged");
    }
    /* Source A pixels via layer_select + copy_pixels. */
    api->layer_select (engine, image, A);
    if (api->image_copy_pixels (engine, image, 0, &buf, &e) == GLIMS_STATUS_OK) {
      CHECK (buf.bounds.width == 32 && buf.bounds.height == 24 && all_pixels (&buf, 255,0,0,255), "source A pixels RED");
      api->free_pixels (buf.pixels);
      memset (&buf, 0, sizeof buf);
    } else CHECK (0, "a required native pixel read succeeds");
    clear_error (&e);
    /* Source B pixels. */
    api->layer_select (engine, image, B);
    if (api->image_copy_pixels (engine, image, 0, &buf, &e) == GLIMS_STATUS_OK) {
      CHECK (buf.bounds.width == 8 && buf.bounds.height == 8 && all_pixels (&buf, 0,0,255,255), "source B pixels BLUE");
      api->free_pixels (buf.pixels);
      memset (&buf, 0, sizeof buf);
    } else CHECK (0, "a required native pixel read succeeds");
    clear_error (&e);
    /* Copy of A pixels. */
    api->layer_select (engine, image, copies[1]);
    if (api->image_copy_pixels (engine, image, 0, &buf, &e) == GLIMS_STATUS_OK) {
      CHECK (buf.bounds.width == 32 && buf.bounds.height == 24 && all_pixels (&buf, 255,0,0,255), "copy of A pixels RED");
      api->free_pixels (buf.pixels);
      memset (&buf, 0, sizeof buf);
    } else CHECK (0, "a required native pixel read succeeds");
    clear_error (&e);
    /* Copy of B pixels. */
    api->layer_select (engine, image, copies[0]);
    if (api->image_copy_pixels (engine, image, 0, &buf, &e) == GLIMS_STATUS_OK) {
      CHECK (buf.bounds.width == 8 && buf.bounds.height == 8 && all_pixels (&buf, 0,0,255,255), "copy of B pixels BLUE");
      api->free_pixels (buf.pixels);
      memset (&buf, 0, sizeof buf);
    } else CHECK (0, "a required native pixel read succeeds");
    clear_error (&e);
    /* Restore desired selection. */
    {
      GlimsItemID sel[2] = { copies[0], copies[1] };
      char *e2 = NULL;
      api->image_select_layers (engine, image, sel, 2, &e2);
      clear_error (&e2);
    }
  }

  /* Undo/Redo cycles: reorder original selected [A,B] before Undo. */
  {
    int cycle;
    for (cycle = 0; cycle < 3; cycle++)
      {
        /* Reorder original selected to [A, B]. */
        {
          GlimsItemID sel[2] = { A, B };
          char *e = NULL;
          api->image_select_layers (engine, image, sel, 2, &e);
          clear_error (&e);
        }
        /* Undo. */
        CHECK (api->image_undo (engine, image) == GLIMS_STATUS_OK, "undo OK");
        /* Expect original before [B, A] restored. */
        {
          GlimsItemID now_sel[8];
          int n = get_selected (image, now_sel, 8);
          CHECK (n == 2 && now_sel[0] == B && now_sel[1] == A, "undo restores [B, A]");
        }
        /* Tree restored to baseline. */
        CHECK (layers_equal (image, base_layers, base_layer_count), "undo restores original tree");
        /* Redo. */
        CHECK (api->image_redo (engine, image) == GLIMS_STATUS_OK, "redo OK");
        {
          GlimsItemID now_sel[8];
          int n = get_selected (image, now_sel, 8);
          CHECK (n == 2 && now_sel[0] == copies[0] && now_sel[1] == copies[1], "redo restores [Bcopy, Acopy]");
        }
        {
          GlimsLayerInfo now[16];
          int n = get_layers (image, now, 16);
          int idxBcopy = find_index (now, n, copies[0]);
          int idxB = find_index (now, n, B);
          int idxAcopy = find_index (now, n, copies[1]);
          int idxA = find_index (now, n, A);
          CHECK (idxBcopy >= 0 && idxB >= 0 && idxBcopy + 1 == idxB, "redo Bcopy above B");
          CHECK (idxAcopy >= 0 && idxA >= 0 && idxAcopy + 1 == idxA, "redo Acopy above A");
        }
      }
  }

  /* Restore selection to copies. */
  {
    GlimsItemID sel[2] = { copies[0], copies[1] };
    char *e = NULL;
    api->image_select_layers (engine, image, sel, 2, &e);
    clear_error (&e);
  }

  /* Refusal fixtures outside baseline. */
  {
    /* Dead source via paste + delete. */
    GlimsItemID dead = 0;
    GlimsItemID foreign = 0;
    GlimsItemID grp = 0;
    uint8_t one[4] = { 255, 0, 0, 255 };
    GlimsRect r = { 0, 0, 1, 1 };
    GlimsItemID src_dead[3];
    GlimsItemID src_foreign[1];
    GlimsItemID src_group[1];
    GlimsItemID src_zero[2];
    GlimsItemID src_dup[2];
    (void) 0;

    /* dead */
    {
      char *e = NULL;
      GlimsItemID tmp = 0;
      api->image_paste_pixels (engine, image, r, one, 4, &tmp, &e);
      clear_error (&e);
      if (tmp)
        {
          dead = tmp;
          api->layer_command (engine, image, dead, GLIMS_LAYER_DELETE, NULL, &e);
          clear_error (&e);
        }
    }
    /* foreign image */
    {
      char *e = NULL;
      GlimsLayerInfo l2[4];
      int32_t c2 = 0;
      uint8_t rp[4*4*4];
      for (i = 0; i < 4*4*4; i += 4) { rp[i]=255; rp[i+1]=0; rp[i+2]=0; rp[i+3]=255; }
      if (api->image_from_pixels (engine, 4, 4, rp, sizeof rp, &other_image, &e) == GLIMS_STATUS_OK)
        {
          clear_error (&e);
          c2 = get_layers (other_image, l2, 4);
          if (c2 > 0) foreign = l2[0].id;
        }
      else clear_error (&e);
    }
    /* group */
    {
      char *e = NULL;
      api->create_group (engine, image, 0, 0, NULL, &grp, &e);
      clear_error (&e);
    }

    CHECK (dead != 0 && foreign != 0 && grp != 0, "all refusal fixtures actually exist");
    /* empty count */
    {
      GlimsLayerInfo bl[16]; int bc = get_layers (image, bl, 16);
      GlimsItemID bs[8]; int bsc = get_selected (image, bs, 8);
      GlimsImageInfo bi; api->image_info (engine, image, &bi);
      GlimsUndoInfo bu; api->image_undo_info (engine, image, &bu);
      char *e = NULL;
      outbuf[0]=0xAAAAAAAA; outbuf[1]=0xBBBBBBBB; outbuf[2]=0xCCCCCCCC; outbuf[3]=0xDDDDDDDD;
      GlimsStatus st = checked_duplicate (engine, image, src_order, 0, outbuf, &e);
      clear_error (&e);
      CHECK (st == GLIMS_STATUS_INVALID_ARGUMENT, "empty count INVALID");
      CHECK (layers_equal (image, bl, bc), "empty count tree unchanged");
      /* selection */
      {
        GlimsItemID as[8]; int asc = get_selected (image, as, 8);
        int same = (asc == bsc);
        for (i = 0; i < bsc && i < 8; i++) if (as[i] != bs[i]) same = 0;
        CHECK (same, "empty count selection unchanged");
      }
      (void) bi; (void) bu;
    }

    /* negative count: don't assert reset. */
    {
      char *e = NULL;
      GlimsStatus st = checked_duplicate (engine, image, src_order, -1, outbuf, &e);
      clear_error (&e);
      CHECK (st == GLIMS_STATUS_INVALID_ARGUMENT, "negative count INVALID");
    }

    /* null sources with valid count. */
    {
      char *e = NULL;
      outbuf[0]=0xAAAAAAAA; outbuf[1]=0xBBBBBBBB; outbuf[2]=0xCCCCCCCC; outbuf[3]=0xDDDDDDDD;
      GlimsStatus st = checked_duplicate (engine, image, NULL, 2, outbuf, &e);
      clear_error (&e);
      CHECK (st == GLIMS_STATUS_INVALID_ARGUMENT, "null sources INVALID");
      CHECK (outbuf[0] == 0 && outbuf[1] == 0, "null sources out all zero");
    }

    /* duplicate source. */
    src_dup[0] = A; src_dup[1] = A;
    {
      char *e = NULL;
      outbuf[0]=0xAAAAAAAA; outbuf[1]=0xBBBBBBBB; outbuf[2]=0xCCCCCCCC; outbuf[3]=0xDDDDDDDD;
      GlimsStatus st = checked_duplicate (engine, image, src_dup, 2, outbuf, &e);
      clear_error (&e);
      CHECK (st == GLIMS_STATUS_INVALID_ARGUMENT, "duplicate source INVALID");
      CHECK (outbuf[0] == 0 && outbuf[1] == 0, "duplicate source out all zero");
    }

    /* source 0. */
    src_zero[0] = 0; src_zero[1] = A;
    {
      char *e = NULL;
      outbuf[0]=0xAAAAAAAA; outbuf[1]=0xBBBBBBBB; outbuf[2]=0xCCCCCCCC; outbuf[3]=0xDDDDDDDD;
      GlimsStatus st = checked_duplicate (engine, image, src_zero, 2, outbuf, &e);
      clear_error (&e);
      CHECK (st == GLIMS_STATUS_INVALID_ARGUMENT, "source 0 INVALID");
      CHECK (outbuf[0] == 0 && outbuf[1] == 0, "source 0 out all zero");
    }

    /* middle dead. */
    if (dead != 0)
      {
        src_dead[0] = A; src_dead[1] = dead; src_dead[2] = B;
        {
          char *e = NULL;
          outbuf[0]=0xAAAAAAAA; outbuf[1]=0xBBBBBBBB; outbuf[2]=0xCCCCCCCC; outbuf[3]=0xDDDDDDDD;
          GlimsStatus st = checked_duplicate (engine, image, src_dead, 3, outbuf, &e);
          clear_error (&e);
          CHECK (st == GLIMS_STATUS_NOT_FOUND, "middle dead NOT_FOUND");
          CHECK (outbuf[0] == 0 && outbuf[1] == 0 && outbuf[2] == 0, "middle dead out all zero (valid count)");
        }
      }

    /* foreign. */
    if (foreign != 0)
      {
        src_foreign[0] = foreign;
        {
          char *e = NULL;
          outbuf[0]=0xAAAAAAAA; outbuf[1]=0xBBBBBBBB; outbuf[2]=0xCCCCCCCC; outbuf[3]=0xDDDDDDDD;
          GlimsStatus st = checked_duplicate (engine, image, src_foreign, 1, outbuf, &e);
          clear_error (&e);
          CHECK (st == GLIMS_STATUS_NOT_FOUND, "foreign NOT_FOUND");
          CHECK (outbuf[0] == 0, "foreign out all zero");
        }
      }

    /* group. */
    if (grp != 0)
      {
        src_group[0] = grp;
        {
          char *e = NULL;
          outbuf[0]=0xAAAAAAAA; outbuf[1]=0xBBBBBBBB; outbuf[2]=0xCCCCCCCC; outbuf[3]=0xDDDDDDDD;
          GlimsStatus st = checked_duplicate (engine, image, src_group, 1, outbuf, &e);
          clear_error (&e);
          CHECK (st == GLIMS_STATUS_UNSUPPORTED, "group UNSUPPORTED");
          CHECK (outbuf[0] == 0, "group out all zero");
        }
      }

    (void) 0;
  }

done:
  extra_public_cases ();
  if (other_image) api->image_close (engine, other_image);
  if (image) api->image_close (engine, image);
  api->stop (engine);
  dlclose (library);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures != 0;
}
