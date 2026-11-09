/*
 * Engine-internal READ-ONLY XMP LangAlt reader; contract and evidence:
 * docs/metadata-language-read.md. No facade slot, no writer; reads never
 * modify the metadata.
 */
#include "engine-private.h"
#include "metadata-language.h"
#include <string.h>
#define LANGALT_MAX_PACKET ((gsize) 2 * 1024 * 1024)
#define LANGALT_MAX_DEPTH 32
#define LANGALT_MAX_PAIRS 256
#define LANGALT_MAX_TEXT ((gsize) 1024 * 1024)
#define LANGALT_XML_NS "http://www.w3.org/XML/1998/namespace"
#define LANGALT_RDF_ALT "http://www.w3.org/1999/02/22-rdf-syntax-ns#" "\001" "Alt"
#define LANGALT_RDF_LI "http://www.w3.org/1999/02/22-rdf-syntax-ns#" "\001" "li"
/* Semantic refusals carry this domain (UNSUPPORTED); other parser errors are native failures (FAILED). */
#define LANGALT_ERROR (g_quark_from_static_string ("glims-metadata-language"))
enum { ROLE_NONE, ROLE_PROP, ROLE_ALT, ROLE_LI };

typedef struct
{
  char *name;      /* expanded "uri" '\001' "local" */
  GHashTable *own; /* this element's own xmlns declarations */
  int role; guint attrs, children;     /* non-xmlns attributes */
  char *lang;      /* ROLE_LI: xml:lang value */
  GString *text;
} LangAltFrame;
typedef struct
{
  GPtrArray *stack, *pairs;
  char *target; const char *rdf_alt, *rdf_li;
  gboolean found; gsize text_bytes;
} LangAltState;
static void
langalt_pair_free (gpointer data)
{
  GlimsMetadataLanguagePair *pair = data;
  if (pair)
    g_free (pair->language), g_free (pair->text), g_free (pair);
}
static void
langalt_frame_free (gpointer data)
{
  LangAltFrame *f = data;
  g_free (f->name);
  if (f->own) g_hash_table_unref (f->own);
  g_free (f->lang);
  if (f->text) g_string_free (f->text, TRUE);
  g_free (f);
}
static void
langalt_reject (GError **error, const char *message)
{
  g_set_error_literal (error, LANGALT_ERROR, 0, message);
}
static char *
langalt_expand (LangAltState *state, GHashTable *extra, const char *name)
{
  const char *colon = strchr (name, ':'), *local = name, *uri = NULL;
  char *prefix;
  guint i;
  if (colon && colon - name == 3 && ! strncmp (name, "xml", 3))
    return g_strconcat (LANGALT_XML_NS, "\001", colon + 1, NULL);
  prefix = colon ? g_strndup (name, (gsize) (colon - name)) : g_strdup ("");
  if (colon)
    local = colon + 1;
  uri = extra ? g_hash_table_lookup (extra, prefix) : NULL;
  for (i = state->stack->len; ! uri && i > 0; i--)
    uri = g_hash_table_lookup (((LangAltFrame *) g_ptr_array_index (state->stack, i - 1))->own, prefix);
  g_free (prefix);
  return uri ? g_strconcat (uri, "\001", local, NULL) : NULL;
}
static void
langalt_start (GMarkupParseContext *context, const gchar *name,
               const gchar **attr_names, const gchar **attr_values,
               gpointer data, GError **error)
{
  LangAltState *state = data;
  LangAltFrame *parent = state->stack->len
    ? g_ptr_array_index (state->stack, state->stack->len - 1) : NULL;
  LangAltFrame *frame = g_new0 (LangAltFrame, 1);
  const char *reject = NULL;
  int first_attr = -1, role = ROLE_NONE;
  guint i;
  (void) context;
  /* A short packet can repeat very long namespace names many times.
   * Bound expanded-name work as well as packet bytes and tree depth. */
  if (strlen (name) > 512)
    { langalt_frame_free (frame); langalt_reject (error, "An XML name exceeds the bound."); return; }
  for (i = 0; attr_names[i]; i++)
    if (strlen (attr_names[i]) > 512 ||
        ((! strcmp (attr_names[i], "xmlns") || g_str_has_prefix (attr_names[i], "xmlns:")) &&
         strlen (attr_values[i]) > 4096))
      { langalt_frame_free (frame); langalt_reject (error, "An XML namespace exceeds the bound."); return; }
  if (state->stack->len >= LANGALT_MAX_DEPTH)
    reject = "The XMP packet nests deeper than the reader's bound.";
  else
    {
      frame->own = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
      for (i = 0; attr_names[i]; i++)
        if (! strcmp (attr_names[i], "xmlns"))
          g_hash_table_insert (frame->own, g_strdup (""), g_strdup (attr_values[i]));
        else if (! strncmp (attr_names[i], "xmlns:", 6))
          g_hash_table_insert (frame->own, g_strdup (attr_names[i] + 6), g_strdup (attr_values[i]));
        else { if (first_attr < 0) first_attr = (int) i; frame->attrs++; }
      frame->name = langalt_expand (state, frame->own, name);
      if (! frame->name)
        reject = "The XMP packet uses an undeclared namespace prefix.";
      else if (parent && parent->role == ROLE_NONE && ! strcmp (frame->name, state->target))
        {
          if (state->found || frame->attrs)
            reject = "The property is duplicated or qualified.";
          else { state->found = TRUE; role = ROLE_PROP; }
        }
      else if (parent && parent->role == ROLE_PROP && ! strcmp (frame->name, state->rdf_alt))
        {
          if (parent->children++) reject = "The property has more than one rdf:Alt container.";
          else role = ROLE_ALT;
        }
      else if (parent && parent->role == ROLE_ALT && ! strcmp (frame->name, state->rdf_li))
        role = ROLE_LI;
      else if (parent && parent->role != ROLE_NONE)
        reject = "Unsupported nesting inside the language-alternative property.";
      if (! reject && (role == ROLE_PROP || role == ROLE_ALT) && frame->attrs)
        reject = "The container carries unsupported qualifiers.";
      if (! reject && role == ROLE_LI &&
          (frame->attrs != 1 || strcmp (attr_names[first_attr], "xml:lang")))
        reject = "Each rdf:li must carry exactly the xml:lang qualifier.";
      if (! reject)
        {
          frame->role = role;
          frame->text = g_string_new (NULL);
          if (role == ROLE_LI) frame->lang = g_strdup (attr_values[first_attr]);
        }
    }
  if (reject)
    { langalt_frame_free (frame); langalt_reject (error, reject); return; }
  g_ptr_array_add (state->stack, frame);
}
static void
langalt_text (GMarkupParseContext *context, const gchar *text, gsize length,
              gpointer data, GError **error)
{
  LangAltState *state = data;
  LangAltFrame *frame = state->stack->len
    ? g_ptr_array_index (state->stack, state->stack->len - 1) : NULL;
  (void) context; (void) error;
  if (frame)
    g_string_append_len (frame->text, text, length);
}
static void
langalt_end (GMarkupParseContext *context, const gchar *name,
             gpointer data, GError **error)
{
  LangAltState *state = data;
  LangAltFrame *frame = g_ptr_array_steal_index (state->stack, state->stack->len - 1);
  const char *text = frame->text->str;
  gsize length = frame->text->len;
  const char *reject = NULL;
  (void) context; (void) name;
  if (frame->role == ROLE_LI)
    {
      if (! frame->lang || ! *frame->lang || strlen (frame->lang) > 255 || ! g_utf8_validate (frame->lang, -1, NULL) ||
          ! g_utf8_validate (text, (gssize) length, NULL) || length == 0 ||
          memchr (text, '\0', length))
        reject = "An rdf:li entry is empty, not valid UTF-8 or holds a NUL.";
      else if (state->pairs->len >= LANGALT_MAX_PAIRS ||
               state->text_bytes + length > LANGALT_MAX_TEXT)
        reject = "The language-alternative map exceeds its bounds.";
      else
        {
          char *fold = g_utf8_casefold (frame->lang, -1);
          gboolean duplicate = FALSE;
          guint i;
          for (i = 0; i < state->pairs->len && ! duplicate; i++)
            {
              char *other_fold = g_utf8_casefold (
                ((GlimsMetadataLanguagePair *) g_ptr_array_index (state->pairs, i))->language, -1);
              duplicate = ! strcmp (fold, other_fold);
              g_free (other_fold);
            }
          g_free (fold);
          if (duplicate)
            reject = "Duplicate language key (case-insensitive) in the map.";
          else
            {
              GlimsMetadataLanguagePair *pair = g_new (GlimsMetadataLanguagePair, 1);

              pair->language = g_strdup (frame->lang);
              pair->text = g_strdup (text);
              g_ptr_array_add (state->pairs, pair);
              state->text_bytes += length;
            }
        }
    }
  else if ((frame->role == ROLE_PROP || frame->role == ROLE_ALT) &&
           length != strspn (text, " \t\r\n"))
    reject = "The container holds mixed content.";
  if (reject)
    langalt_reject (error, reject);
  langalt_frame_free (frame);
}
#define LANGALT_FAIL(code, ...) \
  do { status = (code); if (error) *error = g_strdup_printf (__VA_ARGS__); goto out; } while (0)
