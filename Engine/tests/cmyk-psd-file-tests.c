#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE 1
#endif

#include "cmyk-psd-codec.h"
#include "cmyk-psd-file.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if !defined(PATH_MAX) || PATH_MAX < 256
#define GLIMS_PATH_MAX 1024
#else
#define GLIMS_PATH_MAX PATH_MAX
#endif

static int g_checks;
static int g_failures;
static char g_tmpdir[GLIMS_PATH_MAX];

#define CHECK(cond) do { \
  g_checks++; \
  if (!(cond)) { \
    g_failures++; \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
  } \
} while (0)

#define CHECK_MSG(cond, msg) do { \
  g_checks++; \
  if (!(cond)) { \
    g_failures++; \
    fprintf(stderr, "FAIL %s:%d: %s (%s)\n", __FILE__, __LINE__, #cond, msg); \
  } \
} while (0)

static bool join_path(char *out, size_t cap, const char *a, const char *b) {
  int n = snprintf(out, cap, "%s/%s", a, b);
  return n >= 0 && (size_t)n < cap;
}

static bool write_all_fd(int fd, const void *buf, size_t size) {
  const uint8_t *p = (const uint8_t *)buf;
  while (size > 0) {
    ssize_t n = write(fd, p, size);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (n == 0) { errno = EIO; return false; }
    p += (size_t)n;
    size -= (size_t)n;
  }
  return true;
}

static bool read_file_exact(const char *path, uint8_t *buf, size_t cap, size_t *out_size) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return false;
  size_t total = 0;
  bool ok = true;
  for (;;) {
    uint8_t extra;
    ssize_t n = total == cap ? read(fd, &extra, 1) : read(fd, buf + total, cap - total);
    if (n < 0) { if (errno == EINTR) continue; ok = false; break; }
    if (!n) break;
    if (total == cap) { ok = false; break; }
    total += (size_t)n;
  }
  if (close(fd)) ok = false;
  if (out_size) *out_size = total;
  return ok;
}

static bool write_file_exact(const char *path, const void *buf, size_t size, mode_t mode) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
  if (fd < 0) return false;
  bool ok = write_all_fd(fd, buf, size);
  if (close(fd) != 0) ok = false;
  return ok;
}

static bool files_equal(const char *path, const uint8_t *expect, size_t expect_size) {
  struct stat st;
  if (lstat(path, &st) != 0) return false;
  if (!S_ISREG(st.st_mode) || (uint64_t)st.st_size != expect_size) return false;
  uint8_t *buf = (uint8_t *)malloc(expect_size ? expect_size : 1);
  if (!buf) return false;
  size_t got = 0;
  bool ok = read_file_exact(path, buf, expect_size, &got) && got == expect_size &&
            memcmp(buf, expect, expect_size) == 0;
  free(buf);
  return ok;
}

static bool fd_reads_bytes(int fd, const uint8_t *expect, size_t size) {
  struct stat st;
  if (fstat(fd, &st) || st.st_size < 0 || (uint64_t)st.st_size != size ||
      lseek(fd, 0, SEEK_SET) < 0) return false;
  uint8_t *buf = (uint8_t *)malloc(size ? size : 1);
  if (!buf) return false;
  size_t total = 0;
  while (total < size) {
    ssize_t n = read(fd, buf + total, size - total);
    if (n < 0) { if (errno == EINTR) continue; free(buf); return false; }
    if (n == 0) break;
    total += (size_t)n;
  }
  bool ok = (total == size && memcmp(buf, expect, size) == 0);
  free(buf);
  return ok;
}

static bool dir_has_only(const char *dir, const char *const *allowed, size_t allowed_n) {
  DIR *d = opendir(dir);
  if (!d) return false;
  struct dirent *e;
  bool ok = true;
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    bool found = false;
    for (size_t i = 0; i < allowed_n; i++) {
      if (strcmp(e->d_name, allowed[i]) == 0) { found = true; break; }
    }
    if (!found) { ok = false; break; }
  }
  closedir(d);
  return ok;
}

