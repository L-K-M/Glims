/* A fresh native user directory exercises migration, unlike conformance's
 * preinstalled fixture plug-ins. Run each SNAP state in a separate process. */
#include "glims_engine.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef void (*LogFunction) (const char *, unsigned int, const char *, void *);
typedef unsigned int (*SetLogHandler) (const char *, unsigned int, LogFunction, void *);
typedef void (*RemoveLogHandler) (const char *, unsigned int);

static atomic_uint critical_count;
static unsigned int failures;

static void
check (int condition, const char *message)
{
  printf ("%s %s\n", condition ? "ok  " : "FAIL", message);
  if (! condition)
    failures++;
  fflush (stdout);
}

static void
capture_critical (const char *domain, unsigned int level,
                  const char *message, void *context)
{
  (void) level;
  (void) context;
  atomic_fetch_add (&critical_count, 1);
  /* Keep every diagnostic visible while recording it for the assertion. */
  fprintf (stderr, "%s-CRITICAL: %s\n", domain ? domain : "GLib",
           message ? message : "(no message)");
}

static int
snap_matches (const char *expected)
{
  const char *actual = getenv ("SNAP");
  return expected ? actual && strcmp (actual, expected) == 0 : actual == NULL;
}

int
main (int argc, char **argv)
{
  if (argc != 5)
    {
      fprintf (stderr, "usage: %s LIBRARY USER_DIRECTORY CACHE_DIRECTORY CASE\n", argv[0]);
      return 2;
    }

  const char *snap = getenv ("SNAP");
  char *expected = snap ? strdup (snap) : NULL;
  if (snap && ! expected)
    return 2;
  int valid_case = (strcmp (argv[4], "absent") == 0 && snap == NULL) ||
                   (strcmp (argv[4], "empty") == 0 && snap && *snap == '\0') ||
                   (strcmp (argv[4], "present") == 0 && snap && *snap != '\0');
  check (valid_case, "requested SNAP input state is present exactly");
  struct stat info;
  errno = 0;
  check (lstat (argv[2], &info) == -1 && errno == ENOENT,
         "fresh config directory does not exist before start");
  if (failures)
    {
      free (expected);
      return 1;
    }

  void *library = dlopen (argv[1], RTLD_NOW | RTLD_LOCAL);
  if (! library)
    {
      fprintf (stderr, "dlopen: %s\n", dlerror ());
      free (expected);
      return 2;
    }
  GlimsEngineGetAPIFunction get_api = (GlimsEngineGetAPIFunction)
    dlsym (library, "glims_engine_get_api");
  SetLogHandler set_handler = (SetLogHandler) dlsym (library, "g_log_set_handler");
  RemoveLogHandler remove_handler = (RemoveLogHandler) dlsym (library, "g_log_remove_handler");
  const GlimsEngineAPI *api = get_api ? get_api (GLIMS_ENGINE_API_VERSION) : NULL;
  if (! api || api->struct_size < offsetof (GlimsEngineAPI, free_string) + sizeof api->free_string ||
      ! api->start || ! api->stop || ! api->free_string || ! set_handler || ! remove_handler)
    {
      fprintf (stderr, "Missing facade or GLib log capture functions\n");
      free (expected);
      return 2;
    }

  /* G_LOG_LEVEL_CRITICAL | G_LOG_FLAG_FATAL | G_LOG_FLAG_RECURSION. */
  unsigned int handler = set_handler ("GLib", (1u << 3) | (1u << 1) | 1u,
                                     capture_critical, NULL);
  GlimsEngineConfig config = { .struct_size = sizeof config,
                              .user_directory = argv[2],
                              .cache_directory = argv[3] };
  GlimsEngine *engine = NULL;
  char *error = NULL;
  GlimsStatus status = api->start (&config, &engine, &error);
  if (error)
    fprintf (stderr, "engine start: %s\n", error);
  api->free_string (error);
  check (status == GLIMS_STATUS_OK && engine != NULL, "native engine starts successfully");
  check (snap_matches (expected), "SNAP is restored exactly after start");
  check (stat (argv[2], &info) == 0 && S_ISDIR (info.st_mode),
         "native startup creates the missing config directory");
  if (engine)
    api->stop (engine);
  check (snap_matches (expected), "SNAP is unchanged after stop");
  unsigned int count = atomic_load (&critical_count);
  printf ("captured GLib criticals: %u\n", count);
  check (count == 0, "first startup and stop emit no GLib criticals");
  remove_handler ("GLib", handler);
  free (expected);
  /* GObject registrations outlive stop; let process exit unload the engine. */
  printf ("%s (engine first start %s): %u failures\n",
          failures ? "FAILED" : "PASSED", argv[4], failures);
  return failures ? 1 : 0;
}
