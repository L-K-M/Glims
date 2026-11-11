#include "startup-helper.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures;
#define CHECK(condition, label) do { \
  gboolean passed = (condition); \
  printf ("%s: %s\n", passed ? "PASS" : "FAIL", label); \
  if (! passed) failures++; \
} while (0)

static gboolean
unexpected_dispatch (gpointer data)
{
  *(gboolean *) data = TRUE;
  return G_SOURCE_REMOVE;
}

int
main (int argc, char **argv)
{
  if (argc == 2 && ! strcmp (argv[1], "--sleep"))
    {
      gchar *pid = g_strdup_printf ("%d", getpid ());
      if (! g_file_set_contents ("child.pid", pid, -1, NULL)) return 3;
      g_free (pid);
      signal (SIGTERM, SIG_IGN);
      g_usleep (1200000);
      return 0;
    }
  if (argc == 2 && ! strcmp (argv[1], "--success"))
    return g_file_set_contents ("success", "ready", -1, NULL) ? 0 : 3;
  if (argc == 2 && ! strcmp (argv[1], "--failure")) return 7;
  if (argc != 2) return 2;

  const gchar *sleeping[] = { argv[0], "--sleep", NULL };
  const gchar *success[] = { argv[0], "--success", NULL };
  const gchar *failure[] = { argv[0], "--failure", NULL };
  const gchar *missing[] = { "/nonexistent/glims-font-cache", NULL };
  gboolean dispatched = FALSE;
  guint idle = g_idle_add (unexpected_dispatch, &dispatched);
  gint64 began = g_get_monotonic_time ();
  gboolean result = glims_run_startup_helper (argv[1], sleeping, 150);
  gint64 elapsed = g_get_monotonic_time () - began;
  CHECK (! result, "sleeping helper refuses after its deadline");
  CHECK (elapsed < 1000000, "deadline prevents waiting for the child's 1.2-second sleep");
  CHECK (! dispatched, "waiting does not dispatch unrelated default-context work");
  g_source_remove (idle);

  gchar *pid_path = g_build_filename (argv[1], "child.pid", NULL);
  gchar *pid_text = NULL;
  CHECK (g_file_get_contents (pid_path, &pid_text, NULL, NULL), "sleeping helper really launched");
  if (pid_text)
    {
      pid_t child = (pid_t) strtol (pid_text, NULL, 10);
      errno = 0;
      CHECK (child > 0 && kill (child, 0) == -1 && errno == ESRCH, "timed-out helper no longer exists");
      errno = 0;
      CHECK (waitpid (child, NULL, WNOHANG) == -1 && errno == ECHILD, "timed-out helper was reaped");
    }
  CHECK (glims_run_startup_helper (argv[1], success, 1000), "successful helper reports success");
  gchar *marker = g_build_filename (argv[1], "success", NULL);
  CHECK (g_file_test (marker, G_FILE_TEST_IS_REGULAR), "child uses the private working directory");
  CHECK (! glims_run_startup_helper (argv[1], failure, 1000), "nonzero helper exit requests fallback");
  CHECK (! glims_run_startup_helper (argv[1], missing, 1000), "spawn failure requests fallback");
  CHECK (! glims_run_startup_helper ("/nonexistent/glims-work", success, 1000), "invalid working directory requests fallback");
  g_free (marker);
  g_free (pid_path);
  g_free (pid_text);
  return failures ? 1 : 0;
}
