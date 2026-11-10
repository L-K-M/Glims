/* Standalone GLib-only parser tests. Literal malformed text is intentional:
 * never normalize duplicate keys/groups through GKeyFile before decoding. */
#include "effect-archive.h"
#include <stdio.h>
#include <string.h>
#pragma clang diagnostic ignored "-Wdeclaration-after-statement"

int main (void);
static int checks, failures;
#define CHECK(c,t) do { gboolean ok_=(c);checks++;printf("%s %s\n",ok_?"ok  ":"FAIL",t);if(!ok_)failures++; } while(0)
#define SCOPE "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
#define HASH  "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
#define HEADER "[archive]\nversion=1\ncount=1\nscope=" SCOPE "\n"
#define RECORD "[effect0]\ntattoo=7\nindex=0\nfingerprint=" HASH "\nblend=rgb-linear\ncomposite-space=rgb-non-linear\ncomposite-mode=clip-to-backdrop\nidentities=21\n"
static const char valid[] = HEADER RECORD;
static gchar *replace(const char *text,const char *old,const char *value) {
  const char *at=strstr(text,old);g_assert(at!=NULL);
  GString *s=g_string_new_len(text,at-text);g_string_append(s,value);g_string_append(s,at+strlen(old));return g_string_free(s,FALSE);
}
static GlimsEffectArchiveRecord *record(guint32 tattoo,guint32 index,guint32 mask,const char *symbol) {
  GlimsEffectArchiveRecord *r=g_new0(GlimsEffectArchiveRecord,1);r->tattoo=tattoo;r->index=index;r->identities=mask;
  r->fingerprint=g_strdup(HASH);r->blend_space=g_strdup(symbol);r->composite_space=g_strdup("rgb-non-linear");r->composite_mode=g_strdup("clip-to-backdrop");return r;
}
static GlimsEffectArchive *archive(guint count) {
  GlimsEffectArchive *a=glims_effect_archive_new();a->scope=g_strdup(SCOPE);
  for(guint i=0;i<count;i++)g_ptr_array_add(a->records,record(7+i,i?4095:0,i?32:21,"rgb-linear"));return a;
}
static void reject(const char *label,const void *bytes,gsize length) {
  GError *error=NULL;GlimsEffectArchive *a=glims_effect_archive_decode(bytes,length,&error);
  CHECK(a==NULL&&error!=NULL,label);glims_effect_archive_free(a);g_clear_error(&error);
}
static void reject_text(const char *label,const char *text) { reject(label,text,strlen(text)); }
static void reject_change(const char *label,const char *old,const char *value) {
  gchar *text=replace(valid,old,value);reject_text(label,text);g_free(text);
}
static void accept_text(const char *label,const char *text) {
  GError *error=NULL;GlimsEffectArchive *a=glims_effect_archive_decode(text,strlen(text),&error);
  CHECK(a!=NULL&&error==NULL,label);glims_effect_archive_free(a);g_clear_error(&error);
}
static void reject_encode(const char *label,GlimsEffectArchive *a) {
  gchar *bytes=(gchar *)(guintptr)1;gsize length=73;GError *error=NULL;
  gboolean success=glims_effect_archive_encode(a,&bytes,&length,&error);
  CHECK(!success&&bytes==NULL&&length==0&&error!=NULL,label);if(success)g_free(bytes);g_clear_error(&error);
}
static void roundtrip(guint count) {
  GlimsEffectArchive *a=archive(count),*copy=NULL;gchar *bytes=NULL;gsize length=0;GError *error=NULL;
  gboolean encoded=glims_effect_archive_encode(a,&bytes,&length,&error);
  CHECK(encoded&&bytes&&length>0&&length<=GLIMS_EFFECT_ARCHIVE_MAX_BYTES&&error==NULL,"legitimate archive encodes within byte bound");
  if(encoded)copy=glims_effect_archive_decode(bytes,length,&error);
  gboolean independent=copy&&copy->scope!=a->scope&&copy->records!=a->records&&copy->records->len==count;
  for(guint i=0;independent&&i<count;i++) {
    GlimsEffectArchiveRecord *x=g_ptr_array_index(a->records,i),*y=g_ptr_array_index(copy->records,i);
    independent=x!=y&&x->fingerprint!=y->fingerprint&&x->blend_space!=y->blend_space&&x->composite_space!=y->composite_space&&x->composite_mode!=y->composite_mode;
  }
  CHECK(independent&&error==NULL,"decoded archive owns separate arrays, records and every string");
  g_free(bytes);glims_effect_archive_free(a); /* decoded data must outlive both */
  gboolean exact=copy&&copy->records->len==count&&!g_strcmp0(copy->scope,SCOPE);
  for(guint i=0;exact&&i<count;i++) {
    GlimsEffectArchiveRecord *r=g_ptr_array_index(copy->records,i);
    exact=r->tattoo==7+i&&r->index==(i?4095u:0u)&&r->identities==(i?32u:21u)&&!strcmp(r->fingerprint,HASH)&&
      !strcmp(r->blend_space,"rgb-linear")&&!strcmp(r->composite_space,"rgb-non-linear")&&!strcmp(r->composite_mode,"clip-to-backdrop");
  }
  CHECK(exact,"decoded empty/single/multiple data remains exact after input/source free");glims_effect_archive_free(copy);g_clear_error(&error);
}
int main(void) {
  for(guint count=0;count<3;count++)roundtrip(count);
  accept_text("independent literal valid archive parses",valid);
  reject("NULL bytes refuse even with nonzero length",NULL,1);reject("NULL empty input refuses",NULL,0);reject_text("empty input refuses","");
  gchar *nul=g_strdup(valid);nul[20]=0;reject("embedded NUL refuses",nul,sizeof valid-1);g_free(nul);
  reject("trailing NUL included in explicit length refuses",valid,sizeof valid);
  gchar *huge=g_malloc0(GLIMS_EFFECT_ARCHIVE_MAX_BYTES+1);reject("oversized input refuses",huge,GLIMS_EFFECT_ARCHIVE_MAX_BYTES+1);g_free(huge);
  reject_text("invalid INI syntax refuses","[archive\nversion=1\n");
  static const struct { const char *label,*old,*replacement; } bad[]={
    {"unknown version","version=1\n","version=2\n"},
    {"missing header key","version=1\n",""},
    {"extra header key","version=1\n","version=1\nextra=1\n"},
    {"duplicate header key","version=1\n","version=1\nversion=1\n"},
    {"duplicate empty header group","[archive]\n","[archive]\n[archive]\n"},
    {"wrong header group","[archive]\n","[other]\n"},
    {"missing record key","blend=rgb-linear\n",""},
    {"extra record key","blend=rgb-linear\n","blend=rgb-linear\nextra=1\n"},
    {"duplicate record key","tattoo=7\n","tattoo=7\ntattoo=7\n"},
    {"duplicate empty record group","[effect0]\n","[effect0]\n[effect0]\n"},
    {"noncanonical record group","[effect0]\n","[effect00]\n"},
    {"wrong numbered record group","[effect0]\n","[effect1]\n"},
    {"zero count with record","count=1\n","count=0\n"},
    {"missing group for count","count=1\n","count=2\n"},
    {"record count above cap","count=1\n","count=4097\n"},
    {"negative count","count=1\n","count=-1\n"},
    {"uint32 count overflow","count=1\n","count=4294967296\n"},
    {"uint64 count overflow","count=1\n","count=18446744073709551616\n"},
    {"nonnumeric count","count=1\n","count=no\n"},
    {"zero tattoo","tattoo=7\n","tattoo=0\n"},
    {"negative tattoo","tattoo=7\n","tattoo=-1\n"},
    {"tattoo overflow","tattoo=7\n","tattoo=4294967296\n"},
    {"negative index","index=0\n","index=-1\n"},
    {"index above cap","index=0\n","index=4096\n"},
    {"index overflow","index=0\n","index=4294967296\n"},
    {"negative identity mask","identities=21\n","identities=-1\n"},
    {"identity mask above sentinel","identities=21\n","identities=33\n"},
    {"identity mask overflow","identities=21\n","identities=4294967296\n"},
    {"invalid scope hash","scope=" SCOPE "\n","scope=short\n"},
    {"uppercase fingerprint","fingerprint=" HASH "\n","fingerprint=ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n"},
    {"nonhex fingerprint","fingerprint=" HASH "\n","fingerprint=gbcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789\n"},
    {"short fingerprint","fingerprint=" HASH "\n","fingerprint=abcdef\n"},
    {"empty enum symbol","blend=rgb-linear\n","blend=\n"},
    {"punctuated enum symbol","blend=rgb-linear\n","blend=rgb.linear\n"},
    {"spaced enum symbol","composite-space=rgb-non-linear\n","composite-space=rgb linear\n"},
    {"non-ASCII enum symbol","composite-mode=clip-to-backdrop\n","composite-mode=é\n"}
  };
  for(guint i=0;i<G_N_ELEMENTS(bad);i++)reject_change(bad[i].label,bad[i].old,bad[i].replacement);
  gchar *text=g_strconcat(valid,"[extra]\nkey=1\n",NULL);reject_text("extra group refuses",text);g_free(text);
  text=g_strconcat(valid,RECORD,NULL);reject_text("duplicate complete record group refuses",text);g_free(text);
  gchar *symbol=g_strnfill(97,'a'),*line=g_strdup_printf("blend=%s\n",symbol);reject_change("97-byte symbol refuses","blend=rgb-linear\n",line);g_free(symbol);g_free(line);
  text=replace(valid,"identities=21\n","identities=0\n");accept_text("zero identity mask is valid",text);g_free(text);
  text=replace(valid,"identities=21\n","identities=31\n");accept_text("all five identity bits are valid",text);g_free(text);
  text=replace(valid,"identities=21\n","identities=32\n");accept_text("non-Curves sentinel is valid",text);g_free(text);
  text=replace(valid,"tattoo=7\n","tattoo=4294967295\n");accept_text("uint32 maximum nonzero tattoo is valid",text);g_free(text);
  symbol=g_strnfill(96,'a');line=g_strdup_printf("blend=%s\n",symbol);text=replace(valid,"blend=rgb-linear\n",line);
  accept_text("96-byte enum symbol passes data-only lexical bound",text);g_free(text);g_free(line);g_free(symbol);
  GlimsEffectArchive *a=archive(2);GlimsEffectArchiveRecord *r=g_ptr_array_index(a->records,1);r->tattoo=7;r->index=0;
  reject_encode("encoder rejects duplicate native target",a);gchar *encoded=NULL;gsize length=0;GError *error=NULL;
  r->index=1;gboolean encoded_ok=glims_effect_archive_encode(a,&encoded,&length,&error);CHECK(encoded_ok,"same tattoo with distinct stack index is valid");
  if(encoded_ok){text=replace(encoded,"index=1\n","index=0\n");reject_text("decoder rejects duplicate tattoo/index target",text);g_free(text);}
  g_free(encoded);g_clear_error(&error);glims_effect_archive_free(a);
  reject_encode("encoder rejects NULL archive",NULL);a=archive(0);g_free(a->scope);a->scope=g_strdup("invalid");reject_encode("encoder rejects invalid scope",a);glims_effect_archive_free(a);
  a=archive(0);GPtrArray *records=a->records;a->records=NULL;reject_encode("encoder rejects missing records array",a);a->records=records;g_ptr_array_add(a->records,NULL);reject_encode("encoder rejects NULL record",a);glims_effect_archive_free(a);
  a=archive(0);g_ptr_array_set_size(a->records,GLIMS_EFFECT_ARCHIVE_MAX_RECORDS+1);reject_encode("encoder rejects record count overflow",a);glims_effect_archive_free(a);
  a=archive(1);r=g_ptr_array_index(a->records,0);r->tattoo=0;reject_encode("encoder rejects zero tattoo",a);r->tattoo=7;
  r->index=4096;reject_encode("encoder rejects out-of-bound stack index",a);r->index=0;
  r->identities=33;reject_encode("encoder rejects invalid identity mask",a);r->identities=21;
  g_free(r->fingerprint);r->fingerprint=g_strdup("invalid");reject_encode("encoder rejects malformed hash",a);
  g_free(r->fingerprint);r->fingerprint=g_strdup(HASH);g_free(r->blend_space);r->blend_space=g_strnfill(97,'a');
  reject_encode("encoder rejects overlong symbol",a);glims_effect_archive_free(a);
  a=archive(0);symbol=g_strnfill(96,'a');for(guint i=0;i<4096;i++)g_ptr_array_add(a->records,record(i+1,0,31,symbol));
  reject_encode("encoder rejects byte overflow from individually valid records",a);glims_effect_archive_free(a);g_free(symbol);
  printf("%s: %d checks, %d failures\n",failures?"FAILED":"PASSED",checks,failures);return failures!=0;
}