static bool find_stage(const char *dir, const char *const *allowed, size_t allowed_n,
                       uint64_t expect_size, char *out, size_t out_cap, bool *found) {
  DIR *d = opendir(dir);
  if (!d) return false;
  struct dirent *e;
  bool ok = true;
  *found = false;
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
    bool known = false;
    for (size_t i = 0; i < allowed_n; i++) {
      if (strcmp(e->d_name, allowed[i]) == 0) { known = true; break; }
    }
    if (known) continue;
    char p[GLIMS_PATH_MAX];
    if (!join_path(p, sizeof(p), dir, e->d_name)) { ok = false; break; }
    struct stat st;
    if (lstat(p, &st) != 0) { ok = false; break; }
    if (S_ISREG(st.st_mode) && (uint64_t)st.st_size == expect_size) {
      if (*found) ok = false;
      *found = true;
      if (out && out_cap) {
        int n = snprintf(out, out_cap, "%s", p);
        if (n < 0 || (size_t)n >= out_cap) ok = false;
      }
    }
  }
  closedir(d);
  return ok;
}

static void cleanup_tree(const char *path) {
  struct stat st;
  if (lstat(path, &st) != 0) return;
  if (S_ISDIR(st.st_mode)) {
    DIR *d = opendir(path);
    if (d) {
      struct dirent *e;
      while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char c[GLIMS_PATH_MAX];
        if (join_path(c, sizeof(c), path, e->d_name)) cleanup_tree(c);
      }
      closedir(d);
    }
    rmdir(path);
  } else {
    unlink(path);
  }
}

/* Fixtures below were repaired from the helper draft against the frozen
 * headers, without reading cmyk-psd-file.c. The pure codec is intentionally
 * reused as the byte reference: its independent file-format oracle is separate. */
static const uint8_t sentinel[] = "ORIGINAL FILE: do not replace on failure";
static const char *only_output[] = {"out.psd"};

static bool make_case(const char *name, char *dir, char *path, bool existing) {
  bool ok = join_path(dir, GLIMS_PATH_MAX, g_tmpdir, name) &&
    mkdir(dir, 0700) == 0 && join_path(path, GLIMS_PATH_MAX, dir, "out.psd");
  CHECK_MSG(ok, name);
  if (!ok) return false;
  if (existing) {
    ok = write_file_exact(path, sentinel, sizeof sentinel, 0600) && chmod(path, 0640) == 0;
    CHECK(ok);
  }
  return ok;
}

static void make_icc(uint8_t *icc, size_t size) {
  memset(icc, 0, size);
  icc[0]=(uint8_t)(size>>24); icc[1]=(uint8_t)(size>>16);
  icc[2]=(uint8_t)(size>>8); icc[3]=(uint8_t)size;
  memcpy(icc+12, "prtr", 4); memcpy(icc+16, "CMYK", 4); memcpy(icc+36, "acsp", 4);
  if (size == 129) icc[128] = 0x93;
}

typedef enum { CANCEL_NONE, CANCEL_EARLY, CANCEL_MID, CANCEL_STAGED } CancelMode;
typedef struct {
  const GlimsCmykPsdSpec *spec;
  const char *dir, *path;
  bool existing, watch, stopped, after_stop, destination_changed, bad_request, triggered;
  uint64_t samples, total, file_size;
  size_t reads, proceeds, fail_read, stopped_reads, stopped_proceeds;
  CancelMode cancel;
} Context;

static Context context(const GlimsCmykPsdSpec *spec, const char *dir,
                       const char *path, bool existing) {
  Context c = {0}; c.spec=spec; c.dir=dir; c.path=path; c.existing=existing;
  c.watch = path != NULL;
  c.total = (uint64_t)4*spec->width*spec->height;
  c.file_size = 52u + spec->icc_size + (spec->icc_size & 1u) + c.total*(spec->depth/8u);
  return c;
}

static bool intact(Context *c) {
  if (!c->watch) return true;
  struct stat st;
  bool ok = c->existing ? files_equal(c->path, sentinel, sizeof sentinel)
    : (lstat(c->path, &st) != 0 && errno == ENOENT);
  if (!ok) c->destination_changed = true;
  return ok;
}

static bool stop_context(Context *c, bool intended) {
  c->stopped=true; c->triggered=intended;
  c->stopped_reads=c->reads; c->stopped_proceeds=c->proceeds;
  return false;
}

