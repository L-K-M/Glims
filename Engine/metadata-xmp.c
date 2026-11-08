#include "metadata-xmp.h"
#include <string.h>

/* XMP properties and namespace attributes can be emitted in a different
 * order by the engine's XML duplicate. Compare a structural representation
 * instead of packet byte order. Preserve every value, qualifier and array
 * order; only RDF Description properties and XML attributes are unordered. */
typedef struct
{
  gchar     *name;
  GString   *text;
  GPtrArray *attributes;
  GPtrArray *children;
} MetadataXmlFrame;

typedef struct
{
  GPtrArray *stack;
  gchar     *root;
} MetadataXmlState;

static void
metadata_xml_frame_free (gpointer data)
{
  MetadataXmlFrame *frame = data;
  g_free (frame->name);
  g_string_free (frame->text, TRUE);
  g_ptr_array_unref (frame->attributes);
  g_ptr_array_unref (frame->children);
  g_free (frame);
}

static gint
metadata_xml_string_compare (gconstpointer a, gconstpointer b)
{
  return g_strcmp0 (*(gchar * const *) a, *(gchar * const *) b);
}

static void
metadata_xml_part (GString *out, const gchar *part)
{
  g_string_append_printf (out, "%" G_GSIZE_FORMAT ":", strlen (part));
  g_string_append (out, part);
}

static void
metadata_xml_start (GMarkupParseContext *context, const gchar *name,
                    const gchar **names, const gchar **values,
                    gpointer data, GError **error)
{
  MetadataXmlState *state = data;
  MetadataXmlFrame *frame;
  if (state->stack->len >= 128)
    {
      g_set_error_literal (error, G_MARKUP_ERROR, G_MARKUP_ERROR_PARSE,
                           "Metadata nesting exceeds the comparison limit.");
      return;
    }
  frame = g_new0 (MetadataXmlFrame, 1);
  frame->name = g_strdup (name);
  frame->text = g_string_new (NULL);
  frame->attributes = g_ptr_array_new_with_free_func (g_free);
  frame->children = g_ptr_array_new_with_free_func (g_free);
  for (guint i = 0; names[i]; i++)
    {
      GString *attribute = g_string_new (NULL);
      metadata_xml_part (attribute, names[i]);
      metadata_xml_part (attribute, values[i]);
      g_ptr_array_add (frame->attributes, g_string_free (attribute, FALSE));
    }
  g_ptr_array_sort (frame->attributes, metadata_xml_string_compare);
  g_ptr_array_add (state->stack, frame);
}

static void
metadata_xml_text (GMarkupParseContext *context, const gchar *text,
                   gsize length, gpointer data, GError **error)
{
  MetadataXmlState *state = data;
  if (state->stack->len)
    {
      MetadataXmlFrame *frame = g_ptr_array_index (state->stack, state->stack->len - 1);
      g_string_append_len (frame->text, text, length);
    }
}

static void
metadata_xml_end (GMarkupParseContext *context, const gchar *name,
                  gpointer data, GError **error)
{
  MetadataXmlState *state = data;
  MetadataXmlFrame *frame = g_ptr_array_steal_index (state->stack, state->stack->len - 1);
  GString *out = g_string_new (NULL);
  metadata_xml_part (out, frame->name);
  g_string_append_printf (out, "A%u:", frame->attributes->len);
  for (guint i = 0; i < frame->attributes->len; i++)
    metadata_xml_part (out, g_ptr_array_index (frame->attributes, i));
  if (frame->children->len)
    {
      for (const gchar *p = frame->text->str; *p; p++)
        if (! g_ascii_isspace (*p))
          {
            g_set_error_literal (error, G_MARKUP_ERROR, G_MARKUP_ERROR_PARSE,
                                 "Mixed metadata content cannot be compared safely.");
            g_string_free (out, TRUE);
            metadata_xml_frame_free (frame);
            return;
          }
      if (! strcmp (frame->name, "rdf:Description"))
        g_ptr_array_sort (frame->children, metadata_xml_string_compare);
      g_string_append_printf (out, "C%u:", frame->children->len);
      for (guint i = 0; i < frame->children->len; i++)
        metadata_xml_part (out, g_ptr_array_index (frame->children, i));
    }
  else
    {
      g_string_append_c (out, 'T');
      metadata_xml_part (out, frame->text->str);
    }
  metadata_xml_frame_free (frame);
  if (state->stack->len)
    {
      MetadataXmlFrame *parent = g_ptr_array_index (state->stack, state->stack->len - 1);
      g_ptr_array_add (parent->children, g_string_free (out, FALSE));
    }
  else
    {
      g_free (state->root);
      state->root = g_string_free (out, FALSE);
    }
}

gchar *
glims_metadata_xmp_structure (const gchar *packet)
{
  GMarkupParser parser = { metadata_xml_start, metadata_xml_end, metadata_xml_text, NULL, NULL };
  MetadataXmlState state = { g_ptr_array_new_with_free_func (metadata_xml_frame_free), NULL };
  GError *error = NULL;
  GMarkupParseContext *context = g_markup_parse_context_new (&parser, G_MARKUP_TREAT_CDATA_AS_TEXT, &state, NULL);
  gboolean valid = g_markup_parse_context_parse (context, packet, -1, &error) &&
                   g_markup_parse_context_end_parse (context, &error);
  g_markup_parse_context_free (context);
  g_ptr_array_unref (state.stack);
  g_clear_error (&error);
  if (! valid)
    g_clear_pointer (&state.root, g_free);
  return state.root;
}

