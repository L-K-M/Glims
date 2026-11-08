#include "../metadata-xmp.h"
#include <stdio.h>
#include <string.h>

static int failures;
static void pair (const char *name, const char *a, const char *b, gboolean equal)
{
  gchar *left = glims_metadata_xmp_structure (a);
  gchar *right = glims_metadata_xmp_structure (b);
  gboolean matches = left && right && !strcmp (left, right);
  if (!left || !right || matches != equal)
    { fprintf (stderr, "FAIL %s\n", name); failures++; }
  else
    printf ("ok %s\n", name);
  g_free (left); g_free (right);
}
static void refuses (const char *name, const char *xml)
{
  gchar *value = glims_metadata_xmp_structure (xml);
  if (value) { fprintf (stderr, "FAIL %s\n", name); failures++; }
  else printf ("ok %s\n", name);
  g_free (value);
}
int main (void)
{
  pair ("distinct CDATA values", "<p><![CDATA[A]]></p>", "<p><![CDATA[B]]></p>", FALSE);
  pair ("CDATA and ordinary text agree", "<p><![CDATA[A & B]]></p>", "<p>A &amp; B</p>", TRUE);
  pair ("attribute order", "<p a='1' b='2'/>", "<p b='2' a='1'/>", TRUE);
  pair ("description property order", "<rdf:Description><a>A</a><b>B</b></rdf:Description>",
        "<rdf:Description><b>B</b><a>A</a></rdf:Description>", TRUE);
  pair ("namespace identity", "<p xmlns:q='urn:a'><q:a>A</q:a></p>",
        "<p xmlns:q='urn:b'><q:a>A</q:a></p>", FALSE);
  pair ("sequence order", "<rdf:Seq><i>A</i><i>B</i></rdf:Seq>",
        "<rdf:Seq><i>B</i><i>A</i></rdf:Seq>", FALSE);
  pair ("bag order retained conservatively", "<rdf:Bag><i>A</i><i>B</i></rdf:Bag>",
        "<rdf:Bag><i>B</i><i>A</i></rdf:Bag>", FALSE);
  pair ("language qualifiers", "<rdf:li xml:lang='fr'>A</rdf:li>",
        "<rdf:li xml:lang='de'>A</rdf:li>", FALSE);
  pair ("leaf whitespace", "<p> A </p>", "<p>A</p>", FALSE);
  pair ("decoded entities", "<p>&#65;</p>", "<p>A</p>", TRUE);
  pair ("empty content", "<p/>", "<p></p>", TRUE);
  refuses ("malformed packet", "<p><a></p>");
  refuses ("mixed content", "<p>A<a/>B</p>");
  GString *deep = g_string_new (NULL);
  for (int i = 0; i < 129; i++) g_string_append (deep, "<p>");
  for (int i = 0; i < 129; i++) g_string_append (deep, "</p>");
  refuses ("excessive nesting", deep->str);
  g_string_free (deep, TRUE);
  printf ("%s: %d failures\n", failures ? "FAILED" : "PASSED", failures);
  return failures ? 1 : 0;
}