static bool read_cb(void *opaque, uint32_t channel, uint32_t y,
                    uint32_t x, uint32_t count, void *samples) {
  Context *c = opaque; c->reads++;
  if (c->stopped) { c->after_stop=true; return false; }
  if (!intact(c)) return stop_context(c, false);
  if (!samples || (uintptr_t)samples % _Alignof(uint16_t) || channel >= 4 ||
      y >= c->spec->height || x >= c->spec->width || count == 0 || count > 4096 ||
      count > c->spec->width-x ||
      ((uint64_t)channel*c->spec->height+y)*c->spec->width+x != c->samples) {
    c->bad_request=true; return stop_context(c, false);
  }
  if (c->fail_read && c->reads == c->fail_read) return stop_context(c, true);
  for (uint32_t i=0; i<count; i++) {
    uint16_t value=(uint16_t)(channel*1009u+y*257u+(x+i)*251u+19u);
    if (c->spec->depth == 8) ((uint8_t *)samples)[i]=(uint8_t)value;
    else memcpy((uint8_t *)samples+2u*i, &value, sizeof value);
  }
  c->samples += count;
  return true;
}

static bool proceed_cb(void *opaque) {
  Context *c=opaque; c->proceeds++;
  if (c->stopped) { c->after_stop=true; return false; }
  if (!intact(c)) return stop_context(c, false);
  bool cancel = c->cancel == CANCEL_EARLY && c->samples == 0;
  if (c->cancel == CANCEL_MID) cancel = c->samples > 0 && c->samples < c->total;
  if (c->cancel == CANCEL_STAGED && c->samples == c->total) {
    bool found=false;
    bool ok=find_stage(c->dir, only_output, 1, c->file_size, NULL, 0, &found);
    CHECK(ok);
    cancel = ok && found;
  }
  return cancel ? stop_context(c, true) : true;
}

typedef struct { uint8_t *data; size_t size, cap; } Collect;
static bool collect_write(void *opaque, const uint8_t *bytes, size_t count) {
  Collect *c=opaque;
  if ((count && !bytes) || c->size > c->cap || count > c->cap-c->size) return false;
  if (count) memcpy(c->data+c->size, bytes, count);
  c->size += count; return true;
}

static uint8_t *reference(const GlimsCmykPsdSpec *spec, size_t *size) {
  uint64_t bytes=0;
  bool ok=glims_cmyk_psd_size(spec, &bytes) == GLIMS_CMYK_PSD_OK && bytes < 400u*1024u;
  CHECK(ok); if (!ok) return NULL;
  uint8_t *out=malloc((size_t)bytes);
  CHECK(out != NULL); if (!out) return NULL;
  Collect collect={out,0,(size_t)bytes}; Context c=context(spec,NULL,NULL,false);
  ok=glims_cmyk_psd_write(spec,read_cb,&c,collect_write,&collect) == GLIMS_CMYK_PSD_OK &&
    collect.size == bytes && c.samples == c.total && !c.bad_request;
  CHECK(ok); if (!ok) { free(out); return NULL; }
  *size=collect.size; return out;
}

static void check_failure_state(const Context *c) {
  CHECK(c->triggered && c->stopped && !c->bad_request && !c->destination_changed);
  CHECK(!c->after_stop && c->reads == c->stopped_reads && c->proceeds == c->stopped_proceeds);
  CHECK(files_equal(c->path, sentinel, sizeof sentinel));
  CHECK(dir_has_only(c->dir, only_output, 1));
}

