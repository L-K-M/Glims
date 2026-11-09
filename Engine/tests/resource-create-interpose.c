/* Test-only deterministic interposer for the resource_create_pixels fault
 * tests (scripts/test-resource-create.py inserts this dylib through
 * DYLD_INSERT_LIBRARIES before the harness starts the engine).
 *
 * It arms ONLY through the exported glims_test_arm() control, which the
 * harness calls after the engine has started and immediately around ONE
 * resource_create_pixels call, disarming right after. While armed it:
 *
 *   - g_uuid_string_random() returns a deterministic owned copy of the
 *     armed UUID, so the adapter's staging directory
 *     (<save_dir>/.glims-stage-<uuid>) and final file
 *     (<save_dir>/<uuid><ext>) have harness-known names;
 *   - g_file_make_directory() and g_file_move() are recorded and checked
 *     against exactly those expected paths, and forwarded untouched.
 *
 * While disarmed every interposed function forwards to the original with
 * no recording and no behavior change, so startup uuid/mkdir/file
 * operations are never reinjected. dyld does not interpose references
 * originating in this replacement image, so the forward calls below reach
 * the original implementations.
 *
 * The shim never deletes, moves or writes anything itself: the cleanup
 * ownership defects under test happen in the adapter, and the oracle is
 * the sentinel filesystem state the harness checks afterwards. All state
 * is owned copies (g_strdup) of the arm arguments and of observed paths;
 * no pointer into caller/request storage is retained. The glims_test_*
 * accessors exist so the harness can fail closed when an export is
 * missing or a hook did not fire as expected.
 */
#include <gio/gio.h>
#include <string.h>

/* Test-control API prototypes (the producer's compile flags include
 * -Wmissing-declarations, and the shim is built with -Werror). */
void        glims_test_arm (const char *uuid, const char *save_dir, const char *extension);
void        glims_test_disarm (void);
void        glims_test_reset (void);
unsigned    glims_test_uuid_calls (void);
unsigned    glims_test_uuid_replaced (void);
unsigned    glims_test_mkdir_calls (void);
unsigned    glims_test_move_calls (void);
unsigned    glims_test_path_mismatch (void);
int         glims_test_last_move_succeeded (void);
int         glims_test_armed (void);
const char *glims_test_last_uuid (void);
const char *glims_test_last_mkdir_path (void);
const char *glims_test_last_move_src (void);
const char *glims_test_last_move_dst (void);
const char *glims_test_expected_staging (void);
const char *glims_test_expected_final (void);

/* ---- Armed state (owned copies only) --------------------------------- */

static gchar   *armed_uuid            = NULL; /* deterministic uuid to hand out */
static gchar   *armed_parent          = NULL; /* expected save dir, no trailing '/' */
static gchar   *expected_staging      = NULL; /* <parent>/.glims-stage-<uuid> */
static gchar   *expected_staging_file = NULL; /* <staging>/staging<ext> */
static gchar   *expected_final        = NULL; /* <parent>/<uuid><ext> */

/* ---- Oracle counters and last observed values ------------------------ */

static unsigned uuid_calls      = 0; /* every g_uuid_string_random seen */
static unsigned uuid_replaced   = 0; /* armed replacements handed out */
static unsigned mkdir_calls     = 0; /* armed g_file_make_directory calls */
static unsigned move_calls      = 0; /* armed g_file_move calls */
static unsigned path_mismatch   = 0; /* armed paths outside the expected set */
static int      last_move_ok    = -1; /* result of the last armed move; -1 none */

static gchar   *last_uuid      = NULL; /* owned copies; never caller storage */
static gchar   *last_mkdir     = NULL;
static gchar   *last_move_src  = NULL;
static gchar   *last_move_dst  = NULL;

/* ---- Test-control API (exported; resolved by the harness with dlsym) -- */

void
glims_test_disarm (void)
{
  g_free (armed_uuid);            armed_uuid            = NULL;
  g_free (armed_parent);          armed_parent          = NULL;
  g_free (expected_staging);      expected_staging      = NULL;
  g_free (expected_staging_file); expected_staging_file = NULL;
  g_free (expected_final);        expected_final        = NULL;
}

void
glims_test_arm (const char *uuid, const char *save_dir, const char *extension)
{
  glims_test_disarm ();

  armed_uuid       = g_strdup (uuid);
  armed_parent     = g_strdup (save_dir);
  expected_staging = g_strdup_printf ("%s/.glims-stage-%s", save_dir, uuid);
  expected_staging_file = g_strdup_printf ("%s/staging%s", expected_staging, extension);
  expected_final   = g_strdup_printf ("%s/%s%s", save_dir, uuid, extension);
}

