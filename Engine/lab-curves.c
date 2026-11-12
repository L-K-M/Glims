#include "lab-curves.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <string.h>


/* Keep lookup rounding distinct from the explicit physical-space FMAs. */
#pragma STDC FP_CONTRACT OFF

/* Test an address range against the small changed object without constructing
 * an overflowing end address. */
static bool
aliases_changed(const void *pointer, size_t bytes, uintptr_t changed_start,
                uintptr_t changed_end)
{
  if (!pointer || !bytes) return false;
  uintptr_t start = (uintptr_t)pointer;
  if (start >= changed_start) return start < changed_end;
  return changed_start - start < bytes;
}

static bool
checked_end(const void *pointer, size_t bytes, uintptr_t *end)
{
  uintptr_t start = (uintptr_t)pointer;
  if (bytes > UINTPTR_MAX - start) return false;
  *end = start + bytes;
  return true;
}

static bool
overlaps(const void *a, uintptr_t a_end, const void *b, uintptr_t b_end)
{
  return (uintptr_t)a < b_end && (uintptr_t)b < a_end;
}

static bool
is_valid_curve(const GlimsLabCurve *curve)
{
  if (!curve) return false;
  for (int i = 0; i < 256; i++) {
    double v = curve->samples[i];
    if (!isfinite(v)) return false;
    if (v < 0.0 || v > 1.0) return false;
  }
  return true;
}

static bool
is_identity_curve(const GlimsLabCurve *curve)
{
  if (!curve) return false;
  for (int i = 0; i < 256; i++) {
    if (curve->samples[i] != (double)i / 255.0) return false;
  }
  return true;
}

static double
linear_interp_double(double a, double b, double t)
{
  return a + (b - a) * t;
}

