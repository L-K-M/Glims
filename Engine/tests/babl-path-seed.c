/* Seeds a throwaway babl fish cache with legal but lossy conversion paths.
 *
 * Babl accepts any conversion path whose measured error is under its
 * tolerance, picks the fastest by timing, and stores the choice in a fish
 * cache that GIMP and every other babl user under the same HOME share.
 * A loaded test run once refused valid 16-bit Bitmap pixels. The legal
 * path Y'A u16 -> Y'A u32 -> Y'A float reads opaque white with alpha
 * 0.9999998 and reproduces that refusal exactly, and a cached choice
 * repeats on every later run. This tool writes such choices on purpose,
 * so the export tests can run against them every time:
 *
 *   glims-babl-path-seed seed    writes $XDG_CACHE_HOME/babl/babl-fishes
 *   glims-babl-path-seed check   fails unless babl now uses every seeded
 *                                path and each one moves opaque alpha
 *
 * Both refuse to run without XDG_CACHE_HOME, and seed refuses a cache
 * that already holds a fish file, so neither touches a cache in use. */
#include <babl/babl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*GlimsBablEach) (Babl *babl, void *data);
/* Exported by the babl of every engine set, but missing from its header. */
extern void babl_conversion_class_for_each (GlimsBablEach each, void *data);

#define MAX_FORMATS 4

/* Each route stays inside babl's default search: at most three
 * conversions and no format twice. The first reproduces the observed
 * refusal. */
static const char *const routes[][MAX_FORMATS + 1] = {
  { "Y'A u16", "Y'A u32", "Y'A float", NULL },          /* 16-bit Bitmap */
  { "Y'A u8", "Y'A u16", "Y'A u32", "Y'A float", NULL }, /* 8-bit Bitmap and Duotone */
};
#define N_ROUTES (sizeof routes / sizeof routes[0])

typedef struct {
  char wanted[128];
  const char *found;
} Lookup;

static int
find_conversion (Babl *conversion, void *data)
{
  Lookup *lookup = data;
  const char *name = babl_get_name (conversion);
  /* Extension conversions are named "<module> <index>: <from> to <to>". */
  const char *colon = strstr (name, ": ");
  const char *plain = colon ? colon + 2 : name;
  if (!lookup->found && !strcmp (plain, lookup->wanted)) lookup->found = name;
  return 0;
}

static int
fail (const char *message, const char *detail)
{
  fprintf (stderr, "babl-path-seed: %s%s%s\n", message, detail ? ": " : "", detail ? detail : "");
  return 1;
}

static int
cache_path (char *path, size_t size)
{
  const char *cache = getenv ("XDG_CACHE_HOME");
  if (!cache || !*cache) return 0;
  return snprintf (path, size, "%s/babl/babl-fishes", cache) < (int) size;
}

typedef struct {
  char text[8192];
  size_t used;
} Text;

static int
append (Text *text, const char *a, const char *b)
{
  int added = snprintf (text->text + text->used, sizeof text->text - text->used, a, b);
  if (added < 0 || (size_t) added >= sizeof text->text - text->used) return 0;
  text->used += (size_t) added;
  return 1;
}

/* Appends one cache entry per route, naming each conversion as this babl
 * does. pixels stays above 99: babl drops a cached entry whose pixel count
 * equals the current time modulo 100. */
static int
describe_routes (Text *text)
{
  for (size_t r = 0; r < N_ROUTES; r++)
    {
      const char *const *route = routes[r];
      size_t last = 0;
      while (last + 1 < MAX_FORMATS && route[last + 1]) last++;
      if (!append (text, "%s\n", route[0]) || !append (text, "%s\n", route[last]) ||
          !append (text, "%s", "\tpixels=100000000 cost=1 error=0.0000002000\n"))
        return fail ("the seeded cache is too large", NULL);
      for (size_t i = 0; i < last; i++)
        {
          Lookup lookup = { .found = NULL };
          snprintf (lookup.wanted, sizeof lookup.wanted, "%s to %s", route[i], route[i + 1]);
          babl_conversion_class_for_each (find_conversion, &lookup);
          if (!lookup.found) return fail ("babl has no conversion", lookup.wanted);
          if (!append (text, "\t%s\n", lookup.found)) return fail ("the seeded cache is too large", NULL);
        }
      if (!append (text, "%s", "----\n")) return fail ("the seeded cache is too large", NULL);
    }
  return 0;
}

static int
seed (const char *path)
{
  Text text = { .used = 0 };
  char header[1024] = { 0 };
  FILE *file;
  int failed, ok;

  /* A real cache, GIMP's included, already has this file. */
  if (access (path, F_OK) == 0) return fail ("refusing to replace an existing babl cache", path);

  /* babl_exit stores the fish database under the current cache header, so
   * an empty round trip yields the header this babl will accept. */
  babl_init ();
  failed = describe_routes (&text);
  babl_exit ();
  /* babl_exit wrote the file even on failure. Remove it, or the next
   * attempt would refuse it as an existing cache. */
  if (failed)
    {
      unlink (path);
      return failed;
    }

  file = fopen (path, "r");
  ok = file && fgets (header, sizeof header, file) && header[0] == '#';
  if (file) fclose (file);
  if (!ok)
    {
      unlink (path);
      return fail ("babl wrote no cache header to", path);
    }

  file = fopen (path, "w");
  if (!file)
    {
      unlink (path);
      return fail ("cannot write", path);
    }
  ok = fputs (header, file) >= 0 && fputs (text.text, file) >= 0;
  ok = fclose (file) == 0 && ok;
  if (!ok)
    {
      unlink (path);
      return fail ("cannot write", path);
    }
  printf ("babl-path-seed: seeded %zu lossy paths into %s\n", N_ROUTES, path);
  return 0;
}

static int
check (void)
{
  babl_init ();
  for (size_t r = 0; r < N_ROUTES; r++)
    {
      const char *const *route = routes[r];
      size_t last = 0;
      const Babl *from, *to;
      /* Unsigned all-ones is opaque white in every seeded source format. */
      unsigned char white[16];
      float read[4] = { 0 }, alpha;
      while (last + 1 < MAX_FORMATS && route[last + 1]) last++;
      from = babl_format (route[0]);
      to = babl_format (route[last]);
      if (!from || !to) return fail ("babl has no format for route", route[0]);
      memset (white, 0xff, sizeof white);
      babl_process (babl_fish (from, to), white, read, 1);
      alpha = read[babl_format_get_n_components (to) - 1];
      if (alpha == 1.0f) return fail ("babl did not use the seeded path from", route[0]);
      printf ("babl-path-seed: %s -> %s reads opaque white as %a/%a\n", route[0], route[last],
              (double) read[0], (double) alpha);
    }
  /* No babl_exit: it would rewrite the cache this check just verified. */
  return 0;
}

int
main (int argc, char **argv)
{
  char path[4096];
  if (argc != 2 || (strcmp (argv[1], "seed") && strcmp (argv[1], "check")))
    return fail ("usage: glims-babl-path-seed seed|check", NULL);
  if (!cache_path (path, sizeof path))
    return fail ("XDG_CACHE_HOME must name a throwaway cache directory", NULL);
  return !strcmp (argv[1], "seed") ? seed (path) : check ();
}
