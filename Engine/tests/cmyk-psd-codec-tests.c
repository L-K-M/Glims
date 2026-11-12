/* Independent file-byte and callback-contract tests. The serializer source
 * was not consulted to derive these expectations. Synthetic ICC headers here
 * exercise structural admission only, not transform/profile qualification. */
#include "cmyk-psd-codec.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
static const char *case_name;
#define CHECK(c, message) do { checks++; if (!(c)) { failures++; \
  fprintf(stderr, "FAIL %s:%d: %s\n", case_name, __LINE__, message); } } while (0)

static uint16_t be16(const uint8_t *p)
{ return (uint16_t)((uint16_t)p[0] << 8 | p[1]); }
static uint32_t be32(const uint8_t *p)
{ return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static void put32(uint8_t *p, uint32_t n)
{ p[0]=(uint8_t)(n>>24); p[1]=(uint8_t)(n>>16); p[2]=(uint8_t)(n>>8); p[3]=(uint8_t)n; }

static void icc_header(uint8_t *p, size_t n, const char *kind)
{
  memset(p, 0, n);
  put32(p, (uint32_t)n);
  memcpy(p + 12, kind, 4);
  memcpy(p + 16, "CMYK", 4);
  memcpy(p + 20, "XYZ ", 4);
  memcpy(p + 36, "acsp", 4);
  if (n == 129) p[128] = 0x7b; /* The odd final payload byte is not the pad. */
}

static uint16_t sample(uint16_t depth, uint32_t c, uint32_t y, uint32_t x)
{
  static const uint16_t edge[] = {0, 1, 255, 256, 257, 32767, 32768, 65534, 65535};
  if (depth == 16 && c == 0 && y == 0 && x < sizeof edge / sizeof edge[0])
    return edge[x];
  uint32_t value = c * 1009u + y * 257u + x * 251u + 19u;
  return (uint16_t)(value & (depth == 8 ? 255u : 65535u));
}

typedef struct {
  const GlimsCmykPsdSpec *spec;
  uint8_t *bytes;
  size_t capacity, used;
  uint32_t next_c, next_y, next_x, row_calls, min_row_calls;
  size_t reads, writes, reads_at_failure, writes_at_failure, after_failure;
  size_t fail_read;
  uint64_t fail_byte;
  bool inject_write, stopped, injected, contract_ok;
} Stream;

static Stream stream(const GlimsCmykPsdSpec *spec, uint8_t *bytes, size_t capacity)
{
  Stream s = {0};
  s.spec = spec; s.bytes = bytes; s.capacity = capacity;
  s.contract_ok = true; s.min_row_calls = UINT32_MAX;
  return s;
}

static bool stop(Stream *s, bool injected)
{
  s->stopped = true; s->injected = injected;
  s->reads_at_failure = s->reads; s->writes_at_failure = s->writes;
  return false;
}

static bool read_samples(void *context, uint32_t c, uint32_t y,
                         uint32_t x, uint32_t count, void *destination)
{
  Stream *s = context;
  s->reads++;
  if (s->stopped) { s->after_failure++; return false; }
  bool good = destination && s->spec && c < 4 && c == s->next_c &&
    y == s->next_y && y < s->spec->height && x == s->next_x &&
    x < s->spec->width && count > 0 && count <= 4096 &&
    count <= s->spec->width - x &&
    (uintptr_t)destination % _Alignof(uint16_t) == 0;
  if (!good) { s->contract_ok = false; return stop(s, false); }
  if (s->fail_read && s->reads == s->fail_read) return stop(s, true);
  for (uint32_t i = 0; i < count; i++) {
    uint16_t value = sample(s->spec->depth, c, y, x + i);
    if (s->spec->depth == 8) ((uint8_t *)destination)[i] = (uint8_t)value;
    else memcpy((uint8_t *)destination + 2u*i, &value, sizeof value);
  }
  s->row_calls++;
  s->next_x += count;
  if (s->next_x == s->spec->width) {
    if (s->row_calls < s->min_row_calls) s->min_row_calls = s->row_calls;
    s->row_calls = 0; s->next_x = 0; s->next_y++;
    if (s->next_y == s->spec->height) { s->next_y = 0; s->next_c++; }
  }
  return true;
}

static bool write_bytes(void *context, const uint8_t *bytes, size_t n)
{
  Stream *s = context;
  s->writes++;
  if (s->stopped) { s->after_failure++; return false; }
  if ((n && !bytes) || s->used > s->capacity || n > s->capacity - s->used) {
    s->contract_ok = false; return stop(s, false);
  }
  if (s->inject_write && s->fail_byte >= s->used && s->fail_byte - s->used < n)
    return stop(s, true);
  if (n) memcpy(s->bytes + s->used, bytes, n);
  s->used += n;
  return true;
}

/* This fixed-layout decoder does not trust emitted lengths for pointer math.
 * Its offsets are derived independently from the frozen format contract. */
static void inspect(const GlimsCmykPsdSpec *spec, const Stream *s)
{
  static const uint8_t literal8[26] = {
    '8','B','P','S', 0,1, 0,0,0,0,0,0, 0,4,
    0,0,0,1, 0,0,0,1, 0,8, 0,4
  };
  static const uint8_t literal16[26] = {
    '8','B','P','S', 0,1, 0,0,0,0,0,0, 0,4,
    0,0,0,1, 0,0,0,1, 0,16, 0,4
  };
  static const uint8_t resource[8] = {'8','B','I','M', 4,15, 0,0};
  uint8_t expected[26];
  memcpy(expected, spec->depth == 8 ? literal8 : literal16, sizeof expected);
  put32(expected + 14, spec->height); put32(expected + 18, spec->width);
  size_t pad = spec->icc_size & 1u;
  size_t start = 52u + spec->icc_size + pad;
  size_t pixels = (size_t)4 * spec->width * spec->height * (spec->depth / 8u);
  CHECK(s->used == start + pixels, "exact total bytes and EOF");
  if (s->used < start + pixels) return; /* Never parse past partial output. */
  CHECK(!memcmp(s->bytes, expected, sizeof expected), "literal PSD header");
  CHECK(be32(s->bytes + 26) == 0, "no color-mode data");
  CHECK(be32(s->bytes + 30) == 12u + spec->icc_size + pad, "resource section length");
  CHECK(!memcmp(s->bytes + 34, resource, sizeof resource), "one ICC resource and empty padded name");
  CHECK(be32(s->bytes + 42) == spec->icc_size, "ICC length excludes pad");
  CHECK(!memcmp(s->bytes + 46, spec->icc, spec->icc_size), "ICC bytes exact");
  if (pad) CHECK(s->bytes[46u + spec->icc_size] == 0, "odd ICC has zero padding");
  CHECK(be32(s->bytes + 46u + spec->icc_size + pad) == 0, "no layer/mask records");
  CHECK(be16(s->bytes + start - 2u) == 0, "RAW compression");
  bool equal = true;
  size_t offset = start;
  for (uint32_t c = 0; c < 4; c++)
    for (uint32_t y = 0; y < spec->height; y++)
      for (uint32_t x = 0; x < spec->width; x++) {
        uint16_t got = spec->depth == 8 ? s->bytes[offset] : be16(s->bytes + offset);
        if (got != sample(spec->depth, c, y, x)) equal = false;
        offset += spec->depth / 8u;
      }
  CHECK(equal, "every C/M/Y/K sample preserves its integer value without inversion");
  CHECK(offset == s->used, "no extra channel or trailing data");
}

static void valid(uint32_t w, uint32_t h, uint16_t depth, size_t profile_size,
                  const char *kind)
{
  uint8_t profile[129], saved_profile[129];
  icc_header(profile, profile_size, kind); memcpy(saved_profile, profile, profile_size);
  GlimsCmykPsdSpec spec = {w, h, depth, profile, profile_size};
  uint8_t saved_spec[sizeof spec]; memcpy(saved_spec, &spec, sizeof spec);
  uint64_t expected = 52u + profile_size + (profile_size & 1u) + (uint64_t)4*w*h*(depth/8u);
  uint64_t actual = UINT64_MAX;
  CHECK(glims_cmyk_psd_size(&spec, &actual) == GLIMS_CMYK_PSD_OK, "valid size succeeds");
  CHECK(actual == expected, "size matches independent arithmetic");
  CHECK(expected < 400u*1024u, "fixture output remains bounded");
  if (expected >= 400u*1024u) return;
  uint8_t *output = malloc((size_t)expected);
  CHECK(output != NULL, "fixture output allocation");
  if (!output) return;
  Stream s = stream(&spec, output, (size_t)expected);
  CHECK(glims_cmyk_psd_write(&spec, read_samples, &s, write_bytes, &s) == GLIMS_CMYK_PSD_OK,
        "valid stream succeeds");
  CHECK(s.contract_ok && !s.stopped, "read request bounds/order/alignment hold");
  CHECK(s.next_c == 4 && s.next_y == 0 && s.next_x == 0, "exactly all source samples requested");
  if (w == 12345) CHECK(s.min_row_calls >= 4, "every long row uses multiple bounded reads");
  inspect(&spec, &s);
  CHECK(!memcmp(saved_spec, &spec, sizeof spec), "spec remains immutable");
  CHECK(!memcmp(saved_profile, profile, profile_size), "ICC remains immutable");
  free(output);
}

typedef struct { size_t reads, writes; } Calls;
static bool count_read(void *context, uint32_t c, uint32_t y, uint32_t x,
                       uint32_t n, void *destination)
{
  Calls *calls = context; calls->reads++;
  (void)c; (void)y; (void)x; (void)n; (void)destination; return false;
}
static bool count_write(void *context, const uint8_t *bytes, size_t n)
{ Calls *calls = context; calls->writes++; (void)bytes; (void)n; return false; }

static void invalid(const GlimsCmykPsdSpec *spec, const char *name)
{
  case_name = name;
  uint64_t size = UINT64_MAX;
  uint8_t saved[sizeof(GlimsCmykPsdSpec)];
  if (spec) memcpy(saved, spec, sizeof saved);
  CHECK(glims_cmyk_psd_size(spec, &size) == GLIMS_CMYK_PSD_INVALID, "invalid size refuses");
  CHECK(size == 0, "failed size clears output");
  Calls calls = {0};
  CHECK(glims_cmyk_psd_write(spec, count_read, &calls, count_write, &calls) == GLIMS_CMYK_PSD_INVALID,
        "invalid write refuses");
  CHECK(calls.reads == 0 && calls.writes == 0, "invalid preflight invokes no callbacks");
  if (spec) CHECK(!memcmp(saved, spec, sizeof saved), "invalid spec remains immutable");
}

static void admission(void)
{
  uint8_t icc[128]; icc_header(icc, sizeof icc, "prtr");
  GlimsCmykPsdSpec base = {1, 1, 8, icc, sizeof icc}, bad;
  invalid(NULL, "NULL spec");
  bad = base; bad.width = 0; invalid(&bad, "zero width");
  bad = base; bad.height = 0; invalid(&bad, "zero height");
  bad = base; bad.width = 30001; invalid(&bad, "large width");
  bad = base; bad.height = 30001; invalid(&bad, "large height");
  bad = base; bad.width = UINT32_MAX; invalid(&bad, "maximum width integer");
  bad = base; bad.height = UINT32_MAX; invalid(&bad, "maximum height integer");
  bad = base; bad.depth = 1; invalid(&bad, "one-bit depth");
  bad = base; bad.depth = 32; invalid(&bad, "float depth");
  bad = base; bad.depth = 0; invalid(&bad, "zero depth");
  bad = base; bad.icc = NULL; invalid(&bad, "missing ICC");
  bad = base; bad.icc_size = 0; invalid(&bad, "zero ICC size");
  bad = base; bad.icc_size = 127; invalid(&bad, "short ICC header");
  bad = base; bad.icc_size = 4u*1024u*1024u + 1u; invalid(&bad, "oversized ICC before access");
  bad = base; bad.icc_size = SIZE_MAX; invalid(&bad, "maximum ICC size integer");
  put32(icc, 129); invalid(&base, "declared ICC size mismatch"); put32(icc, 128);
  memcpy(icc + 36, "xxxx", 4); invalid(&base, "ICC signature"); memcpy(icc + 36, "acsp", 4);
  memcpy(icc + 16, "RGB ", 4); invalid(&base, "ICC color space"); memcpy(icc + 16, "CMYK", 4);
  const char *classes[] = {"mntr", "link", "xxxx"};
  for (size_t i = 0; i < sizeof classes / sizeof classes[0]; i++) {
    memcpy(icc + 12, classes[i], 4); invalid(&base, classes[i]);
  }
  memcpy(icc + 12, "prtr", 4);
  case_name = "preflight boundary";
  uint64_t size = 0;
  CHECK(glims_cmyk_psd_size(&base, NULL) == GLIMS_CMYK_PSD_INVALID, "missing size output refuses");
  bad = base; bad.width = 30000; bad.height = 8947; bad.depth = 16;
  CHECK(glims_cmyk_psd_size(&bad, &size) == GLIMS_CMYK_PSD_OK, "near-two-GiB size admitted");
  CHECK(size == UINT64_C(2147280180), "independent literal near-two-GiB result");
  bad.height = 8948; invalid(&bad, "over-two-GiB encoded size");
  case_name = "dimension limit inclusive";
  bad = base; bad.width = 30000;
  CHECK(glims_cmyk_psd_size(&bad, &size) == GLIMS_CMYK_PSD_OK && size == 120180,
        "maximum width accepted without writing");
  bad = base; bad.height = 30000;
  CHECK(glims_cmyk_psd_size(&bad, &size) == GLIMS_CMYK_PSD_OK && size == 120180,
        "maximum height accepted without writing");
  case_name = "profile limit inclusive";
  size_t length = 4u*1024u*1024u;
  uint8_t *large = malloc(length);
  CHECK(large != NULL, "bounded four-MiB fixture allocation");
  if (large) {
    icc_header(large, length, "spac"); bad = base; bad.icc = large; bad.icc_size = length;
    CHECK(glims_cmyk_psd_size(&bad, &size) == GLIMS_CMYK_PSD_OK && size == 4194360,
          "four-MiB profile accepted by size-only preflight");
    free(large);
  }
  case_name = "missing callbacks";
  Calls calls = {0};
  CHECK(glims_cmyk_psd_write(&base, NULL, &calls, count_write, &calls) == GLIMS_CMYK_PSD_INVALID,
        "missing read refuses");
  CHECK(glims_cmyk_psd_write(&base, count_read, &calls, NULL, &calls) == GLIMS_CMYK_PSD_INVALID,
        "missing write refuses");
  CHECK(glims_cmyk_psd_write(&base, NULL, NULL, NULL, NULL) == GLIMS_CMYK_PSD_INVALID,
        "both callbacks missing refuses");
  CHECK(calls.reads == 0 && calls.writes == 0, "missing callbacks emit/read nothing");
}

static void callback_failure(size_t fail_read, uint64_t fail_byte, bool fail_write,
                             uint16_t depth, const char *name)
{
  case_name = name;
  uint8_t icc[129], saved_icc[129]; icc_header(icc, sizeof icc, "prtr");
  memcpy(saved_icc, icc, sizeof icc);
  GlimsCmykPsdSpec spec = {12345, 3, depth, icc, sizeof icc};
  uint8_t saved_spec[sizeof spec]; memcpy(saved_spec, &spec, sizeof spec);
  size_t size = 182u + (size_t)4*12345*3*(depth/8u);
  uint8_t *bytes = malloc(size);
  CHECK(bytes != NULL, "failure fixture allocation");
  if (!bytes) return;
  Stream s = stream(&spec, bytes, size);
  s.fail_read = fail_read; s.inject_write = fail_write; s.fail_byte = fail_byte;
  GlimsCmykPsdStatus result = glims_cmyk_psd_write(&spec, read_samples, &s, write_bytes, &s);
  CHECK(result == (fail_write ? GLIMS_CMYK_PSD_WRITE_FAILED : GLIMS_CMYK_PSD_READ_FAILED),
        "callback failure has its distinct status");
  CHECK(s.injected && s.stopped && s.contract_ok, "intended fault was reached");
  CHECK(s.after_failure == 0 && s.reads == s.reads_at_failure && s.writes == s.writes_at_failure,
        "no source or sink callback occurs after first false");
  if (!fail_write) CHECK(s.reads == fail_read, "read failure occurs at selected request");
  CHECK(!memcmp(saved_spec, &spec, sizeof spec) && !memcmp(saved_icc, icc, sizeof icc),
        "failure leaves borrowed inputs unchanged");
  /* An emitted prefix is permitted. Atomic replacement belongs to the caller. */
  free(bytes);
}

static size_t null_reads, null_writes;
static bool null_read(void *context, uint32_t c, uint32_t y, uint32_t x,
                      uint32_t count, void *samples)
{
  null_reads++;
  CHECK(context == NULL && c < 4 && y == 0 && x == 0 && count == 1 && samples,
        "null-context callback still receives valid one-pixel request");
  if (!samples || count != 1) return false;
  ((uint8_t *)samples)[0] = (uint8_t)(17u*c); return true;
}
static bool null_write(void *context, const uint8_t *bytes, size_t n)
{ null_writes++; CHECK(context == NULL && (bytes || !n), "null sink context is delivered"); return true; }

int main(void)
{
  for (unsigned depth = 8; depth <= 16; depth += 8) {
    case_name = depth == 8 ? "U8 one pixel literal" : "U16 one pixel literal";
    valid(1, 1, (uint16_t)depth, 128, "prtr");
    case_name = depth == 8 ? "U8 odd profile/non-square" : "U16 odd profile/non-square";
    valid(11, 3, (uint16_t)depth, 129, "scnr");
    case_name = depth == 8 ? "U8 long rows" : "U16 long rows";
    valid(12345, 3, (uint16_t)depth, 128, "spac");
  }
  admission();
  for (unsigned depth = 8; depth <= 16; depth += 8) {
    callback_failure(1, 0, false, (uint16_t)depth, "first source failure");
    callback_failure(5, 0, false, (uint16_t)depth, "later source failure");
    callback_failure(0, 10, true, (uint16_t)depth, "header sink failure");
    callback_failure(0, 46+64, true, (uint16_t)depth, "ICC payload sink failure");
    callback_failure(0, 182+8195, true, (uint16_t)depth, "pixel sink failure");
  }
  case_name = "null callback contexts";
  uint8_t icc[128]; icc_header(icc, sizeof icc, "prtr");
  GlimsCmykPsdSpec spec = {1, 1, 8, icc, sizeof icc};
  CHECK(glims_cmyk_psd_write(&spec, null_read, NULL, null_write, NULL) == GLIMS_CMYK_PSD_OK,
        "callbacks may accept null contexts");
  CHECK(null_reads == 4 && null_writes > 0, "null contexts do not bypass callbacks");
  printf("%u checks; %u failures\n", checks, failures);
  return failures ? 1 : 0;
}
