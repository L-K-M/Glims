#include "lab-brush-coverage.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned checks;
static unsigned failures;

static void
check(bool condition, const char *description)
{
  checks++;
  if (!condition) {
    failures++;
    fprintf(stderr, "FAIL: %s\n", description);
  }
}

static bool
same_bits(float a, float b)
{
  return memcmp(&a, &b, sizeof a) == 0;
}

static void
literal_results(void)
{
  /* Fixed dyadic goldens. No copy of the kernel's arithmetic is used here. */
  const struct { float previous, mask, expected; } cases[] = {
    {0.0f, 0.5f, 0.5f}, {0.5f, 0.5f, 0.75f}, {0.75f, 0.5f, 0.875f},
    {0.25f, 0.5f, 0.625f}, {0.25f, 0.25f, 0.4375f},
    {0.0f, 1.0f, 1.0f}, {0.25f, 1.0f, 1.0f}, {1.0f, 0.5f, 1.0f},
    {1.0f, FLT_TRUE_MIN, 1.0f}, {0.0f, FLT_TRUE_MIN, FLT_TRUE_MIN},
    {FLT_TRUE_MIN, 0.0f, FLT_TRUE_MIN},
    {-0.0f, 0.0f, -0.0f}, {-0.0f, -0.0f, -0.0f},
    {-0.0f, -0x1.172ap-53f, -0.0f}, {-0.0f, -FLT_MAX, -0.0f},
    {0.25f, -0x1.172ap-53f, 0.25f}, {0.75f, -FLT_MAX, 0.75f},
    {0.25f, 2.0f, 1.0f}, {0.75f, FLT_MAX, 1.0f},
    /* 1-2^-25 is a binary32 half tie; nearest-even rounds to 1. */
    {0x1.fffffep-1f, 0.5f, 1.0f}
  };
  for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
    float previous = cases[i].previous, mask = cases[i].mask, out = -1.0f;
    check(glims_lab_brush_coverage(1, &previous, &mask, &out), "literal admitted");
    check(same_bits(out, cases[i].expected), "literal exact output bytes");
    check(same_bits(previous, cases[i].previous) && same_bits(mask, cases[i].mask),
          "successful literal does not mutate inputs");
  }

  float mask = 0.5f, previous = 0.0f;
  const float expected[] = {0.5f, 0.75f, 0.875f};
  for (size_t i = 0; i < 3; i++) {
    float next = -1.0f;
    check(glims_lab_brush_coverage(1, &previous, &mask, &next) &&
          same_bits(next, expected[i]), "repeated dabs accumulate fixed goldens");
    previous = next;
  }
}

static void
atomic_rejections(void)
{
  const float bad_previous[] = {-FLT_TRUE_MIN, -1.0f, 0x1.000002p0f,
                                FLT_MAX, NAN, INFINITY, -INFINITY};
  const float bad_mask[] = {NAN, INFINITY, -INFINITY};
  for (size_t kind = 0; kind < 2; kind++) {
    const size_t count = kind == 0 ? sizeof bad_previous / sizeof bad_previous[0]
                                  : sizeof bad_mask / sizeof bad_mask[0];
    for (size_t bad = 0; bad < count; bad++) {
      float previous[] = {0.0f, 0.25f, 0.5f};
      float mask[] = {0.5f, 0.5f, 0.5f};
      float out[] = {9.0f, -7.0f, -0.0f};
      unsigned char previous_before[sizeof previous], mask_before[sizeof mask];
      unsigned char out_before[sizeof out];
      if (kind == 0) previous[2] = bad_previous[bad];
      else mask[2] = bad_mask[bad];
      memcpy(previous_before, previous, sizeof previous);
      memcpy(mask_before, mask, sizeof mask);
      memcpy(out_before, out, sizeof out);
      check(!glims_lab_brush_coverage(3, previous, mask, out), "last invalid sample refused");
      check(memcmp(out, out_before, sizeof out) == 0, "last invalid sample leaves entire output intact");
      check(memcmp(previous, previous_before, sizeof previous) == 0 &&
            memcmp(mask, mask_before, sizeof mask) == 0, "rejection preserves all input bytes");
    }
  }
  float previous = NAN, mask = 0.0f, out = 7.0f;
  check(!glims_lab_brush_coverage(1, &previous, &mask, &out) && same_bits(out, 7.0f),
        "zero mask does not bypass previous validation");
  previous = 1.0f; mask = INFINITY;
  check(!glims_lab_brush_coverage(1, &previous, &mask, &out) && same_bits(out, 7.0f),
        "full previous coverage does not bypass mask validation");
}

