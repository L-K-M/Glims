/* Separate macOS packaging helper, never linked into the adapter. */
#include <CoreText/CoreText.h>
#include <fontconfig/fontconfig.h>
#include <harfbuzz/hb.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void
write_xml_text (FILE *file, const char *text)
{
  for (; *text; text++)
    switch (*text)
      {
      case '&': fputs ("&amp;", file); break;
      case '<': fputs ("&lt;", file); break;
      case '>': fputs ("&gt;", file); break;
      default: fputc (*text, file); break;
      }
}

/* MacPorts' default fonts.conf scans all of Assets/AssetsV2 recursively,
 * including speech models and other non-font data. CoreText identifies the
 * installed font assets without that traversal. Keep ordinary font roots
 * and user configuration; add the asset font directories explicitly. */
static int
write_runtime_config (const char *base, const char *destination)
{
  CFArrayRef urls = CTFontManagerCopyAvailableFontURLs ();
  CFMutableSetRef directories = CFSetCreateMutable (NULL, 0, &kCFTypeSetCallBacks);
  if (! urls || ! directories)
    {
      if (urls) CFRelease (urls);
      if (directories) CFRelease (directories);
      return 0;
    }
  char *temporary = NULL;
  if (asprintf (&temporary, "%s.XXXXXX", destination) < 0)
    { CFRelease (urls); CFRelease (directories); return 0; }
  int fd = mkstemp (temporary);
  FILE *file = fd >= 0 ? fdopen (fd, "w") : NULL;
  if (! file)
    {
      if (fd >= 0) close (fd);
      unlink (temporary);
      free (temporary);
      CFRelease (urls);
      CFRelease (directories);
      return 0;
    }
  fputs ("<?xml version=\"1.0\"?>\n<fontconfig>\n<include>", file);
  write_xml_text (file, base);
  fputs ("</include>\n<selectfont><acceptfont>\n", file);
  for (CFIndex i = 0; i < CFArrayGetCount (urls); i++)
    {
      CFURLRef url = CFArrayGetValueAtIndex (urls, i);
      CFURLRef parent = CFURLCreateCopyDeletingLastPathComponent (NULL, url);
      char path[PATH_MAX];
      if (parent && CFURLGetFileSystemRepresentation (parent, true,
                                                      (UInt8 *) path, sizeof path) &&
          (strncmp (path, "/System/Library/Assets/", 23) == 0 ||
           strncmp (path, "/System/Library/AssetsV2/", 25) == 0) &&
          ! CFSetContainsValue (directories, parent))
        {
          CFSetAddValue (directories, parent);
          fputs ("<glob>", file); write_xml_text (file, path); fputs ("</glob><glob>", file);
          write_xml_text (file, path); fputs ("/*</glob>\n", file);
        }
      if (parent) CFRelease (parent);
    }
  fputs ("</acceptfont></selectfont>\n", file);
  CFIndex count = CFSetGetCount (directories);
  const void **values = count ? calloc ((size_t) count, sizeof *values) : NULL;
  int ok = count == 0 || values != NULL;
  if (values)
    {
      CFSetGetValues (directories, values);
      for (CFIndex i = 0; i < count; i++)
        {
          char path[PATH_MAX];
          if (! CFURLGetFileSystemRepresentation (values[i], true, (UInt8 *) path, sizeof path))
            { ok = 0; break; }
          fputs ("<dir>", file); write_xml_text (file, path); fputs ("</dir>\n", file);
        }
      free (values);
    }
  fputs ("</fontconfig>\n", file);
  if (ferror (file)) ok = 0;
  if (fclose (file) != 0) ok = 0;
  if (ok && rename (temporary, destination) != 0) ok = 0;
  if (! ok) unlink (temporary);
  free (temporary);
  CFRelease (directories);
  CFRelease (urls);
  return ok;
}

int
main (int argc, char **argv)
{
  if (argc != 3) return 2;
  if (access (argv[1], R_OK) != 0 || ! write_runtime_config (argv[1], argv[2]))
    return 1;
  /* FreeType resolves HarfBuzz through RTLD_DEFAULT. Link the bundled
   * library explicitly so it cannot dlopen its compiled-in build path. */
  if (! hb_version_string ()) return 1;
  FcConfig *config = FcConfigCreate ();
  if (! config) return 1;
  int ok = FcConfigParseAndLoad (config, (const FcChar8 *) argv[2], FcTrue) &&
           FcConfigBuildFonts (config);
  FcConfigDestroy (config);
  FcFini ();
  return ok ? 0 : 1;
}
