/*
 * Image metadata (EXIF/IPTC/XMP): tag listing, value reads and single-tag
 * set/remove. Runs on the engine thread.
 *
 * Native dependencies (adapter-only): GExiv2 0.14 headers plus the
 * GUI-free GimpMetadata utility (libgimpbase/gimpmetadata.h, which
 * GIMP_TYPE_METADATA derives from GExiv2Metadata) and the core image
 * metadata API (app/core/gimpimage-metadata.h). libgimp and the GUI
 * modules are never linked or loaded.
 *
 * Reads borrow the image's own GimpMetadata (gimp_image_get_metadata,
 * transfer none) and are allowed at any time; they never create
 * metadata. An image with no metadata reads back an honest empty owned
 * vector.
 *
 * Writes (glims_image_metadata_edit) validate the complete request,
 * duplicate the current metadata privately (gimp_metadata_duplicate, or
 * gimp_metadata_new when the image has none) and apply the native
 * GExiv2 set/clear ONLY on that copy; the image is then updated through
 * the single native setter gimp_image_set_metadata (image, copy, TRUE),
 * which pushes exactly one GIMP_UNDO_IMAGE_METADATA step because the
 * copy is never the image's own object, and which takes its own
 * reference — the adapter releases its local reference right after.
 * Undo/redo restore the previous metadata object exactly
 * (gimpimageundo.c swaps a duplicate back with push_undo FALSE).
 *
 * Normalization (app/core/gimpimage-metadata.c, identical in all four
 * engine sets): gimp_image_set_metadata rewrites pixel size, bits per
 * sample, resolution and colorspace tags on the new metadata from the
 * image's own state. The facade therefore refuses SET and REMOVE on
 * exactly those tags (metadata_tag_protected) with UNSUPPORTED, before
 * any mutation, so no requested value can be overridden silently. Note
 * honestly: the FIRST metadata edit on an image that had none creates
 * the metadata and that same normalization then fills those tags —
 * native behavior, documented, not a requested-value override.
 */
#include "engine-private.h"
#include "metadata-xmp.h"

#include <string.h>

#include "core/gimp.h"
#include "core/gimpimage.h"
#include "core/gimpimage-metadata.h"

/* The tags gimp_image_set_metadata rewrites from the image's own state
 * on every metadata change (gimpimage-metadata.c,
 * gimp_image_metadata_update_{pixel_size,bits_per_sample,resolution,
 * colorspace}); all four engine sets carry the identical list. Editing
 * any of them is refused so normalization can never override a
 * requested value. */
static const char *const protected_tags[] = {
  "Exif.Image.ImageWidth",
  "Exif.Image.ImageLength",
  "Exif.Photo.PixelXDimension",
  "Exif.Photo.PixelYDimension",
  "Exif.Image.BitsPerSample",
  "Exif.Image.XResolution",
  "Exif.Image.YResolution",
  "Exif.Image.ResolutionUnit",
  "Exif.Photo.ColorSpace",
  "Xmp.exif.ColorSpace",
  "Exif.Iop.InteroperabilityIndex",
  "Exif.Nikon3.ColorSpace",
  "Exif.Canon.ColorSpace",
};

/* The XMP container type names gexiv2_metadata_try_get_tag_type reports
 * for structured XMP tags (alternatives without language qualifiers,
 * unordered and ordered arrays). */
static gboolean
xmp_container_type (const gchar *type)
{
  return type && (! g_strcmp0 (type, "XmpAlt") ||
                  ! g_strcmp0 (type, "XmpBag") ||
                  ! g_strcmp0 (type, "XmpSeq"));
}

static gboolean
metadata_tag_protected (const gchar *tag)
{
  for (gsize i = 0; i < G_N_ELEMENTS (protected_tags); i++)
    if (! strcmp (tag, protected_tags[i]))
      return TRUE;
  return FALSE;
}

/* A facade tag string is well formed: non-NULL, non-empty, valid UTF-8
 * and carrying one of the three native domain prefixes. */
static gboolean
valid_tag_name (const char *tag)
{
  return tag && *tag && g_utf8_validate (tag, -1, NULL) &&
         (g_str_has_prefix (tag, "Exif.") ||
          g_str_has_prefix (tag, "Iptc.") ||
          g_str_has_prefix (tag, "Xmp."));
}