#define LANGALT_FAIL_NATIVE(fallback) \
  do { status = glims_fail (error, g_steal_pointer (&gerror), (fallback)); goto out; } while (0)
#define LANGALT_INVALID(msg) \
  do { if (error) *error = strdup (msg); return GLIMS_STATUS_INVALID_ARGUMENT; } while (0)
GlimsStatus
glims_metadata_language_read (GimpMetadata *metadata, const char *root,
                             GPtrArray **out, char **error)
{
  GMarkupParser parser = { langalt_start, langalt_end, langalt_text, NULL, NULL };
  LangAltState state;
  GMarkupParseContext *context;
  GError *gerror = NULL;
  GlimsMetadataLanguagePair *pair; const gchar *type;
  const char *dot2;
  gchar *property = NULL, *ns_uri = NULL, *packet = NULL, **native = NULL, *entry;
  GPtrArray *pairs = NULL;
  GlimsStatus status = GLIMS_STATUS_OK;
  gboolean valid, exact, present; guint i, n, k;
  if (out) *out = NULL;
  if (! out || ! metadata || ! root || ! *root || ! g_utf8_validate (root, -1, NULL))
    LANGALT_INVALID ("Needs an out pointer, a metadata object and a nonempty UTF-8 root tag.");
  if (! (g_str_has_prefix (root, "Xmp.") || g_str_has_prefix (root, "Exif.") ||
         g_str_has_prefix (root, "Iptc.")))
    LANGALT_INVALID ("A metadata tag must start with \"Xmp.\", \"Exif.\" or \"Iptc.\".");
  dot2 = strchr (root, '.');
  dot2 = dot2 ? strchr (dot2 + 1, '.') : NULL;
  if (! g_str_has_prefix (root, "Xmp.") || ! dot2 || strchr (dot2 + 1, '.') ||
      strpbrk (root, "[]"))
    LANGALT_FAIL (GLIMS_STATUS_UNSUPPORTED, "'%s' is not a plain XMP root property.", root);
  property = g_strdup (dot2 + 1);
  type = gexiv2_metadata_try_get_tag_type (root, &gerror);
  if (! type)
    {
      if (error)
        *error = g_strdup_printf ("The registry has no tag '%s'%s%s", root,
                                  gerror ? ": " : "", gerror ? gerror->message : "");
      g_clear_error (&gerror);
      status = GLIMS_STATUS_NOT_FOUND;
      goto out;
    }
  if (strcmp (type, "LangAlt"))
    LANGALT_FAIL (GLIMS_STATUS_UNSUPPORTED, "'%s' is registered as '%s', not a LangAlt tag.",
                 root, type);
  ns_uri = gexiv2_metadata_try_get_xmp_namespace_for_tag (root, &gerror);
  if (! ns_uri)
    LANGALT_FAIL_NATIVE ("The engine could not resolve the tag's XMP namespace.");
  present = gexiv2_metadata_try_has_tag (GEXIV2_METADATA (metadata), root, &gerror);
  if (gerror)
    LANGALT_FAIL_NATIVE ("The engine could not inspect the tag.");
  if (! present)
    LANGALT_FAIL (GLIMS_STATUS_NOT_FOUND, "The metadata does not hold '%s'.", root);
  packet = gexiv2_metadata_try_generate_xmp_packet (GEXIV2_METADATA (metadata),
    GEXIV2_OMIT_PACKET_WRAPPER | GEXIV2_USE_COMPACT_FORMAT | GEXIV2_OMIT_ALL_FORMATTING, 0,
    &gerror);
  if (! packet || gerror)
    LANGALT_FAIL_NATIVE ("The engine could not generate the current XMP packet.");
  if (strlen (packet) > LANGALT_MAX_PACKET)
    LANGALT_FAIL (GLIMS_STATUS_UNSUPPORTED, "The generated XMP packet exceeds the size bound.");
  pairs = g_ptr_array_new_with_free_func (langalt_pair_free);
  memset (&state, 0, sizeof state);
  state.stack = g_ptr_array_new_with_free_func (langalt_frame_free);
  state.pairs = pairs;
  state.target = g_strconcat (ns_uri, "\001", property, NULL);
  state.rdf_alt = LANGALT_RDF_ALT;
  state.rdf_li = LANGALT_RDF_LI;
  context = g_markup_parse_context_new (&parser, G_MARKUP_TREAT_CDATA_AS_TEXT, &state, NULL);
  valid = g_markup_parse_context_parse (context, packet, -1, &gerror) &&
          g_markup_parse_context_end_parse (context, &gerror);
  g_markup_parse_context_free (context);
  g_ptr_array_unref (state.stack);
  g_free (state.target);
  if (! valid)
    {
      if (gerror && g_error_matches (gerror, LANGALT_ERROR, 0))
        {
          if (error) *error = g_strdup (gerror->message);
          status = GLIMS_STATUS_UNSUPPORTED;
        }
      else
        status = glims_fail (error, g_steal_pointer (&gerror), "The XMP packet could not be parsed.");
      g_clear_error (&gerror);
      goto out;
    }
  if (! state.found || pairs->len == 0)
    LANGALT_FAIL (GLIMS_STATUS_UNSUPPORTED, "No simple rdf:Alt of rdf:li in the packet.");
  native = gexiv2_metadata_try_get_tag_multiple (GEXIV2_METADATA (metadata), root, &gerror);
  if (! native || gerror)
    LANGALT_FAIL_NATIVE ("The engine could not read the tag's native value vector.");
  n = g_strv_length (native);
  if (n != pairs->len)
    LANGALT_FAIL (GLIMS_STATUS_UNSUPPORTED, "Native vector has %u entries, packet parsed %u.",
                 n, pairs->len);
  /* The explicit-prefix strings must equal the native strings element for
   * element, in the native writer's order (the case-insensitively default
   * key first, then every key not byte-equal to "x-default" in packet
   * order); the k < n guard refuses the case-variant x-default quirk. */
#define LANGALT_CHECK(idx) \
  do { \
    pair = g_ptr_array_index (pairs, (idx)); \
    entry = g_strdup_printf ("lang=\"%s\" %s", pair->language, pair->text); \
    exact = k < n && ! strcmp (entry, native[k++]); \
    g_free (entry); \
    if (! exact) LANGALT_FAIL (GLIMS_STATUS_UNSUPPORTED, "Native vector mismatch."); \
  } while (0)
  for (k = 0, i = 0; i < pairs->len; i++)
    if (! g_ascii_strcasecmp (((GlimsMetadataLanguagePair *) g_ptr_array_index (pairs, i))->language,
                             "x-default"))
      LANGALT_CHECK (i);
  for (i = 0; i < pairs->len; i++)
    if (strcmp (((GlimsMetadataLanguagePair *) g_ptr_array_index (pairs, i))->language, "x-default"))
      LANGALT_CHECK (i);
  if (k != n)
    LANGALT_FAIL (GLIMS_STATUS_UNSUPPORTED, "The native value vector does not match.");
  *out = pairs;
  pairs = NULL;
out:
  if (pairs)
    g_ptr_array_unref (pairs);
  g_strfreev (native);
  g_free (packet);
  g_free (ns_uri);
  g_free (property);
  return status;
}
