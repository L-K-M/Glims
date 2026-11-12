/* Syscall boundary tests. Only the transaction TU receives syscall aliases;
 * these wrappers and fixture helpers always call the real POSIX functions. */
#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif
#include "cmyk-psd-file.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

enum Fault {
  NONE, SYNC_ERROR, CLOSE_ERROR, CLOSE_INTERRUPTED, RENAME_ERROR, MODE_ERROR,
  SHORT_INTERRUPTED_WRITE, ZERO_WRITE, SYNC_AND_UNLINK_ERROR,
  READ_AND_UNLINK_ERROR, POSTCOMMIT_CLOSE_ERROR, INTERRUPTED_SYNC, FAULT_COUNT
};
static const char *const names[] = {
  "baseline", "fsync EIO", "output close EIO", "output close EINTR",
  "rename EACCES", "chmod EPERM", "short writes and EINTR", "zero write",
  "fsync EIO then unlink EACCES", "read failure then unlink EACCES",
  "directory close after commit", "fsync EINTR recovery"
};
static const unsigned char sentinel[] = "original destination contents";
static unsigned checks, failures;
static const char *case_name;
#define CHECK(c) do { ++checks; if (!(c)) { ++failures; \
  fprintf(stderr, "FAIL %s line %d: %s\n", case_name, __LINE__, #c); } } while (0)
#define REQUIRE(c) do { bool passed_ = (c); CHECK(passed_); \
  if (!passed_) goto cleanup; } while (0)

static struct {
  enum Fault fault;
  char dir[PATH_MAX], path[PATH_MAX];
  dev_t dir_dev, temp_dev;
  ino_t dir_ino, temp_ino;
  bool temp_known, primary_failed, committed, output_closed, harness_error;
  bool after_failure, close_fired, sync_fired, mode_fired, rename_fired;
  bool unlink_fired, zero_fired, directory_close_fired;
  unsigned writes, syncs, closes, renames, modes, unlinks;
  unsigned short_writes, write_interruptions, sync_interruptions, canary_retries;
  int canary_fd;
} g;

static bool join(char *out, size_t capacity, const char *dir, const char *name)
{
  int n = snprintf(out, capacity, "%s/%s", dir, name);
  return n >= 0 && (size_t)n < capacity;
}

static bool same_directory(int fd)
{
  struct stat s;
  return fstat(fd, &s) == 0 && S_ISDIR(s.st_mode) &&
         s.st_dev == g.dir_dev && s.st_ino == g.dir_ino;
}

/* Identify the stage by actual inode membership in our private directory,
 * excluding the named sentinel. No syscall ordinal or random-name assumption. */