static void
bounds_and_nulls(void)
{
  float previous[2] = {0.25f, 0.5f}, mask[2] = {0.5f, 0.5f};
  float out[2] = {7.0f, 8.0f};
  const float unchanged[2] = {7.0f, 8.0f};
  void *wrap = (void *)(uintptr_t)(UINTPTR_MAX - sizeof(float) + 1u);
  check(glims_lab_brush_coverage(0, NULL, NULL, NULL), "empty permits all NULL");
  check(glims_lab_brush_coverage(0, wrap, wrap, wrap), "empty performs no range access");
  check(glims_lab_brush_coverage(0, NULL, NULL, out) && memcmp(out, unchanged, sizeof out) == 0,
        "empty does not write destination");
  check(!glims_lab_brush_coverage(4097, previous, mask, out), "4097 refuses before reading short buffers");
  check(!glims_lab_brush_coverage(SIZE_MAX, previous, mask, out), "SIZE_MAX refuses before multiplication/access");
  check(!glims_lab_brush_coverage(1, NULL, mask, out), "NULL previous refuses");
  check(!glims_lab_brush_coverage(1, previous, NULL, out), "NULL mask refuses");
  check(!glims_lab_brush_coverage(1, previous, mask, NULL), "NULL destination refuses");
  check(!glims_lab_brush_coverage(1, wrap, mask, out), "previous address wrap refuses before access");
  check(!glims_lab_brush_coverage(1, previous, wrap, out), "mask address wrap refuses before access");
  check(!glims_lab_brush_coverage(1, previous, mask, wrap), "destination address wrap refuses before access");
  check(memcmp(out, unchanged, sizeof out) == 0, "bad ranges/counts/NULL leave output intact");

  static float full_previous[4096], full_mask[4096], full_out[4096];
  for (size_t i = 0; i < 4096; i++) {
    full_previous[i] = 0.5f; full_mask[i] = 0.5f; full_out[i] = -1.0f;
  }
  check(glims_lab_brush_coverage(4096, full_previous, full_mask, full_out), "maximum accepted");
  bool correct = true, intact = true;
  for (size_t i = 0; i < 4096; i++) {
    correct = correct && same_bits(full_out[i], 0.75f);
    intact = intact && same_bits(full_previous[i], 0.5f) && same_bits(full_mask[i], 0.5f);
  }
  check(correct, "maximum writes every expected sample");
  check(intact, "maximum preserves both inputs");
}

static void
alias_rules(void)
{
  float shared[8] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f, 0.25f, 0.5f, 0.75f};
  float other[4] = {0.5f, 0.5f, 0.5f, 0.5f};
  unsigned char before[sizeof shared], other_before[sizeof other];
  memcpy(before, shared, sizeof shared); memcpy(other_before, other, sizeof other);
  for (size_t input = 0; input < 2; input++) {
    /* Exact, output-after-input, output-before-input; all overlap four samples. */
    const size_t input_offsets[] = {0, 0, 1};
    const size_t output_offsets[] = {0, 1, 0};
    for (size_t i = 0; i < 3; i++) {
      const void *previous = input == 0 ? shared + input_offsets[i] : other;
      const void *mask = input == 0 ? other : shared + input_offsets[i];
      check(!glims_lab_brush_coverage(4, previous, mask, shared + output_offsets[i]),
            "exact/partial output overlap with either input refuses");
      check(memcmp(before, shared, sizeof shared) == 0 &&
            memcmp(other_before, other, sizeof other) == 0,
            "overlap refusal preserves actual overlapping storage");
    }
  }

  float out[4] = {-1, -1, -1, -1};
  const float exact[] = {0.0f, 0.4375f, 0.75f, 0.9375f};
  check(glims_lab_brush_coverage(4, shared, shared, out) && memcmp(out, exact, sizeof out) == 0,
        "identical inputs admitted with independent literal oracle");
  const float partial[] = {0.25f, 0.625f, 0.875f, 1.0f};
  check(glims_lab_brush_coverage(4, shared, shared + 1, out) && memcmp(out, partial, sizeof out) == 0,
        "partly overlapping inputs admitted");
  check(memcmp(before, shared, sizeof shared) == 0, "overlapping inputs remain unchanged");

  float adjacent[6] = {-1, -1, 0.0f, 0.5f, 0.5f, 0.5f};
  check(glims_lab_brush_coverage(2, adjacent + 2, adjacent + 4, adjacent) &&
        same_bits(adjacent[0], 0.5f) && same_bits(adjacent[1], 0.75f) &&
        same_bits(adjacent[2], 0.0f) && same_bits(adjacent[3], 0.5f) &&
        same_bits(adjacent[4], 0.5f) && same_bits(adjacent[5], 0.5f),
        "adjacent destination before inputs admitted");
  float tail[4] = {0.5f, 0.5f, -1, -1};
  const float previous[2] = {0.0f, 0.5f};
  check(glims_lab_brush_coverage(2, previous, tail, tail + 2) &&
        same_bits(tail[0], 0.5f) && same_bits(tail[1], 0.5f) &&
        same_bits(tail[2], 0.5f) && same_bits(tail[3], 0.75f),
        "adjacent destination after mask admitted");
}

static void
unaligned_canaries(void)
{
  unsigned char storage[40], expected[40], before[40];
  const float previous[2] = {-0.0f, 0.5f}, mask[2] = {0.0f, 0.5f};
  const float output[2] = {-0.0f, 0.75f};
  unsigned char *p = storage + 1, *m = storage + 13, *d = storage + 25;
  memset(storage, 0xa5, sizeof storage);
  memcpy(p, previous, sizeof previous); memcpy(m, mask, sizeof mask);
  memcpy(expected, storage, sizeof storage); memcpy(expected + 25, output, sizeof output);
  check(glims_lab_brush_coverage(2, p, m, d), "unaligned arrays admitted");
  check(memcmp(storage, expected, sizeof storage) == 0,
        "unaligned result exact; both inputs and every exterior canary preserved");
  float invalid = NAN;
  memcpy(m + sizeof(float), &invalid, sizeof invalid);
  memcpy(before, storage, sizeof storage);
  check(!glims_lab_brush_coverage(2, p, m, d), "unaligned late invalid refused");
  check(memcmp(storage, before, sizeof storage) == 0, "unaligned failure leaves all bytes unchanged");
  /* A one-byte intersection must be refused, not only float-aligned aliases. */
  check(!glims_lab_brush_coverage(2, p, m, p + 7) &&
        memcmp(storage, before, sizeof storage) == 0, "one-byte output/previous overlap refused atomically");
  check(!glims_lab_brush_coverage(2, p, m, m + 7) &&
        memcmp(storage, before, sizeof storage) == 0, "one-byte output/mask overlap refused atomically");
}

int
main(void)
{
  literal_results(); atomic_rejections(); bounds_and_nulls(); alias_rules(); unaligned_canaries();
  printf("lab-brush-coverage: %u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}