static void success(uint16_t depth, bool existing, bool optional_nulls, const char *name) {
  char dir[GLIMS_PATH_MAX], path[GLIMS_PATH_MAX];
  if (!make_case(name,dir,path,existing)) return;
  uint8_t icc[129], saved_icc[129]; make_icc(icc,sizeof icc); memcpy(saved_icc,icc,sizeof icc);
  GlimsCmykPsdSpec spec={11,3,depth,icc,sizeof icc};
  uint8_t saved_spec[sizeof spec]; memcpy(saved_spec,&spec,sizeof spec);
  size_t size=0; uint8_t *expected=reference(&spec,&size); if (!expected) return;
  int oldfd=existing ? open(path,O_RDONLY) : -1;
  if (existing) { CHECK(oldfd >= 0); if (oldfd < 0) { free(expected); return; } }
  Context c=context(&spec,dir,path,existing);
  int error=987;
  GlimsCmykPsdFileStatus result=glims_cmyk_psd_write_file(&spec,read_cb,&c,path,
    optional_nulls ? NULL : proceed_cb, optional_nulls ? NULL : &c, optional_nulls ? NULL : &error);
  CHECK(result == GLIMS_CMYK_PSD_FILE_OK);
  if (!optional_nulls) CHECK(error == 0 && c.proceeds > 0);
  CHECK(c.samples == c.total && !c.destination_changed && !c.bad_request && !c.stopped);
  CHECK(files_equal(path,expected,size));
  struct stat st={0}; CHECK(lstat(path,&st) == 0 && S_ISREG(st.st_mode));
  if (existing) {
    CHECK((st.st_mode & 0777) == 0640);
    CHECK(fd_reads_bytes(oldfd,sentinel,sizeof sentinel));
    CHECK(close(oldfd) == 0);
  } else CHECK((st.st_mode & 0077) == 0); /* Private, not an invented exact mode requirement. */
  CHECK(dir_has_only(dir,only_output,1));
  CHECK(!memcmp(saved_icc,icc,sizeof icc) && !memcmp(saved_spec,&spec,sizeof spec));
  free(expected);
}

typedef struct { unsigned reads, proceeds; } Calls;
static bool unused_read(void *opaque,uint32_t c,uint32_t y,uint32_t x,uint32_t n,void *p) {
  Calls *calls=opaque; calls->reads++; (void)c; (void)y; (void)x; (void)n; (void)p; return false;
}
static bool count_proceed(void *opaque) { ((Calls *)opaque)->proceeds++; return true; }

static void refusal(const GlimsCmykPsdSpec *spec, const char *path, bool missing_read,
                    GlimsCmykPsdFileStatus expected, const char *dir, const char *sentinel_path) {
  Calls calls={0}; int error=876;
  GlimsCmykPsdFileStatus result=glims_cmyk_psd_write_file(spec,missing_read?NULL:unused_read,&calls,
                                                       path,count_proceed,&calls,&error);
  CHECK(result == expected && calls.reads == 0);
  if (expected == GLIMS_CMYK_PSD_FILE_INVALID) CHECK(error == 0);
  else CHECK(error != 0 && error != 876);
  CHECK(files_equal(sentinel_path,sentinel,sizeof sentinel));
  CHECK(dir_has_only(dir,only_output,1));
}

static void invalid_inputs(void) {
  char dir[GLIMS_PATH_MAX],path[GLIMS_PATH_MAX],missing[GLIMS_PATH_MAX];
  if (!make_case("invalid",dir,path,true)) return;
  uint8_t icc[128]; make_icc(icc,sizeof icc);
  GlimsCmykPsdSpec spec={3,2,8,icc,sizeof icc}, bad=spec;
  refusal(NULL,path,false,GLIMS_CMYK_PSD_FILE_INVALID,dir,path);
  bad.width=0; refusal(&bad,path,false,GLIMS_CMYK_PSD_FILE_INVALID,dir,path);
  bad=spec; bad.depth=32; refusal(&bad,path,false,GLIMS_CMYK_PSD_FILE_INVALID,dir,path);
  icc[36]='X'; refusal(&spec,path,false,GLIMS_CMYK_PSD_FILE_INVALID,dir,path); icc[36]='a';
  refusal(&spec,path,true,GLIMS_CMYK_PSD_FILE_INVALID,dir,path);
  refusal(&spec,NULL,false,GLIMS_CMYK_PSD_FILE_INVALID,dir,path);
  refusal(&spec,"",false,GLIMS_CMYK_PSD_FILE_INVALID,dir,path);
  int cwd=open(".",O_RDONLY); CHECK(cwd >= 0);
  if (cwd >= 0) {
    bool moved=chdir(dir) == 0; CHECK(moved);
    if (moved) refusal(&spec,"out.psd",false,GLIMS_CMYK_PSD_FILE_INVALID,dir,path);
    CHECK(fchdir(cwd) == 0); CHECK(close(cwd) == 0);
  }
  bool joined=join_path(missing,sizeof missing,dir,"missing/out.psd"); CHECK(joined);
  if (joined) refusal(&spec,missing,false,GLIMS_CMYK_PSD_FILE_IO_FAILED,dir,path);
}