static bool stage_fd(int fd)
{
  struct stat s;
  if (fstat(fd, &s) != 0 || !S_ISREG(s.st_mode)) return false;
  if (g.temp_known) return s.st_dev == g.temp_dev && s.st_ino == g.temp_ino;
  DIR *d = opendir(g.dir);
  if (!d) { g.harness_error = true; return false; }
  bool found = false;
  struct dirent *e;
  while ((e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..") ||
        !strcmp(e->d_name, "out.psd")) continue;
    struct stat entry;
    if (fstatat(dirfd(d), e->d_name, &entry, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(entry.st_mode) && entry.st_dev == s.st_dev && entry.st_ino == s.st_ino) {
      found = true;
      break;
    }
  }
  if (closedir(d) != 0) g.harness_error = true;
  if (found) {
    g.temp_known = true;
    g.temp_dev = s.st_dev;
    g.temp_ino = s.st_ino;
  }
  return found;
}

static bool stage_at(int fd, const char *path)
{
  struct stat s;
  return same_directory(fd) && g.temp_known &&
         fstatat(fd, path, &s, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(s.st_mode) &&
         s.st_dev == g.temp_dev && s.st_ino == g.temp_ino;
}

int glims_test_fsync(int fd)
{
  if (stage_fd(fd)) {
    ++g.syncs;
    if (g.primary_failed) g.after_failure = true;
    if (g.fault == SYNC_ERROR || g.fault == SYNC_AND_UNLINK_ERROR) {
      g.sync_fired = g.primary_failed = true;
      errno = EIO;
      return -1;
    }
    if (g.fault == INTERRUPTED_SYNC && !g.sync_interruptions) {
      ++g.sync_interruptions;
      errno = EINTR;
      return -1;
    }
  }
  return fsync(fd);
}

int glims_test_close(int fd)
{
  if (fd == g.canary_fd) {
    ++g.canary_retries;
    return close(fd);
  }
  if (stage_fd(fd)) {
    ++g.closes;
    int result = close(fd);
    if (result != 0) g.harness_error = true;
    g.output_closed = result == 0;
    if (g.fault == CLOSE_ERROR || g.fault == CLOSE_INTERRUPTED) {
      g.close_fired = g.primary_failed = true;
      int replacement = open("/dev/null", O_RDWR | O_CLOEXEC);
      if (replacement < 0) g.harness_error = true;
      else {
        if (replacement != fd) {
          if (dup2(replacement, fd) < 0) g.harness_error = true;
          if (close(replacement) != 0) g.harness_error = true;
        }
        g.canary_fd = fd;
      }
      errno = g.fault == CLOSE_INTERRUPTED ? EINTR : EIO;
      return -1;
    }
    return result;
  }
  if (same_directory(fd) && g.committed && g.fault == POSTCOMMIT_CLOSE_ERROR) {
    g.directory_close_fired = true;
    if (close(fd) != 0) g.harness_error = true;
    errno = EIO;
    return -1;
  }
  return close(fd);
}

int glims_test_renameat(int from_fd, const char *from, int to_fd, const char *to)
{
  if (stage_at(from_fd, from) && same_directory(to_fd)) {
    ++g.renames;
    if (g.primary_failed || !g.output_closed) g.after_failure = true;
    if (g.fault == RENAME_ERROR) {
      g.rename_fired = g.primary_failed = true;
      errno = EACCES;
      return -1;
    }
    int result = renameat(from_fd, from, to_fd, to);
    if (result == 0) g.committed = true;
    return result;
  }
  g.harness_error = true;
  return renameat(from_fd, from, to_fd, to);
}

int glims_test_fchmod(int fd, mode_t mode)
{
  if (stage_fd(fd)) {
    ++g.modes;
    if (g.primary_failed) g.after_failure = true;
    if (g.fault == MODE_ERROR) {
      g.mode_fired = g.primary_failed = true;
      errno = EPERM;
      return -1;
    }
  }
  return fchmod(fd, mode);
}

ssize_t glims_test_write(int fd, const void *bytes, size_t count)
{
  if (stage_fd(fd)) {
    ++g.writes;
    if (g.primary_failed) g.after_failure = true;
    if (g.fault == ZERO_WRITE) {
      g.zero_fired = g.primary_failed = true;
      return 0;
    }
    if (g.fault == SHORT_INTERRUPTED_WRITE) {
      if (!g.write_interruptions) {
        ++g.write_interruptions;
        errno = EINTR;
        return -1;
      }
      if (count > 1) {
        ++g.short_writes;
        return write(fd, bytes, count / 2);
      }
    }
  }
  return write(fd, bytes, count);
}

int glims_test_unlinkat(int fd, const char *path, int flags)
{
  if (stage_at(fd, path)) {
    ++g.unlinks;
    if (g.fault == SYNC_AND_UNLINK_ERROR || g.fault == READ_AND_UNLINK_ERROR) {
      g.unlink_fired = true;
      errno = EACCES;
      return -1;
    }
  } else g.harness_error = true;
  return unlinkat(fd, path, flags);
}

static bool file_equals(const char *path, const void *expected, size_t length)
{
  struct stat s;
  if (lstat(path, &s) != 0 || !S_ISREG(s.st_mode) || s.st_size != (off_t)length)
    return false;
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return false;
  unsigned char bytes[1024];
  bool good = length <= sizeof bytes;
  size_t done = 0;
  while (good && done < length) {
    ssize_t n = read(fd, bytes + done, length - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) good = false;
    else done += (size_t)n;
  }
  if (close(fd) != 0) good = false;
  return good && memcmp(bytes, expected, length) == 0;
}

static bool write_sentinel(void)
{
  int fd = open(g.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0640);
  if (fd < 0) return false;
  size_t done = 0;
  bool good = true;
  while (done < sizeof sentinel) {
    ssize_t n = write(fd, sentinel + done, sizeof sentinel - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) { good = false; break; }
    done += (size_t)n;
  }
  if (close(fd) != 0) good = false;
  return good;
}

struct Source {
  GlimsCmykPsdSpec spec;
  bool watch, failed, bad, after_failure, changed;
  unsigned reads, proceeds;
  uint64_t samples;
};

static bool observe(struct Source *s)
{
  if (!s->watch) return true;
  if (g.committed || g.primary_failed || s->failed) s->after_failure = true;
  if (!file_equals(g.path, sentinel, sizeof sentinel)) s->changed = true;
  return !s->after_failure && !s->changed;
}

static bool source_read(void *context, uint32_t channel, uint32_t y,
                        uint32_t x, uint32_t count, void *samples)
{
  struct Source *s = context;
  ++s->reads;
  if (!observe(s)) return false;
  if (!samples || channel >= 4 || y >= s->spec.height || x >= s->spec.width ||
      !count || count > GLIMS_CMYK_PSD_CHUNK_SAMPLES || count > s->spec.width - x ||
      ((uint64_t)channel * s->spec.height + y) * s->spec.width + x != s->samples ||
      (s->spec.depth == 16 && (uintptr_t)samples % _Alignof(uint16_t))) {
    s->bad = true;
    return false;
  }
  if (s->watch && g.fault == READ_AND_UNLINK_ERROR) {
    s->failed = g.primary_failed = true;
    return false;
  }
  for (uint32_t i = 0; i < count; ++i) {
    unsigned value = channel * 1337 + y * 101 + x + i;
    if (s->spec.depth == 8) ((uint8_t *)samples)[i] = (uint8_t)value;
    else ((uint16_t *)samples)[i] = (uint16_t)value;
  }
  s->samples += count;
  return true;
}

static bool proceed(void *context)
{
  struct Source *s = context;
  ++s->proceeds;
  return observe(s);
}

struct Output { unsigned char bytes[1024]; size_t size; };
static bool collect(void *context, const uint8_t *bytes, size_t count)
{
  struct Output *o = context;
  if (count > sizeof o->bytes - o->size) return false;
  memcpy(o->bytes + o->size, bytes, count);
  o->size += count;
  return true;
}

/* Check all directory entries, including nonregular surprises, then remove only
 * this private fixture's entries. Also used on setup/assertion failure. */
static int entries(bool remove_entries)
{
  DIR *d = opendir(g.dir);
  if (!d) return -1;
  int count = 0;
  struct dirent *e;
  while ((e = readdir(d))) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    ++count;
    struct stat s;
    bool regular = fstatat(dirfd(d), e->d_name, &s, AT_SYMLINK_NOFOLLOW) == 0 &&
                   S_ISREG(s.st_mode);
    CHECK(regular);
    if (regular && strcmp(e->d_name, "out.psd"))
      CHECK(g.temp_known && s.st_dev == g.temp_dev && s.st_ino == g.temp_ino);
    if (remove_entries) CHECK(unlinkat(dirfd(d), e->d_name, 0) == 0);
  }
  CHECK(closedir(d) == 0);
  return count;
}

static void run_case(const char *root, enum Fault fault, uint16_t depth)
{
  memset(&g, 0, sizeof g);
  g.fault = fault;
  g.canary_fd = -1;
  case_name = names[fault];
  char name[64];
  (void)snprintf(name, sizeof name, "%u-%u", (unsigned)fault, depth);
  bool created = false;
  REQUIRE(join(g.dir, sizeof g.dir, root, name));
  REQUIRE(mkdir(g.dir, 0700) == 0);
  created = true;
  REQUIRE(join(g.path, sizeof g.path, g.dir, "out.psd"));
  struct stat dir;
  REQUIRE(stat(g.dir, &dir) == 0);
  g.dir_dev = dir.st_dev;
  g.dir_ino = dir.st_ino;
  REQUIRE(write_sentinel());

  uint8_t icc[128] = {0};
  icc[3] = 128;
  memcpy(icc + 12, "prtr", 4);
  memcpy(icc + 16, "CMYK", 4);
  memcpy(icc + 36, "acsp", 4);
  GlimsCmykPsdSpec spec = {13, 3, depth, icc, sizeof icc};
  struct Source reference = {.spec = spec};
  struct Output expected = {{0}, 0};
  REQUIRE(glims_cmyk_psd_write(&spec, source_read, &reference, collect, &expected) ==
          GLIMS_CMYK_PSD_OK);
  REQUIRE(expected.size == 52 + sizeof icc + 4 * 13 * 3 * (depth / 8));
  struct Source source = {.spec = spec, .watch = true};
  int os_error = -1;
  GlimsCmykPsdFileStatus status = glims_cmyk_psd_write_file(
    &spec, source_read, &source, g.path, proceed, &source, &os_error);
  bool success = fault == NONE || fault == SHORT_INTERRUPTED_WRITE ||
                 fault == POSTCOMMIT_CLOSE_ERROR || fault == INTERRUPTED_SYNC;
  CHECK(status == (success ? GLIMS_CMYK_PSD_FILE_OK : fault == READ_AND_UNLINK_ERROR ?
                   GLIMS_CMYK_PSD_FILE_READ_FAILED : GLIMS_CMYK_PSD_FILE_IO_FAILED));
  int wanted_error = success ? 0 : fault == MODE_ERROR ? EPERM :
    fault == CLOSE_INTERRUPTED ? EINTR :
    (fault == RENAME_ERROR || fault == READ_AND_UNLINK_ERROR) ? EACCES : EIO;
  CHECK(os_error == wanted_error);
  CHECK(g.temp_known && g.writes > 0 && g.closes == 1);
  CHECK(!g.harness_error && !g.after_failure);
  CHECK(!source.bad && !source.changed && !source.after_failure);
  CHECK(source.proceeds > 0);
  CHECK(g.committed == success);
  CHECK(g.output_closed);
  CHECK(g.renames == (success || fault == RENAME_ERROR ? 1u : 0u));
  CHECK(file_equals(g.path, success ? expected.bytes : sentinel,
                    success ? expected.size : sizeof sentinel));
  CHECK(entries(false) == ((fault == SYNC_AND_UNLINK_ERROR ||
                            fault == READ_AND_UNLINK_ERROR) ? 2 : 1));
  CHECK(g.unlinks == (success ? 0u : 1u));
  if (success) CHECK(source.samples == 4 * 13 * 3);
  switch (fault) {
    case SYNC_ERROR: case SYNC_AND_UNLINK_ERROR:
      CHECK(g.sync_fired && g.syncs == 1); break;
    case CLOSE_ERROR: case CLOSE_INTERRUPTED:
      CHECK(g.close_fired && g.canary_fd >= 0);
      CHECK(g.canary_retries == 0);
      CHECK(g.canary_fd >= 0 && fcntl(g.canary_fd, F_GETFD) >= 0); break;
    case RENAME_ERROR: CHECK(g.rename_fired); break;
    case MODE_ERROR: CHECK(g.mode_fired && g.syncs == 0); break;
    case SHORT_INTERRUPTED_WRITE:
      CHECK(g.short_writes > 1 && g.write_interruptions == 1); break;
    case ZERO_WRITE:
      CHECK(g.zero_fired && g.writes == 1 && source.reads == 0 && g.modes == 0 && g.syncs == 0); break;
    case READ_AND_UNLINK_ERROR:
      CHECK(source.failed && source.reads == 1 && g.modes == 0 && g.syncs == 0); break;
    case POSTCOMMIT_CLOSE_ERROR: CHECK(g.directory_close_fired); break;
    case INTERRUPTED_SYNC: CHECK(g.sync_interruptions == 1 && g.syncs == 2); break;
    case NONE: break;
    case FAULT_COUNT: CHECK(false); break;
  }
  if (fault == SYNC_AND_UNLINK_ERROR || fault == READ_AND_UNLINK_ERROR)
    CHECK(g.unlink_fired);
cleanup:
  if (g.canary_fd >= 0) {
    if (fcntl(g.canary_fd, F_GETFD) >= 0) CHECK(close(g.canary_fd) == 0);
    g.canary_fd = -1;
  }
  if (created) {
    CHECK(entries(true) >= 0);
    CHECK(rmdir(g.dir) == 0);
  }
}

int main(void)
{
  char root[] = "/tmp/glims-cmyk-psd-faults.XXXXXX";
  case_name = "setup";
  if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
  for (unsigned depth = 8; depth <= 16; depth += 8)
    for (enum Fault fault = NONE; fault < FAULT_COUNT; ++fault)
      run_case(root, fault, (uint16_t)depth);
  case_name = "cleanup";
  CHECK(rmdir(root) == 0);
  printf("CMYK PSD file faults: %u checks, %u failures (%u scenarios)\n",
         checks, failures, 2u * FAULT_COUNT);
  return failures ? 1 : 0;
}