bool
glims_lab_curves_row(GlimsLabRole role,
                     GlimsLabFormat format,
                     const GlimsLabCurve *curve,
                     size_t count,
                     const void *source,
                     const float *mask,
                     void *destination,
                     bool *changed)
{
  if (!changed) return false;
  uintptr_t changed_start = (uintptr_t)changed, changed_end;
  if (!checked_end(changed, sizeof *changed, &changed_end)) return false;

  size_t width = glims_lab_sample_size(format);
  /* Protect settings even when another argument is invalid. Invalid format or
   * count has no accepted sample range, but exact aliases still refuse. */
  if (aliases_changed(curve, sizeof *curve, changed_start, changed_end)) return false;
  if (count && (source == (const void *)changed || destination == (void *)changed ||
                (const void *)mask == (const void *)changed)) return false;
  if (width && count <= GLIMS_LAB_CURVES_MAX_SAMPLES) {
    if (aliases_changed(source, count * width, changed_start, changed_end) ||
        aliases_changed(destination, count * width, changed_start, changed_end) ||
        aliases_changed(mask, count * sizeof(float), changed_start, changed_end))
      return false;
  }
  *changed = false;

  if (!width || count > GLIMS_LAB_CURVES_MAX_SAMPLES ||
      (role != GLIMS_LAB_ROLE_L && role != GLIMS_LAB_ROLE_A && role != GLIMS_LAB_ROLE_B) ||
      !curve)
    return false;

  size_t bytes = count * width;
  uintptr_t source_end, destination_end, mask_end = 0, curve_end = 0;
  if (!checked_end(source, bytes, &source_end) ||
      !checked_end(destination, bytes, &destination_end) ||
      !checked_end(curve, sizeof *curve, &curve_end) ||
      (mask && !checked_end(mask, count * sizeof(float), &mask_end))) return false;
  if (count && (!source || !destination)) return false;
  if (count && source != destination && overlaps(source, source_end, destination, destination_end))
    return false;
  if (count && mask && (overlaps(source, source_end, mask, mask_end) ||
               overlaps(destination, destination_end, mask, mask_end))) return false;
  if (count && (overlaps(source, source_end, curve, curve_end) ||
      overlaps(destination, destination_end, curve, curve_end) ||
      (mask && overlaps(mask, mask_end, curve, curve_end)))) return false;

  /* The caller may supply unaligned settings. Never dereference that pointer. */
  GlimsLabCurve settings;
  memcpy(&settings, (const unsigned char *)(const void *)curve, sizeof settings);
  if (!is_valid_curve(&settings)) return false;
  if (!count) return true;
  bool identity = is_identity_curve(&settings);
  curve = &settings;
  unsigned char staging[GLIMS_LAB_CURVES_MAX_SAMPLES * sizeof(float)];
  const unsigned char *input = source;
  const unsigned char *mask_bytes = (const unsigned char *)mask;

  for (size_t i = 0; i < count; i++) {
    float coverage = 1.0f;
    if (mask) memcpy(&coverage, mask_bytes + i * sizeof coverage, sizeof coverage);
    if (!isfinite(coverage) || coverage < 0.0f || coverage > 1.0f) return false;
    double weight = (double)coverage;
    if (weight == 0.0) {
      memcpy(staging + i * width, input + i * width, width);
      continue;
    }

    double original_phys;
    if (!glims_lab_decode_row(role, format, 1, input + i * width, &original_phys)) return false;

    if (identity) {
      memcpy(staging + i * width, input + i * width, width);
      continue;
    }
    double lookup_norm;
    if (format == GLIMS_LAB_FORMAT_FLOAT) {
      /* Extended physical input maps to the nearest endpoint. */
      double n;
      if (role == GLIMS_LAB_ROLE_L) {
        n = original_phys / 100.0;
      } else {
        n = (original_phys + 128.0) / 255.0;
      }
      if (n <= 0.0) {
        lookup_norm = curve->samples[0];
      } else if (n >= 1.0) {
        lookup_norm = curve->samples[255];
      } else {
        /* linear interpolation in double between samples */
        double pos = n * 255.0;
        int idx = (int)floor(pos);
        if (idx < 0) idx = 0;
        if (idx >= 255) {
          lookup_norm = curve->samples[255];
        } else {
          double t = pos - (double)idx;
          lookup_norm = linear_interp_double(curve->samples[idx], curve->samples[idx + 1], t);
        }
      }
    } else if (format == GLIMS_LAB_FORMAT_U8) {
      unsigned q = ((const unsigned char *)input)[i];
      /* exact U8 table indexing */
      lookup_norm = curve->samples[q];
    } else if (format == GLIMS_LAB_FORMAT_U16) {
      uint16_t encoded;
      memcpy(&encoded, input + i * width, sizeof(encoded));
      unsigned q = encoded;
      /* U16 quotient/257 + remainder/257 */
      unsigned base_idx = q / 257;
      unsigned rem = q % 257;
      double t = (double)rem / 257.0;
      if (base_idx >= 255) {
        lookup_norm = curve->samples[255];
      } else {
        lookup_norm = linear_interp_double(curve->samples[base_idx], curve->samples[base_idx + 1], t);
      }
    } else {
      lookup_norm = 0.0;
    }

    /* Convert the normalized lookup into this axis's physical units. */
    double target_phys;
    if (role == GLIMS_LAB_ROLE_L) {
      target_phys = fma(100.0, lookup_norm, 0.0);
    } else {
      target_phys = fma(255.0, lookup_norm, -128.0);
    }

    /* If mapped physical target==decoded source preserve original bytes. */
    if (target_phys == original_phys) {
      memcpy(staging + i * width, input + i * width, width);
      continue;
    }

    /* Use the same physical-space blend as Lab Fill. */
    double result;
    if (weight == 1.0) {
      result = target_phys;
    } else {
      result = fma(weight, target_phys, (1.0 - weight) * original_phys);
    }
    if (!isfinite(result)) return false;
    /* repair roundoff to convex interval endpoints */
    if (weight != 1.0) {
      double low = fmin(original_phys, target_phys), high = fmax(original_phys, target_phys);
      if (result < low) result = low;
      if (result > high) result = high;
    }
    /* Float must remain finite/in FLT_MAX. No gamut clipping. */
    if (format == GLIMS_LAB_FORMAT_FLOAT) {
      if (fabs(result) > (double)FLT_MAX) return false;
    }
    if (!glims_lab_encode_row(role, format, 1, &result, staging + i * width)) return false;
  }

  bool any_changed = memcmp(source, staging, bytes) != 0;
  memcpy(destination, staging, bytes);
  *changed = any_changed;
  return true;
}