/* The native registry's type name for `tag`, shared by the value read,
 * the edit and the tag descriptor so their registered-tag validation
 * cannot drift apart. The registry decides what a tag is: a well-formed
 * but unregistered name returns NULL with *status NOT_FOUND and the
 * registry's message, never guessed XML handling. */
static const gchar *
lookup_tag_type (const char *tag, GlimsStatus *status, char **error)
{
  GError      *gerror = NULL;
  const gchar *type   = gexiv2_metadata_try_get_tag_type (tag, &gerror);

  if (! type)
    {
      if (error)
        *error = g_strdup_printf ("The engine's metadata registry has no tag "
                                  "'%s'%s%s", tag,
                                  gerror && gerror->message ? ": " : "",
                                  gerror && gerror->message ? gerror->message : "");
      g_clear_error (&gerror);
      *status = GLIMS_STATUS_NOT_FOUND;
      return NULL;
    }
  *status = GLIMS_STATUS_OK;
  return type;
}

/* Copies a NULL-terminated native string vector into an OWNED facade
 * vector: `count` entries plus the NULL terminator, every string
 * duplicated. `src` may be NULL (the empty vector). The caller owns the
 * result and releases it with glims_free_metadata_strings. */
static char **
owned_string_vector (gchar **src,
                     int32_t *count)
{
  int32_t n = src ? (int32_t) g_strv_length (src) : 0;
  char  **out = g_new0 (char *, (gsize) n + 1);
  int32_t i;

  for (i = 0; i < n; i++)
    out[i] = g_strdup (src[i]);

  if (count)
    *count = n;
  return out;
}

void
glims_free_metadata_strings (char **strings)
{
  char **p;

  if (! strings)
    return;
  for (p = strings; *p; p++)
    g_free (*p);
  g_free (strings);
}