static void special_destination(int type) {
  const char *names[]={"symlink","directory","fifo"};
  char dir[GLIMS_PATH_MAX],path[GLIMS_PATH_MAX],real[GLIMS_PATH_MAX];
  if (!make_case(names[type],dir,path,false)) return;
  const char *allowed[]={"out.psd","real.psd"}; size_t count=1;
  bool ok;
  if (type == 0) {
    ok=join_path(real,sizeof real,dir,"real.psd") &&
      write_file_exact(real,sentinel,sizeof sentinel,0600) && symlink("real.psd",path) == 0;
    count=2;
  } else if (type == 1) {
    ok=mkdir(path,0700) == 0 && join_path(real,sizeof real,path,"inside") &&
      write_file_exact(real,sentinel,sizeof sentinel,0600);
  } else ok=mkfifo(path,0600) == 0;
  CHECK(ok); if (!ok) return;
  struct stat before={0}, after={0}; CHECK(lstat(path,&before) == 0);
  uint8_t icc[128]; make_icc(icc,sizeof icc); GlimsCmykPsdSpec spec={3,2,8,icc,sizeof icc};
  /* Bound a defective FIFO open in its own process; it must never hang the suite. */
  if (type == 2) {
    fflush(NULL); pid_t pid=fork(); CHECK(pid >= 0);
    if (pid == 0) {
      alarm(5); Calls calls={0}; int error=987;
      GlimsCmykPsdFileStatus result=glims_cmyk_psd_write_file(&spec,unused_read,&calls,path,
                                                          count_proceed,&calls,&error);
      _exit((result == GLIMS_CMYK_PSD_FILE_INVALID || result == GLIMS_CMYK_PSD_FILE_IO_FAILED) &&
            !calls.reads ? 0 : 1);
    }
    if (pid > 0) {
      int status=0; pid_t got;
      do { got=waitpid(pid,&status,0); } while (got < 0 && errno == EINTR);
      CHECK(got == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
  } else {
    Calls calls={0}; int error=987;
    GlimsCmykPsdFileStatus result=glims_cmyk_psd_write_file(&spec,unused_read,&calls,path,
                                                        count_proceed,&calls,&error);
    CHECK(result == GLIMS_CMYK_PSD_FILE_INVALID || result == GLIMS_CMYK_PSD_FILE_IO_FAILED);
    CHECK(calls.reads == 0);
    CHECK(error != 987); /* Header does not pin the error category for nonregular targets. */
  }
  CHECK(lstat(path,&after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
        before.st_mode == after.st_mode);
  CHECK(dir_has_only(dir,allowed,count));
  if (type < 2) CHECK(files_equal(real,sentinel,sizeof sentinel));
  if (type == 0) {
    char link[32]; ssize_t n=readlink(path,link,sizeof link);
    CHECK(n == 8 && !memcmp(link,"real.psd",8));
  } else if (type == 1) {
    const char *inside[]={"inside"}; CHECK(dir_has_only(path,inside,1));
  }
}

static void fault(uint16_t depth, size_t fail_read, CancelMode cancel, const char *name) {
  char dir[GLIMS_PATH_MAX],path[GLIMS_PATH_MAX]; if (!make_case(name,dir,path,true)) return;
  uint8_t icc[129],saved_icc[129]; make_icc(icc,sizeof icc); memcpy(saved_icc,icc,sizeof icc);
  GlimsCmykPsdSpec spec={8193,3,depth,icc,sizeof icc};
  uint8_t saved_spec[sizeof spec]; memcpy(saved_spec,&spec,sizeof spec);
  Context c=context(&spec,dir,path,true); c.fail_read=fail_read; c.cancel=cancel;
  int error=123;
  GlimsCmykPsdFileStatus result=glims_cmyk_psd_write_file(&spec,read_cb,&c,path,proceed_cb,&c,&error);
  CHECK(result == (fail_read ? GLIMS_CMYK_PSD_FILE_READ_FAILED : GLIMS_CMYK_PSD_FILE_CANCELLED));
  CHECK(error == 0); check_failure_state(&c);
  if (fail_read) CHECK(c.reads == fail_read);
  if (cancel == CANCEL_EARLY) CHECK(c.samples == 0);
  if (cancel == CANCEL_MID) CHECK(c.samples > 0 && c.samples < c.total);
  if (cancel == CANCEL_STAGED) CHECK(c.samples == c.total);
  CHECK(!memcmp(saved_spec,&spec,sizeof spec) && !memcmp(saved_icc,icc,sizeof icc));
}

static void write_failure_child(void) {
  char dir[GLIMS_PATH_MAX],path[GLIMS_PATH_MAX]; if (!make_case("write-limit",dir,path,true)) return;
  struct rlimit original={0}, after={0}; struct sigaction action_before, action_after;
  bool ready=getrlimit(RLIMIT_FSIZE,&original) == 0 && sigaction(SIGXFSZ,NULL,&action_before) == 0;
  CHECK(ready); if (!ready) return;
  fflush(NULL); pid_t pid=fork(); CHECK(pid >= 0);
  if (pid == 0) {
    alarm(10);
    struct sigaction ignored; memset(&ignored,0,sizeof ignored); ignored.sa_handler=SIG_IGN;
    sigemptyset(&ignored.sa_mask);
    if (sigaction(SIGXFSZ,&ignored,NULL)) _exit(20);
    struct rlimit limit=original;
    limit.rlim_cur=limit.rlim_max == RLIM_INFINITY || limit.rlim_max > 1024 ? 1024 : limit.rlim_max;
    if (setrlimit(RLIMIT_FSIZE,&limit)) _exit(21);
    uint8_t icc[128]; make_icc(icc,sizeof icc); GlimsCmykPsdSpec spec={8193,3,16,icc,sizeof icc};
    Context c=context(&spec,dir,path,true); int error=0;
    GlimsCmykPsdFileStatus result=glims_cmyk_psd_write_file(&spec,read_cb,&c,path,proceed_cb,&c,&error);
    if (result != GLIMS_CMYK_PSD_FILE_IO_FAILED || error == 0 || c.destination_changed ||
        !files_equal(path,sentinel,sizeof sentinel) || !dir_has_only(dir,only_output,1)) _exit(22);
    _exit(0);
  }
  if (pid > 0) {
    int status=0; pid_t got;
    do { got=waitpid(pid,&status,0); } while (got < 0 && errno == EINTR);
    CHECK(got == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
  }
  CHECK(files_equal(path,sentinel,sizeof sentinel)); CHECK(dir_has_only(dir,only_output,1));
  CHECK(getrlimit(RLIMIT_FSIZE,&after) == 0 && original.rlim_cur == after.rlim_cur &&
        original.rlim_max == after.rlim_max);
  CHECK(sigaction(SIGXFSZ,NULL,&action_after) == 0 && action_before.sa_handler == action_after.sa_handler);
}

int main(void) {
  int n=snprintf(g_tmpdir,sizeof g_tmpdir,"/tmp/glims-cmyk-psd-file.XXXXXX");
  if (n < 0 || (size_t)n >= sizeof g_tmpdir || !mkdtemp(g_tmpdir)) { perror("test directory"); return 2; }
  success(8,false,false,"new8"); success(16,false,false,"new16");
  success(8,true,false,"replace8"); success(16,true,false,"replace16");
  success(8,false,true,"optional-nulls");
  invalid_inputs(); for (int type=0;type<3;type++) special_destination(type);
  fault(8,1,CANCEL_NONE,"read-first8"); fault(16,1,CANCEL_NONE,"read-first16");
  fault(8,5,CANCEL_NONE,"read-late8"); fault(16,5,CANCEL_NONE,"read-late16");
  fault(8,0,CANCEL_EARLY,"cancel-early8"); fault(16,0,CANCEL_EARLY,"cancel-early16");
  fault(8,0,CANCEL_MID,"cancel-mid8"); fault(16,0,CANCEL_MID,"cancel-mid16");
  fault(8,0,CANCEL_STAGED,"cancel-staged8"); fault(16,0,CANCEL_STAGED,"cancel-staged16");
  write_failure_child();
  cleanup_tree(g_tmpdir); struct stat st; CHECK(lstat(g_tmpdir,&st) != 0 && errno == ENOENT);
  printf("%d checks; %d failures\n",g_checks,g_failures);
  return g_failures ? 1 : 0;
}