void
glims_test_reset (void)
{
  glims_test_disarm ();
  uuid_calls = uuid_replaced = mkdir_calls = move_calls = path_mismatch = 0;
  last_move_ok = -1;
  g_free (last_uuid);     last_uuid     = NULL;
  g_free (last_mkdir);    last_mkdir    = NULL;
  g_free (last_move_src); last_move_src = NULL;
  g_free (last_move_dst); last_move_dst = NULL;
}

unsigned    glims_test_uuid_calls (void)        { return uuid_calls; }
unsigned    glims_test_uuid_replaced (void)     { return uuid_replaced; }
unsigned    glims_test_mkdir_calls (void)       { return mkdir_calls; }
unsigned    glims_test_move_calls (void)        { return move_calls; }
unsigned    glims_test_path_mismatch (void)     { return path_mismatch; }
int         glims_test_last_move_succeeded (void) { return last_move_ok; }
int         glims_test_armed (void)             { return armed_uuid != NULL; }

/* Returned strings are owned by the shim and valid until the next
 * glims_test_arm/disarm/reset; callers must not free them. */
const char *glims_test_last_uuid (void)     { return last_uuid; }
const char *glims_test_last_mkdir_path (void)  { return last_mkdir; }
const char *glims_test_last_move_src (void)    { return last_move_src; }
const char *glims_test_last_move_dst (void)    { return last_move_dst; }
const char *glims_test_expected_staging (void) { return expected_staging; }
const char *glims_test_expected_final (void)   { return expected_final; }

/* ---- Interposed replacements ------------------------------------------ */

static gchar *
replacement_g_uuid_string_random (void)
{
  uuid_calls++;

  if (armed_uuid)
    {
      uuid_replaced++;
      g_free (last_uuid);
      last_uuid = g_strdup (armed_uuid);
      /* Owned by the caller, exactly like the original's result. */
      return g_strdup (armed_uuid);
    }

  return g_uuid_string_random ();
}

static gboolean
replacement_g_file_make_directory (GFile *file, GCancellable *cancellable, GError **error)
{
  if (armed_parent)
    {
      gchar *path = g_file_get_path (file);

      /* choose_save_dir() may call make_directory_with_parents() on the
       * already-existing save folder. Some GIO builds route that through
       * this symbol too. It is not the staging mkdir under test. */
      if (path && strcmp (path, armed_parent) == 0)
        {
          g_free (path);
          return g_file_make_directory (file, cancellable, error);
        }

      mkdir_calls++;
      g_free (last_mkdir);
      last_mkdir = g_strdup (path);

      /* Fail closed on any armed mkdir that is not exactly the expected
       * staging directory under the harness-supplied parent. */
      if (! path || ! expected_staging || strcmp (path, expected_staging) != 0)
        path_mismatch++;

      g_free (path);
    }

  return g_file_make_directory (file, cancellable, error);
}

static gboolean
replacement_g_file_move (GFile                *source,
                         GFile                *destination,
                         GFileCopyFlags        flags,
                         GCancellable         *cancellable,
                         GFileProgressCallback progress_callback,
                         gpointer              progress_callback_data,
                         GError              **error)
{
  gboolean ok;

  if (armed_parent)
    {
      gchar *src = g_file_get_path (source);
      gchar *dst = g_file_get_path (destination);

      move_calls++;
      g_free (last_move_src);
      g_free (last_move_dst);
      last_move_src = g_strdup (src);
      last_move_dst = g_strdup (dst);

      /* Fail closed unless this is exactly the staged-to-final promotion
       * the harness predicted under the isolated save dir. */
      if (! src || ! dst || ! expected_staging_file || ! expected_final ||
          strcmp (src, expected_staging_file) != 0 ||
          strcmp (dst, expected_final) != 0)
        path_mismatch++;

      ok = g_file_move (source, destination, flags, cancellable,
                        progress_callback, progress_callback_data, error);
      last_move_ok = ok ? 1 : 0;

      g_free (src);
      g_free (dst);

      return ok;
    }

  return g_file_move (source, destination, flags, cancellable,
                      progress_callback, progress_callback_data, error);
}

/* dyld does not interpose references originating in this replacement
 * image; the forward calls above reach the original implementations. */
#define INTERPOSE(replacement, original) \
  __attribute__((used, section("__DATA,__interpose"))) \
  static const struct { const void *replacement_address; const void *original_address; } \
  interpose_##original = { (const void *)&replacement, (const void *)&original }

INTERPOSE (replacement_g_uuid_string_random, g_uuid_string_random);
INTERPOSE (replacement_g_file_make_directory, g_file_make_directory);
INTERPOSE (replacement_g_file_move, g_file_move);