GlimsStatus
glims_image_metadata_tags (GlimsEngine *engine,
                           GlimsImageID id,
                           uint32_t     domain,
                           char       ***result,
                           int32_t      *count,
                           char        **error)
{
  GlimsOpenImage *open;
  GimpMetadata   *metadata;
  gchar         **tags = NULL;

  if (result)
    *result = NULL;
  if (count)
    *count = 0;
  if (! result || ! count)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (domain != GLIMS_METADATA_EXIF && domain != GLIMS_METADATA_IPTC &&
      domain != GLIMS_METADATA_XMP)
    {
      if (error)
        *error = strdup ("The metadata domain is unknown.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  /* Borrowed; NULL when the image carries no metadata at all — an
   * honest empty vector follows. */
  metadata = gimp_image_get_metadata (open->image);
  if (metadata)
    {
      switch (domain)
        {
        case GLIMS_METADATA_EXIF:
          tags = gexiv2_metadata_get_exif_tags (GEXIV2_METADATA (metadata));
          break;
        case GLIMS_METADATA_IPTC:
          tags = gexiv2_metadata_get_iptc_tags (GEXIV2_METADATA (metadata));
          break;
        case GLIMS_METADATA_XMP:
          tags = gexiv2_metadata_get_xmp_tags (GEXIV2_METADATA (metadata));
          break;
        }
    }

  *result = owned_string_vector (tags, count);
  g_strfreev (tags);

  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_metadata_values (GlimsEngine *engine,
                             GlimsImageID id,
                             const char  *tag,
                             char       ***result,
                             int32_t      *count,
                             char        **error)
{
  GlimsOpenImage *open;
  GimpMetadata   *metadata;
  GError         *gerror = NULL;
  const gchar    *type;
  gchar         **values = NULL;

  if (result)
    *result = NULL;
  if (count)
    *count = 0;
  if (! result || ! count)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (! valid_tag_name (tag))
    {
      if (error)
        *error = strdup ("A metadata tag must be a nonempty UTF-8 string "
                         "starting with \"Exif.\", \"Iptc.\" or \"Xmp.\".");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  /* The native registry decides what a tag is; a well-formed but
   * unregistered name is NOT_FOUND, never guessed XML handling. */
  {
    GlimsStatus registry_status;
    type = lookup_tag_type (tag, &registry_status, error);
    if (! type)
      return registry_status;
  }

  metadata = gimp_image_get_metadata (open->image);   /* borrowed, may be NULL */
  if (metadata)
    {
      values = gexiv2_metadata_try_get_tag_multiple (GEXIV2_METADATA (metadata),
                                                      tag, &gerror);
      if (gerror)
        {
          GlimsStatus status = glims_fail (error, gerror,
                                           "The engine could not read the tag.");
          g_clear_error (&gerror);
          return status;
        }
    }
  /* values stays NULL, i.e. array[0] == NULL, when the tag is absent:
   * an honest empty owned vector, not an error. */

  *result = owned_string_vector (values, count);
  g_strfreev (values);

  return GLIMS_STATUS_OK;
}

/* Compare complete native metadata before trusting the engine's XML
 * duplicate. Its serializer can cap ancestor arrays or shorten tag names.
 * EXIF/IPTC use raw values; XMP compares the complete generated packet so
 * language qualifiers and container structure remain part of the check.
 * A comparison error fails closed: it never authorizes a replacement. */
static gboolean
metadata_equal_native (GimpMetadata *left, GimpMetadata *right)
{
  guint domain;
  if (! left || ! right)
    return left == right;
  for (domain = 0; domain < 3; domain++)
    {
      gchar **a = domain == 0 ? gexiv2_metadata_get_exif_tags (GEXIV2_METADATA (left)) :
                  domain == 1 ? gexiv2_metadata_get_iptc_tags (GEXIV2_METADATA (left)) :
                                gexiv2_metadata_get_xmp_tags (GEXIV2_METADATA (left));
      gchar **b = domain == 0 ? gexiv2_metadata_get_exif_tags (GEXIV2_METADATA (right)) :
                  domain == 1 ? gexiv2_metadata_get_iptc_tags (GEXIV2_METADATA (right)) :
                                gexiv2_metadata_get_xmp_tags (GEXIV2_METADATA (right));
      guint n = a ? g_strv_length (a) : 0;
      gboolean equal = n == (b ? g_strv_length (b) : 0);
      guint index;
      for (index = 0; equal && index < n; index++)
        {
          GError *failure = NULL;
          GBytes *raw_a, *raw_b;
          equal = ! strcmp (a[index], b[index]);
          if (! equal || domain == 2)
            continue;
          /* Core normalizes these image facts and can store the same
           * number with a different EXIF integer width on duplication. */
          if (domain == 0 && metadata_tag_protected (a[index]))
            {
              gchar **values_a = gexiv2_metadata_try_get_tag_multiple (GEXIV2_METADATA (left), a[index], &failure);
              gchar **values_b = NULL;
              if (! failure)
                values_b = gexiv2_metadata_try_get_tag_multiple (GEXIV2_METADATA (right), b[index], &failure);
              equal = ! failure && values_a && values_b &&
                      g_strv_equal ((const gchar * const *) values_a, (const gchar * const *) values_b);
              g_clear_error (&failure);
              g_strfreev (values_a);
              g_strfreev (values_b);
              continue;
            }
          raw_a = gexiv2_metadata_try_get_tag_raw (GEXIV2_METADATA (left), a[index], &failure);
          if (failure || ! raw_a)
            {
              g_clear_error (&failure);
              if (raw_a) g_bytes_unref (raw_a);
              equal = FALSE;
              break;
            }
          raw_b = gexiv2_metadata_try_get_tag_raw (GEXIV2_METADATA (right), b[index], &failure);
          equal = ! failure && raw_b && g_bytes_equal (raw_a, raw_b);
          g_clear_error (&failure);
          g_bytes_unref (raw_a);
          if (raw_b) g_bytes_unref (raw_b);
        }
      if (equal && domain == 2 && n > 0)
        {
          GError *failure = NULL;
          gchar *packet_a, *packet_b;
          GExiv2XmpFormatFlags flags = GEXIV2_OMIT_PACKET_WRAPPER |
                                       GEXIV2_USE_COMPACT_FORMAT |
                                       GEXIV2_OMIT_ALL_FORMATTING;
          packet_a = gexiv2_metadata_try_generate_xmp_packet (GEXIV2_METADATA (left), flags, 0, &failure);
          if (failure || ! packet_a)
            {
              g_clear_error (&failure);
              g_free (packet_a);
              equal = FALSE;
            }
          else
            {
              packet_b = gexiv2_metadata_try_generate_xmp_packet (GEXIV2_METADATA (right), flags, 0, &failure);
              gchar *structure_a = glims_metadata_xmp_structure (packet_a);
              gchar *structure_b = packet_b ? glims_metadata_xmp_structure (packet_b) : NULL;
              equal = ! failure && structure_a && structure_b && ! strcmp (structure_a, structure_b);
              g_free (structure_a);
              g_free (structure_b);
              g_clear_error (&failure);
              g_free (packet_a);
              g_free (packet_b);
            }
        }
      g_strfreev (a);
      g_strfreev (b);
      if (! equal)
        return FALSE;
    }
  return TRUE;
}

GlimsStatus
glims_image_metadata_edit (GlimsEngine        *engine,
                           GlimsImageID        id,
                           const char         *tag,
                           uint32_t            operation,
                           const char *const  *values,
                           int32_t             count,
                           char              **error)
{
  GlimsOpenImage *open;
  GimpMetadata   *current, *copy;
  GError         *gerror = NULL;
  const gchar    *type;
  gboolean        is_xmp, is_container, present, noop = FALSE, ok;
  GlimsStatus     status;
  int32_t         i, n = 0;
  gchar         **current_values = NULL;

  /* The complete request is validated before anything is touched. */
  if (! valid_tag_name (tag))
    {
      if (error)
        *error = strdup ("A metadata tag must be a nonempty UTF-8 string "
                         "starting with \"Exif.\", \"Iptc.\" or \"Xmp.\".");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (operation != GLIMS_METADATA_SET && operation != GLIMS_METADATA_REMOVE)
    {
      if (error)
        *error = strdup ("The metadata operation is unknown: use SET or REMOVE.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  if (operation == GLIMS_METADATA_REMOVE)
    {
      if (values != NULL || count != 0)
        {
          if (error)
            *error = strdup ("REMOVE takes no values.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
    }
  else
    {
      if (count < 1 || ! values)
        {
          if (error)
            *error = strdup ("SET needs at least one value; an empty value "
                             "list is refused — use REMOVE to erase the tag.");
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
      for (i = 0; i < count; i++)
        if (! values[i] || ! g_utf8_validate (values[i], -1, NULL))
          {
            if (error)
              *error = strdup ("Every metadata value must be a non-NULL valid "
                               "UTF-8 string.");
            return GLIMS_STATUS_INVALID_ARGUMENT;
          }
    }

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  /* Native registered-tag validation: the registry decides, unknown
   * names are NOT_FOUND with its message. */
  type = lookup_tag_type (tag, &status, error);
  if (! type)
    return status;

  /* Tags the native setter rewrites from the image's own state are
   * refused outright, so normalization can never override a requested
   * value (see the file header). */
  if (metadata_tag_protected (tag))
    {
      if (error)
        *error = g_strdup_printf ("'%s' is rewritten from the image's own "
                                  "dimensions, precision, resolution or color "
                                  "space on every metadata change and cannot "
                                  "be edited directly.", tag);
      return GLIMS_STATUS_UNSUPPORTED;
    }

  is_xmp       = g_str_has_prefix (tag, "Xmp.");
  is_container = is_xmp && xmp_container_type (type);

  /* XMP language alternatives (LangAlt) carry xml:lang qualifiers a
   * plain string vector cannot represent faithfully. */
  if (is_xmp && type && ! g_strcmp0 (type, "LangAlt"))
    {
      if (error)
        *error = g_strdup_printf ("'%s' is a language-alternative (LangAlt) "
                                  "tag; xml:lang qualifiers cannot be edited "
                                  "through a plain string vector.", tag);
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* The private copy every edit runs on; created empty when the image
   * has no metadata yet. Owned by this call. */
  current = gimp_image_get_metadata (open->image);   /* borrowed */
  copy = current ? gimp_metadata_duplicate (current) : gimp_metadata_new ();
  if (! copy)
    return glims_fail (error, NULL, "The image metadata could not be duplicated.");
  if (current && ! metadata_equal_native (current, copy))
    {
      g_object_unref (copy);
      if (error) *error = strdup ("This metadata cannot be copied without changing unrelated tags; the image was left untouched.");
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* A NEW Xmp Bag/Seq/Alt tag needs a chosen container type, which a
   * bare string vector cannot supply; existing containers are edited
   * through the multiple-value setter below. */
  present = gexiv2_metadata_try_has_tag (GEXIV2_METADATA (copy), tag, &gerror);
  if (gerror)
    {
      status = glims_fail (error, gerror, "The engine could not inspect the tag.");
      g_clear_error (&gerror);
      g_object_unref (copy);
      return status;
    }
  if (is_container && ! present)
    {
      g_object_unref (copy);
      if (error)
        *error = g_strdup_printf ("'%s' is an XMP container (Bag/Seq/Alt) "
                                  "the image does not hold yet; a new one needs "
                                  "a chosen array type, which a plain string "
                                  "vector cannot provide.", tag);
      return GLIMS_STATUS_UNSUPPORTED;
    }

  /* A single-value tag must not silently keep only the last of several
   * requested values (the native multiple setter would do exactly
   * that), so more than one value requires native multi-value support:
   * repeatable Iptc tags and Xmp Bag/Seq/Alt — never any Exif tag. */
  if (operation == GLIMS_METADATA_SET && count > 1)
    {
      gboolean multi = gexiv2_metadata_try_tag_supports_multiple_values (
        GEXIV2_METADATA (copy), tag, &gerror);
      if (gerror)
        {
          status = glims_fail (error, gerror, "The engine could not inspect the tag.");
          g_clear_error (&gerror);
          g_object_unref (copy);
          return status;
        }
      if (! multi)
        {
          g_object_unref (copy);
          if (error)
            *error = g_strdup_printf ("'%s' holds a single value; passing %d "
                                      "values would silently keep only the last "
                                      "one.", tag, (int) count);
          return GLIMS_STATUS_INVALID_ARGUMENT;
        }
    }

  /* No-op detection on the CURRENT metadata, before the busy gate (a
   * no-op mutates nothing, like guide_put's same-position move):
   * REMOVE of an absent tag, and SET of the exact value list the tag
   * already holds, in the same order, succeed with zero undo. */
  if (operation == GLIMS_METADATA_REMOVE)
    {
      noop = ! present;
    }
  else
    {
      if (current)
        current_values = gexiv2_metadata_try_get_tag_multiple (
          GEXIV2_METADATA (current), tag, &gerror);
      if (gerror)
        {
          status = glims_fail (error, gerror, "The engine could not read the tag.");
          g_clear_error (&gerror);
          g_strfreev (current_values);
          g_object_unref (copy);
          return status;
        }
      n = current_values ? (int32_t) g_strv_length (current_values) : 0;
      noop = (n == count);
      for (i = 0; noop && i < n; i++)
        noop = current_values[i] && values[i] &&
               ! strcmp (current_values[i], values[i]);
      g_strfreev (current_values);
    }
  if (noop)
    {
      g_object_unref (copy);
      return GLIMS_STATUS_OK;
    }

  /* Readiness: a stroke, a filter preview or a plug-in refuses the
   * mutation before anything is touched. */
  status = glims_edit_ready (engine, open, error);
  if (status != GLIMS_STATUS_OK)
    {
      g_object_unref (copy);
      return status;
    }

  /* Apply on the PRIVATE copy only; the original metadata is untouched
   * on every path below until the single native setter. */
  if (operation == GLIMS_METADATA_REMOVE)
    ok = gexiv2_metadata_try_clear_tag (GEXIV2_METADATA (copy), tag, &gerror);
  else if (is_container || count > 1)
    {
      /* The facade input is count-bounded. GExiv2 consumes a strv, so
       * supply our own terminator rather than reading past the caller's
       * last pointer. The native setter copies the strings synchronously. */
      const gchar **terminated = g_new0 (const gchar *, (gsize) count + 1);
      for (i = 0; i < count; i++)
        terminated[i] = values[i];
      ok = gexiv2_metadata_try_set_tag_multiple (GEXIV2_METADATA (copy), tag,
                                                terminated, &gerror);
      g_free (terminated);
    }
  else
    ok = gexiv2_metadata_try_set_tag_string (GEXIV2_METADATA (copy), tag,
                                             values[0], &gerror);
  if (! ok || gerror)
    {
      status = glims_fail (error, gerror,
                           "The engine could not apply the metadata change.");
      g_clear_error (&gerror);
      g_object_unref (copy);
      return status;
    }

  /* Canonical native values can make an apparent string edit a no-op. */
  if (current && metadata_equal_native (current, copy))
    {
      g_object_unref (copy);
      return GLIMS_STATUS_OK;
    }
  /* Undo and XCF also use the native duplicate/serialization path. Do not
   * create metadata that cannot survive that path without changing it. */
  {
    GimpMetadata *roundtrip = gimp_metadata_duplicate (copy);
    gboolean preserved = roundtrip && metadata_equal_native (copy, roundtrip);
    if (roundtrip) g_object_unref (roundtrip);
    if (! preserved)
      {
        g_object_unref (copy);
        if (error) *error = strdup ("This change cannot preserve all metadata through Undo and save; the image was left untouched.");
        return GLIMS_STATUS_UNSUPPORTED;
      }
  }

  /* The single native setter: takes its own reference on the copy and
   * pushes exactly one GIMP_UNDO_IMAGE_METADATA step (the copy is never
   * the image's own object), then runs the documented normalization on
   * it. The adapter's local reference ends here. */
  gimp_image_set_metadata (open->image, copy, TRUE);
  g_object_unref (copy);

  return GLIMS_STATUS_OK;
}

/* ---- Tag descriptor (slot 128, read-only) ----------------------------- */

/* The facade value kind of a registered tag. Only the five structural
 * native type names map to a container kind; every other native type
 * name (Exif and Iptc scalar types, XmpText, anything a future engine
 * adds) maps through the native multiple-value capability — the native
 * name itself never crosses as an enum, it is only reported as the
 * bounded type_name string. */
static uint32_t
metadata_value_kind (const gchar *type, gboolean supports_multiple)
{
  if (type)
    {
      if (! g_strcmp0 (type, "LangAlt")) return GLIMS_METADATA_VALUE_LANG_ALT;
      if (! g_strcmp0 (type, "XmpBag"))  return GLIMS_METADATA_VALUE_BAG;
      if (! g_strcmp0 (type, "XmpSeq"))  return GLIMS_METADATA_VALUE_SEQ;
      if (! g_strcmp0 (type, "XmpAlt"))  return GLIMS_METADATA_VALUE_ALT;
    }
  return supports_multiple ? GLIMS_METADATA_VALUE_REPEATABLE
                           : GLIMS_METADATA_VALUE_SINGLE;
}

/* The TYPE/FORMAT policy bits of `tag`, mirroring exactly the refusals
 * glims_image_metadata_edit makes before any mutation, so the
 * descriptor and the edit path can never disagree: a normalization-
 * protected tag and a LangAlt tag refuse both operations (no bits); an
 * XMP container the image does not hold cannot be SET (a new container
 * needs a chosen array type) but REMOVE stays allowed as a no-op. The
 * bits say nothing about BUSY, locks or native validation: an actual
 * edit can still refuse, so a set bit never promises a write. */
static uint32_t
metadata_format_policy (const gchar *tag, const gchar *type, gboolean is_xmp,
                        gboolean is_container, gboolean present)
{
  if (metadata_tag_protected (tag))
    return 0;
  if (is_xmp && type && ! g_strcmp0 (type, "LangAlt"))
    return 0;
  if (is_container && ! present)
    return GLIMS_METADATA_FORMAT_SUPPORTS_REMOVE;
  return GLIMS_METADATA_FORMAT_SUPPORTS_SET | GLIMS_METADATA_FORMAT_SUPPORTS_REMOVE;
}

/* Copies the validated UTF-8 `text` into a bounded facade string field:
 * NUL-terminated, cut at most to size - 1 bytes and never inside a
 * multi-byte character (back off while the first excluded byte is a
 * UTF-8 continuation byte). The caller validated `text`; invalid native
 * bytes are refused before and never copied. */
static void
copy_bounded_utf8 (char *buffer, size_t size, const gchar *text)
{
  size_t length = strlen (text);

  if (length > size - 1)
    {
      length = size - 1;
      while (length > 0 && (text[length] & 0xC0) == 0x80)
        length--;
    }
  memcpy (buffer, text, length);
  buffer[length] = '\0';
}

/* A native registry string must be valid UTF-8; invalid bytes are
 * refused explicitly (FAILED), never copied silently. NULL is allowed
 * and reported as the empty string. */
static GlimsStatus
descriptor_string_utf8 (const gchar *text, const char *tag, const char *field,
                        char **error)
{
  if (text && ! g_utf8_validate (text, -1, NULL))
    {
      if (error)
        *error = g_strdup_printf ("The engine's registry %s of tag '%s' is "
                                  "not valid UTF-8 and was not copied.",
                                  field, tag);
      return GLIMS_STATUS_FAILED;
    }
  return GLIMS_STATUS_OK;
}

GlimsStatus
glims_image_metadata_tag_info (GlimsEngine          *engine,
                               GlimsImageID          id,
                               const char           *tag,
                               GlimsMetadataTagInfo *outInfo,
                               char                **error)
{
  GlimsOpenImage *open;
  GimpMetadata   *current, *probe;
  GError         *gerror = NULL;
  const gchar    *type, *label, *description;
  gboolean        is_xmp, is_container, present, supports_multiple;
  GlimsStatus     status;

  /* Size-versioned out: a NULL or undersized struct is refused before
   * anything is written. Once the size check passes, the caller's
   * buffer covers the whole struct, so every failure below resets it to
   * a safe all-zero descriptor and no write goes past the declared
   * size. */
  if (! outInfo)
    return GLIMS_STATUS_INVALID_ARGUMENT;
  if (outInfo->struct_size < sizeof (GlimsMetadataTagInfo))
    {
      if (error)
        *error = strdup ("outInfo is smaller than this facade's "
                         "GlimsMetadataTagInfo.");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }
  memset (outInfo, 0, sizeof *outInfo);
  outInfo->struct_size = sizeof *outInfo;

  if (! valid_tag_name (tag))
    {
      if (error)
        *error = strdup ("A metadata tag must be a nonempty UTF-8 string "
                         "starting with \"Exif.\", \"Iptc.\" or \"Xmp.\".");
      return GLIMS_STATUS_INVALID_ARGUMENT;
    }

  open = glims_lookup_image (engine, id);
  if (! open)
    return GLIMS_STATUS_NOT_FOUND;

  /* Registered-tag validation, shared with the reads and the edit. */
  type = lookup_tag_type (tag, &status, error);
  if (! type)
    return status;

  /* The registry's own label, description and type name (transfer
   * none); a registered tag has all three, but NULL reads as "". */
  label       = gexiv2_metadata_try_get_tag_label (tag, &gerror);
  if (gerror)
    return glims_fail (error, gerror, "The engine could not read the tag's label.");
  description = gexiv2_metadata_try_get_tag_description (tag, &gerror);
  if (gerror)
    return glims_fail (error, gerror, "The engine could not read the tag's description.");

  /* Invalid native bytes are refused explicitly, never copied. */
  status = descriptor_string_utf8 (type, tag, "type name", error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = descriptor_string_utf8 (label, tag, "label", error);
  if (status != GLIMS_STATUS_OK)
    return status;
  status = descriptor_string_utf8 (description, tag, "description", error);
  if (status != GLIMS_STATUS_OK)
    return status;

  /* Borrow the image's own metadata; when the image has none, answer
   * presence and multiple-value questions on a PRIVATE empty metadata
   * that is unref'd on every path below and never installed on the
   * image — no metadata creation, no dirty, no undo, no pixels. */
  current = gimp_image_get_metadata (open->image);   /* borrowed, may be NULL */
  probe   = current ? current : gimp_metadata_new ();
  if (! probe)
    return glims_fail (error, NULL, "The image metadata could not be created for inspection.");

  present = gexiv2_metadata_try_has_tag (GEXIV2_METADATA (probe), tag, &gerror);
  if (gerror)
    {
      status = glims_fail (error, gerror, "The engine could not inspect the tag.");
      g_clear_error (&gerror);
      if (probe != current)
        g_object_unref (probe);
      return status;
    }
  supports_multiple = gexiv2_metadata_try_tag_supports_multiple_values (
    GEXIV2_METADATA (probe), tag, &gerror);
  if (gerror)
    {
      status = glims_fail (error, gerror, "The engine could not inspect the tag.");
      g_clear_error (&gerror);
      if (probe != current)
        g_object_unref (probe);
      return status;
    }
  if (probe != current)
    g_object_unref (probe);

  /* Plain read: no glims_edit_ready gate — allowed while a stroke, a
   * filter preview or a plug-in holds the image. */
  is_xmp       = g_str_has_prefix (tag, "Xmp.");
  is_container = is_xmp && xmp_container_type (type);

  outInfo->present           = present;
  outInfo->supports_multiple = supports_multiple;
  outInfo->value_kind        = metadata_value_kind (type, supports_multiple);
  outInfo->format_policy     = metadata_format_policy (tag, type, is_xmp,
                                                       is_container, present);
  copy_bounded_utf8 (outInfo->label, sizeof outInfo->label, label ? label : "");
  copy_bounded_utf8 (outInfo->description, sizeof outInfo->description,
                     description ? description : "");
  copy_bounded_utf8 (outInfo->type_name, sizeof outInfo->type_name, type);

  return GLIMS_STATUS_OK;
}
