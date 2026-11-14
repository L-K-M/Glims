#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#include "bitmap-psd-file.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static unsigned checks, failures;
#define CHECK(condition, label) do { bool ok = (condition); checks++; if (!ok) failures++; \
  printf("%s %s\n", ok ? "ok" : "FAIL", label); } while (0)

typedef struct { bool bad, fail; unsigned calls, cancel_after, progress_calls, cancel_progress_at; } Fixture;
static bool read_pixels(void *context, uint32_t y, uint32_t x, uint32_t count, uint8_t *pixels)
{
  Fixture *f = context;
  f->calls++;
  if (f->fail) return false;
  for (uint32_t i = 0; i < count; i++) pixels[i] = ((x + i + y) % 2) ? 255 : 0;
  if (f->bad && y == 1) pixels[count - 1] = 42;
  return true;
}
static bool proceed(void *context)
{
  Fixture *f = context;
  f->progress_calls++;
  return (!f->cancel_after || f->calls < f->cancel_after) &&
         (!f->cancel_progress_at || f->progress_calls < f->cancel_progress_at);
}
static bool content_is(const char *path, const char *expected)
{
  char buffer[64]; FILE *f = fopen(path, "rb");
  if (!f) return false;
  size_t n = fread(buffer, 1, sizeof buffer, f); bool error = ferror(f) != 0; fclose(f);
  return !error && n == strlen(expected) && memcmp(buffer, expected, n) == 0;
}
static bool no_temporary(const char *dir)
{
  DIR *d = opendir(dir); if (!d) return false; bool clean = true; struct dirent *entry;
  while ((entry = readdir(d)))
    if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..") &&
        strcmp(entry->d_name, "output.psd") && strcmp(entry->d_name, "link.psd")) clean = false;
  closedir(d); return clean;
}
int main(void)
{
  char folder[] = "/tmp/glims-bitmap-file-XXXXXX";
  if (!mkdtemp(folder)) return 2;
  char path[256], link[256];
  snprintf(path, sizeof path, "%s/output.psd", folder);
  snprintf(link, sizeof link, "%s/link.psd", folder);
  FILE *f = fopen(path, "wb"); if (!f) return 2;
  if (fwrite("original", 1, 8, f) != 8 || fclose(f)) return 2;
  if (chmod(path, 0640)) return 2;
  GlimsBitmapPsdSpec spec = {9,2}; Fixture fixture = {0}; int err = 99;
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, NULL, NULL, NULL, &err) == GLIMS_BITMAP_PSD_FILE_INVALID &&
        err == 0 && fixture.calls == 0 && content_is(path,"original"), "null path is refused before reading pixels");
  fixture.bad = true;
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, path, NULL, NULL, &err) == GLIMS_BITMAP_PSD_FILE_INVALID_PIXEL &&
        content_is(path,"original") && no_temporary(folder), "nonbinary late pixel preserves existing target");
  fixture = (Fixture){.fail=true};
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, path, NULL, NULL, &err) == GLIMS_BITMAP_PSD_FILE_READ_FAILED &&
        content_is(path,"original") && no_temporary(folder), "source failure preserves existing target");
  fixture = (Fixture){.cancel_after=1};
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, path, proceed, &fixture, &err) == GLIMS_BITMAP_PSD_FILE_CANCELLED &&
        content_is(path,"original") && no_temporary(folder), "cancellation preserves existing target");
  if (symlink(path, link)) return 2;
  fixture = (Fixture){0};
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, link, NULL, NULL, &err) == GLIMS_BITMAP_PSD_FILE_INVALID &&
        content_is(path,"original") && fixture.calls == 0 && no_temporary(folder), "symlink target is refused before reading pixels");
  /* Count every cancellation checkpoint in a successful transaction, then
   * cancel at its last checkpoint, immediately before promotion. */
  fixture = (Fixture){0};
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, path, proceed, &fixture, &err) == GLIMS_BITMAP_PSD_FILE_OK &&
        fixture.progress_calls > 1, "successful transaction reaches its final cancellation checkpoint");
  unsigned final_checkpoint = fixture.progress_calls;
  f = fopen(path, "wb"); if (!f) return 2;
  if (fwrite("original", 1, 8, f) != 8 || fclose(f)) return 2;
  fixture = (Fixture){.cancel_progress_at=final_checkpoint};
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, path, proceed, &fixture, &err) == GLIMS_BITMAP_PSD_FILE_CANCELLED &&
        fixture.progress_calls == final_checkpoint && content_is(path,"original") && no_temporary(folder),
        "cancellation at final checkpoint leaves target intact");
  fixture = (Fixture){0}; err = 99;
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, path, NULL, NULL, &err) == GLIMS_BITMAP_PSD_FILE_OK &&
        err == 0 && no_temporary(folder), "valid image atomically replaces target");
  struct stat st; CHECK(stat(path, &st) == 0 && (st.st_mode & 0777) == 0640 && st.st_size == 44,
                        "replacement preserves permissions and complete size");
  f = fopen(path, "rb"); unsigned char header[26] = {0};
  bool header_ok = f && fread(header, 1, sizeof header, f) == sizeof header;
  if (f) fclose(f);
  CHECK(header_ok && !memcmp(header, "8BPS", 4) && header[13] == 1 && header[23] == 1 && header[25] == 0,
        "published file is one-channel one-bit Bitmap PSD");
  unlink(path);
  fixture = (Fixture){0};
  CHECK(glims_bitmap_psd_write_file(&spec, read_pixels, &fixture, path, NULL, NULL, &err) == GLIMS_BITMAP_PSD_FILE_OK &&
        stat(path, &st) == 0 && (st.st_mode & 0777) == 0600,
        "new destination is created with private permissions");
  unlink(link); unlink(path); rmdir(folder);
  printf("%u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}
