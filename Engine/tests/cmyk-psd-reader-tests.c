/* Independent literal PSD producer: never calls Glims's writer or parser to
 * construct expected bytes/samples. Synthetic ICC tests structure only. */
#include "../cmyk-psd-reader.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c, m) do { checks++; if (c) printf("ok   %s\n", m); else { failures++; printf("FAIL %s (%d)\n", m, __LINE__); } } while (0)
typedef struct {
  unsigned char bytes[600000]; size_t size, pixel, resource, icc, layer, compression;
  unsigned width,height,depth; size_t calls, fail_at, outside, callbacks_after_failure; bool failure_seen;
  size_t rle_table, rle_data;
  const unsigned char *expected; /* planar c,y,row-bytes when non-NULL */
} Fixture;
typedef struct { Fixture *fixture; unsigned calls, fail_at; uint64_t samples; bool bad; } Sink;
static void u16(unsigned char *p,unsigned v) { p[0]=(unsigned char)(v>>8);p[1]=(unsigned char)v; }
static void u32(unsigned char *p,unsigned v) { p[0]=(unsigned char)(v>>24);p[1]=(unsigned char)(v>>16);p[2]=(unsigned char)(v>>8);p[3]=(unsigned char)v; }
static unsigned sample(unsigned c,unsigned y,unsigned x,unsigned depth) {
  static const unsigned edge[]={0,1,0x0102,0x00ff,0xff00,0xffff};
  unsigned max=depth==8?255:65535;
  return x<6 ? ((edge[x]+c*79+y*17)&max) : ((c*271+y*29+x*13)&max);
}
static void make(Fixture *f,unsigned w,unsigned h,unsigned depth,unsigned name,unsigned icc_size) {
  memset(f,0,sizeof *f);f->width=w;f->height=h;f->depth=depth;f->expected=NULL;
  memcpy(f->bytes,"8BPS",4);u16(f->bytes+4,1);u16(f->bytes+12,4);
  u32(f->bytes+14,h);u32(f->bytes+18,w);u16(f->bytes+22,depth);u16(f->bytes+24,4);
  /* Color-mode data is empty. The resource block has literal 8BIM/1039. */
  f->resource=34;size_t at=34;memcpy(f->bytes+at,"8BIM",4);u16(f->bytes+at+4,1039);at+=6;
  f->bytes[at++]=(unsigned char)name;memset(f->bytes+at,'n',name);at+=name;
  if ((1+name)&1) f->bytes[at++]=0xa5;
  u32(f->bytes+at,icc_size);at+=4;f->icc=at;
  memset(f->bytes+at,0x36,icc_size);u32(f->bytes+at,icc_size);
  memcpy(f->bytes+at+12,"prtrCMYK",8);memcpy(f->bytes+at+36,"acsp",4);at+=icc_size;
  if (icc_size&1) f->bytes[at++]=0x7d;
  u32(f->bytes+30,(unsigned)(at-34));f->layer=at;u32(f->bytes+at,0);at+=4;
  f->compression=at;u16(f->bytes+at,0);at+=2;f->pixel=at;
  for (unsigned c=0;c<4;c++) for (unsigned y=0;y<h;y++) for (unsigned x=0;x<w;x++) {
    unsigned v=sample(c,y,x,depth);
    if(depth==8) f->bytes[at++]=(unsigned char)v;
    else {u16(f->bytes+at,v);at+=2;}
  }
  f->size=at;
}
static void make_rle(Fixture *f,unsigned w,unsigned h,unsigned depth) {
  make(f,w,h,depth,0,128);
  u16(f->bytes+f->compression,1);
  size_t table=f->pixel,at=table+8*h;
  f->rle_table=table;f->rle_data=at;
  f->pixel=at;
  for(unsigned c=0;c<4;c++)for(unsigned y=0;y<h;y++) {
    unsigned char row[60000];
    size_t count=(size_t)w*(depth/8),start=at;
    for(unsigned x=0;x<w;x++) {
      unsigned value=sample(c,y,x,depth);
      if(depth==8)row[x]=(unsigned char)value;
      else u16(row+2*x,value);
    }
    f->bytes[at++]=128;
    for(size_t i=0;i<count;) {
      size_t n=count-i;if(n>128)n=128;
      f->bytes[at++]=(unsigned char)(n-1);
      memcpy(f->bytes+at,row+i,n);at+=n;i+=n;
    }
    f->bytes[at++]=128;
    u16(f->bytes+table+2*(c*h+y),(unsigned)(at-start));
  }
  f->size=at;
}

static unsigned pack_literal(unsigned char *out,const unsigned char *in,size_t n) {
  unsigned len=0;
  for(size_t i=0;i<n;) {
    size_t m=n-i;if(m>128)m=128;
    out[len++]=(unsigned char)(m-1);
    memcpy(out+len,in+i,m);len+=(unsigned)m;i+=m;
  }
  return len;
}
static void make_rle_custom(Fixture *f,unsigned w,unsigned h,unsigned depth,
                            const unsigned char *const *rows,const unsigned *lens) {
  make(f,w,h,depth,0,128);
  u16(f->bytes+f->compression,1);
  size_t table=f->pixel,at=table+8*h;f->rle_table=table;f->rle_data=at;f->pixel=at;
  for(unsigned c=0;c<4;c++)for(unsigned y=0;y<h;y++) {
    unsigned idx=c*h+y;
    u16(f->bytes+table+2*idx,lens[idx]);
    memcpy(f->bytes+at,rows[idx],lens[idx]);at+=lens[idx];
  }
  f->size=at;
}
static void set_rle_entry(Fixture *f,unsigned channel,unsigned y,unsigned len) {
  u16(f->bytes+f->rle_table+2*(channel*f->height+y),len);
}
static bool read_at(void *context,uint64_t at,void *out,size_t n) {
  Fixture *f=context;f->calls++;if(f->failure_seen)f->callbacks_after_failure++;
  if (at>f->size || n>f->size-at) {f->outside++;return false;}
  if (f->fail_at && f->calls==f->fail_at) {f->failure_seen=true;return false;}
  memcpy(out,f->bytes+(size_t)at,n);return true;
}
static bool emit(void *context,uint32_t c,uint32_t y,uint32_t x,uint32_t n,const void *p) {
  Sink *s=context;Fixture *f=s->fixture;s->calls++;if(f->failure_seen)f->callbacks_after_failure++;
  if (s->fail_at && s->calls==s->fail_at) {f->failure_seen=true;return false;}
  if(c>=4 || y>=f->height || x>=f->width || !n || n>4096 || n>f->width-x || ((uintptr_t)p%_Alignof(uint16_t))) {s->bad=true;return false;}
  uint64_t expected=((uint64_t)c*f->height+y)*f->width+x;
  if(expected!=s->samples) s->bad=true;
  for(unsigned i=0;i<n;i++) {
    unsigned actual, want;
    if(f->depth==8)actual=((const unsigned char *)p)[i];
    else {uint16_t v;memcpy(&v,(const unsigned char *)p+2*i,2);actual=v;}
    if(f->expected) {
      size_t row_bytes=(size_t)f->width*(f->depth/8);
      const unsigned char *row=f->expected + (((size_t)c*f->height + y) * row_bytes);
      if(f->depth==8) want=row[x+i];
      else want=(unsigned)((row[2*(x+i)]<<8)|row[2*(x+i)+1]);
    } else want=sample(c,y,x+i,f->depth);
    if(actual!=want)s->bad=true;
  }
  s->samples+=n;return !s->bad;
}
static void rle_shapes(Fixture *f) {
  unsigned widths[]={1,129,4097,30000};
  for(unsigned depth=8;depth<=16;depth+=8)for(unsigned i=0;i<4;i++) {
    make_rle(f,widths[i],1,depth);
    GlimsCmykPsdInput in;
    CHECK(glims_cmyk_psd_inspect(read_at,f,f->size,&in)==GLIMS_CMYK_PSD_INPUT_OK,"independent RLE fixture inspects");
    Sink sink={.fixture=f};
    CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&sink)==GLIMS_CMYK_PSD_INPUT_OK,"independent RLE bytes decode");
    CHECK(!sink.bad && sink.samples==(uint64_t)4*f->width*f->height,"RLE retains every independent sample and planar order");
    CHECK(sink.calls==4*f->height*((f->width+4095)/4096),"RLE emits bounded aligned sample chunks");
    CHECK(!f->outside,"RLE remains within its declared input");
  }
}
static bool zero(const void *p,size_t n) {const unsigned char *v=p;for(size_t i=0;i<n;i++)if(v[i])return false;return true;}
static GlimsCmykPsdInput inspect(Fixture *f) {
  GlimsCmykPsdInput in;memset(&in,0xaa,sizeof in);
  CHECK(glims_cmyk_psd_inspect(read_at,f,f->size,&in)==GLIMS_CMYK_PSD_INPUT_OK,"literal PSD inspection succeeds");
  CHECK(in.width==f->width && in.height==f->height && in.depth==f->depth && in.pixel_offset==f->pixel && in.icc_offset==f->icc && in.file_size==f->size,"inspection reports exact literal layout");
  return in;
}
static void refused(Fixture *f,GlimsCmykPsdInputStatus expected,const char *label) {
  GlimsCmykPsdInput in;memset(&in,0xa6,sizeof in);f->calls=0;f->outside=0;f->failure_seen=false;f->callbacks_after_failure=0;
  CHECK(glims_cmyk_psd_inspect(read_at,f,f->size,&in)==expected,label);
  CHECK(zero(&in,sizeof in),"refusal clears the entire output layout");
  CHECK(f->outside==0,"malformed input never requests out-of-bounds bytes");
}
static void valid_shapes(Fixture *f) {
  unsigned dimensions[][2]={{1,9},{7,3},{4097,2}};
  for(unsigned d=8;d<=16;d+=8)for(unsigned k=0;k<3;k++)for(unsigned name=0;name<4;name++) {
    unsigned names[]={0,1,2,255};make(f,dimensions[k][0],dimensions[k][1],d,names[name],name==2?129:128);
    GlimsCmykPsdInput in=inspect(f);Sink s={.fixture=f};
    CHECK(in.icc_size==(name==2?129u:128u),"ICC extent excludes padding exactly");
    CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&s)==GLIMS_CMYK_PSD_INPUT_OK,"bounded literal planes decode");
    CHECK(!s.bad && s.samples==(uint64_t)4*f->width*f->height,"every decoded sample has exact C/M/Y/K order and intensity");
    CHECK(s.calls==4*f->height*((f->width+4095)/4096),"emission stays in exact bounded row chunks");
    CHECK(f->outside==0,"valid inspection and decoding stay in input bounds");
  }
}
static void rle_packbits_controls(Fixture *f) {
  for(unsigned depth=8;depth<=16;depth+=8) {
    unsigned w=257,h=3; size_t rs=(size_t)w*(depth/8);
    static unsigned char exp[4*3*514];
    unsigned char packed[4][3][560];
    unsigned lens[12]; const unsigned char *rows[12];
    memset(exp,0,sizeof exp);
    for(unsigned c=0;c<4;c++)for(unsigned y=0;y<h;y++) {
      unsigned char *er=exp + ((size_t)c*h + y) * rs;
      for(size_t i=0;i<rs;i++) er[i]=(unsigned char)(i*37 + c*11 + y*97 + depth);
      unsigned l=0; unsigned char *pk=packed[c][y];
      if(y==0) { /* 128 leading no-op, 0 single literal, 127 128-literal, mixed, 128 trailing no-op */
        pk[l++]=128;
        pk[l++]=0; pk[l++]=er[0];
        pk[l++]=127; memcpy(pk+l,er+1,128); l+=128;
        l+=pack_literal(pk+l,er+129,rs-129);
        pk[l++]=128;
      } else if(y==1) { /* 129 repeat128, 255 repeat2, literal, repeat3, mixed literal/repeat */
        memset(er, (unsigned char)(0x40 + c*3 + depth), 128);
        memset(er+128, (unsigned char)(0x91 + c), 2);
        er[130]=(unsigned char)(0x22 + c);
        memset(er+131, (unsigned char)(0x55 + c), 3);
        for(size_t i=134;i<rs;i++) er[i]=(unsigned char)(i*13 + c*7 + 0x33);
        pk[l++]=129; pk[l++]=er[0];
        pk[l++]=255; pk[l++]=er[128];
        pk[l++]=0; pk[l++]=er[130];
        pk[l++]=254; pk[l++]=er[131];
        l+=pack_literal(pk+l,er+134,rs-134);
      } else { /* leading/trailing no-ops around complete output */
        pk[l++]=128; pk[l++]=128;
        l+=pack_literal(pk+l,er,rs);
        pk[l++]=128;
      }
      lens[c*h+y]=l; rows[c*h+y]=pk;
    }
    make_rle_custom(f,w,h,depth,rows,lens); f->expected=exp;
    GlimsCmykPsdInput in;Sink s={.fixture=f};
    CHECK(glims_cmyk_psd_inspect(read_at,f,f->size,&in)==GLIMS_CMYK_PSD_INPUT_OK,"PackBits control fixture inspects");
    CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&s)==GLIMS_CMYK_PSD_INPUT_OK,"PackBits control fixture decodes");
    CHECK(!s.bad && s.samples==(uint64_t)4*w*h,"PackBits controls preserve exact decoded samples");
    f->expected=NULL;
  }
}
static void rle_multichannel_rows(Fixture *f) {
  unsigned w=9,h=2,depth=16; /* uneven byte boundaries (18 bytes) and multi-row/channel */
  size_t rs=18; static unsigned char exp[4*2*18];
  unsigned char packed[4][2][40]; unsigned lens[8]; const unsigned char *rows[8];
  for(unsigned c=0;c<4;c++)for(unsigned y=0;y<h;y++) {
    unsigned char *er=exp + ((size_t)c*h + y) * rs;
    for(size_t i=0;i<rs;i++) er[i]=(unsigned char)(i*19 + c*41 + y*67 + 3);
    /* ensure mixes differ by channel/row; keep byte-level repeats valid */
    if((c+y)&1) { er[4]=er[5]=er[6]=(unsigned char)(0x70+c); }
    else { er[0]=er[1]=er[2]=(unsigned char)(0x2a+c+y); }
    unsigned l=0; unsigned char *pk=packed[c][y];
    if((c+y)&1) { /* leading no-op, literal, repeat3 bytes, literal tail */
      pk[l++]=128; pk[l++]=3; memcpy(pk+l,er,4); l+=4; /* first 4 bytes literal */
      pk[l++]=254; pk[l++]=er[4]; /* repeat 3 bytes */
      l+=pack_literal(pk+l,er+7,rs-7);
    } else {
      pk[l++]=254; pk[l++]=er[0]; /* repeat 3 bytes */
      l+=pack_literal(pk+l,er+3,rs-3);
      pk[l++]=128; /* trailing no-op */
    }
    lens[c*h+y]=l; rows[c*h+y]=pk;
  }
  make_rle_custom(f,w,h,depth,rows,lens); f->expected=exp;
  GlimsCmykPsdInput in;Sink s={.fixture=f};
  CHECK(glims_cmyk_psd_inspect(read_at,f,f->size,&in)==GLIMS_CMYK_PSD_INPUT_OK,"multi-row/channel RLE inspects");
  CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&s)==GLIMS_CMYK_PSD_INPUT_OK,"multi-row/channel RLE decodes");
  CHECK(!s.bad && s.samples==(uint64_t)4*w*h,"multi-row/channel order and uneven 16-bit boundaries decode exactly");
  f->expected=NULL;
}

static void refused_decode(Fixture *f,const GlimsCmykPsdInput *in,GlimsCmykPsdInputStatus expected,const char *label) {
  Sink s={.fixture=f};f->calls=0;f->outside=0;f->failure_seen=false;f->callbacks_after_failure=0;
  CHECK(glims_cmyk_psd_decode(read_at,f,in,emit,&s)==expected,label);
  CHECK(s.calls==0,"rejected decode emits zero callbacks");
  CHECK(f->outside==0,"rejected decode stays in bounds");
}
static void rle_malformed(Fixture *f) {
  unsigned char row8[4]={1,2,3,4},row16[8]={0,1,0,2,0,3,0,4};
  const unsigned char *rows[4];unsigned lens[4];
  for(unsigned depth=8;depth<=16;depth+=8) {
    size_t rs=4*(depth/8);unsigned char *base=depth==8?row8:row16;
    /* repeat underflow */
    unsigned char p1[]={255,base[0]}; /* repeat2 leaves both4/8-byte rows short */
    rows[0]=p1;lens[0]=2;rows[1]=rows[2]=rows[3]=p1;lens[1]=lens[2]=lens[3]=2;
    unsigned char good[16];unsigned gl=pack_literal(good,base,rs);
    for(int i=1;i<4;i++){rows[i]=good;lens[i]=gl;}
    make_rle_custom(f,4,1,depth,rows,lens);
    GlimsCmykPsdInput in;memset(&in,0xa6,sizeof in);
    CHECK(glims_cmyk_psd_inspect(read_at,f,f->size,&in)==GLIMS_CMYK_PSD_INPUT_MALFORMED,"repeat underflow refused");
    CHECK(zero(&in,sizeof in),"repeat underflow clears layout");
    /* repeat overflow */
    unsigned char p2[16];unsigned l=0;for(unsigned i=0;i<5;i++){p2[l++]=255;p2[l++]=base[0];} /* 10 bytes on 4-byte row */
    rows[0]=p2;lens[0]=l;for(int i=1;i<4;i++){rows[i]=good;lens[i]=gl;} make_rle_custom(f,4,1,depth,rows,lens);
    refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"repeat overflow refused in preflight");
    /* missing repeat data */
    unsigned char p3[]={129};rows[0]=p3;lens[0]=1;for(int i=1;i<4;i++){rows[i]=good;lens[i]=gl;} make_rle_custom(f,4,1,depth,rows,lens);
    refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"missing repeat data refused");
    /* literal underflow (declared too short / not enough produced) */
    unsigned char p4[]={1,base[0],base[1]};rows[0]=p4;lens[0]=3;for(int i=1;i<4;i++){rows[i]=good;lens[i]=gl;} make_rle_custom(f,4,1,depth,rows,lens);
    refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"literal underflow refused");
    /* literal overflow */
    unsigned char p5[129];l=0;p5[l++]=127;for(int i=0;i<128;i++)p5[l++]=0;rows[0]=p5;lens[0]=l;for(int i=1;i<4;i++){rows[i]=good;lens[i]=gl;} make_rle_custom(f,4,1,depth,rows,lens);
    refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"literal overflow refused");
    /* literal truncated data */
    unsigned char p6[]={3,base[0],base[1]};rows[0]=p6;lens[0]=3;for(int i=1;i<4;i++){rows[i]=good;lens[i]=gl;} make_rle_custom(f,4,1,depth,rows,lens);
    refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"literal truncated data refused");
    /* zero row length */
    rows[0]=good;lens[0]=0;for(int i=1;i<4;i++){rows[i]=good;lens[i]=gl;} make_rle_custom(f,4,1,depth,rows,lens);
    refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"zero row length refused");
  }
}

static void rle_structure(Fixture *f) {
  /* table truncated in middle/final entry */
  make_rle(f,4,2,8);
  f->size=f->rle_table + 5; refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"RLE table truncated in middle entry");
  make_rle(f,4,2,8);
  f->size=f->rle_table + 15; refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"RLE table truncated in final entry");

  /* declared row length one too short/long and cross-row spill */
  make_rle(f,4,2,8);
  { unsigned char *t=f->bytes+f->rle_table; set_rle_entry(f,0,0,((unsigned)t[0]<<8)+t[1]-1); }
  refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"declared row length one too short refused");
  {
    const unsigned char row[]={3,1,2,3,4};
    const unsigned char *all[]={row,row,row,row};unsigned lengths[]={5,5,5,5};
    make_rle_custom(f,4,1,8,all,lengths);
    set_rle_entry(f,0,0,6);set_rle_entry(f,1,0,4);
    refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"row length crosses a real next-row packet");
  }

  /* NOP-only/short output */
  unsigned char nops[]={128,128,128};
  unsigned char good8[8];unsigned gl=pack_literal(good8,(unsigned char[]){1,2,3,4},4);
  const unsigned char *rows[4]={nops,good8,good8,good8}; unsigned lens[4]={3,gl,gl,gl};
  make_rle_custom(f,4,1,8,rows,lens);
  refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"NOP-only row refused");

  /* valid complete output followed by non-NOP packet */
  unsigned char extra[20];unsigned l=pack_literal(extra,(unsigned char[]){1,2,3,4},4);extra[l++]=0;extra[l++]=9;
  rows[0]=extra;lens[0]=l;rows[1]=good8;lens[1]=gl;rows[2]=good8;lens[2]=gl;rows[3]=good8;lens[3]=gl;
  make_rle_custom(f,4,1,8,rows,lens);
  refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"valid complete output followed by non-NOP packet refused");

  /* unexpected trailing file bytes */
  make_rle(f,4,1,8); f->bytes[f->size++]=0;
  refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"unexpected trailing file bytes refused");

  /* full final row truncation */
  make_rle(f,4,1,8); f->size -= 1;
  refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"full final row truncation refused");
}

static void rle_preflight_no_emit(Fixture *f) {
  for(unsigned bad_row=5;bad_row<=11;bad_row+=6) {
    const unsigned char row[]={3,1,2,3,4};
    const unsigned char *all[12];unsigned lengths[12];
    for(unsigned i=0;i<12;i++){all[i]=row;lengths[i]=sizeof row;}
    make_rle_custom(f,4,3,8,all,lengths);
    GlimsCmykPsdInput in=inspect(f);
    f->bytes[f->pixel+bad_row*sizeof row]=127;
    refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"middle/final malformed row refuses before layout publication");
    refused_decode(f,&in,GLIMS_CMYK_PSD_INPUT_MALFORMED,"middle/final malformed row refuses before any sample emission");
  }
}

static void rle_forged_fields(Fixture *f) {
  make_rle(f,4,2,8); GlimsCmykPsdInput in=inspect(f);
  GlimsCmykPsdInput bad=in; bad.compression=0;
  refused_decode(f,&bad,GLIMS_CMYK_PSD_INPUT_MALFORMED,"forged compression refuses before emission");
  bad=in; bad.row_lengths_offset=in.pixel_offset;
  refused_decode(f,&bad,GLIMS_CMYK_PSD_INPUT_MALFORMED,"forged row_lengths_offset refuses before emission");
  bad=in; bad.pixel_offset=in.row_lengths_offset;
  refused_decode(f,&bad,GLIMS_CMYK_PSD_INPUT_MALFORMED,"forged RLE pixel_offset refuses before emission");
}

static void rle_max_packed_row(Fixture *f) {
  static unsigned char row[65535];
  memset(row,128,sizeof row);row[0]=1;row[1]=0x12;row[2]=0x34;
  const unsigned char *rows[]={row,row,row,row};unsigned lens[]={65535,65535,65535,65535};
  static const unsigned char expected[]={0x12,0x34,0x12,0x34,0x12,0x34,0x12,0x34};
  make_rle_custom(f,1,1,16,rows,lens);f->expected=expected;
  GlimsCmykPsdInput in=inspect(f);Sink sink={.fixture=f};
  CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&sink)==GLIMS_CMYK_PSD_INPUT_OK,
    "maximum uint16 packed row with legal no-op padding decodes");
  CHECK(!sink.bad && sink.samples==4 && sink.calls==4 && !f->outside,
    "maximum packed row preserves independently specified sample bytes");
}

static void rle_budget(Fixture *f) {
  make_rle(f,4,1,16);
  u32(f->bytes+18,30000);u32(f->bytes+14,30000);
  refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"legal dimensions with 7.2GB expanded sample budget refuse");
}

static void rle_failures(Fixture *f) {
  make_rle(f,4097,3,16); GlimsCmykPsdInput in=inspect(f); size_t inspect_reads=f->calls;
  for(size_t i=1;i<=inspect_reads;i++) {
    f->fail_at=i;refused(f,GLIMS_CMYK_PSD_INPUT_READ_FAILED,"each RLE structural read failure propagates");
    CHECK(f->calls==i && !f->callbacks_after_failure,"RLE inspection stops at first failing callback");
  }
  f->fail_at=0;f->calls=0;f->failure_seen=false;f->callbacks_after_failure=0;Sink s={.fixture=f};
  CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&s)==GLIMS_CMYK_PSD_INPUT_OK,"capture successful RLE decode call count");
  size_t total=f->calls,emit_total=s.calls;
  CHECK(emit_total==24,"exercise all chunks in every RLE row and plane");
  for(size_t i=1;i<=total;i++) {
    f->calls=0;f->fail_at=i;f->failure_seen=false;f->callbacks_after_failure=0;s=(Sink){.fixture=f};
    GlimsCmykPsdInputStatus st=glims_cmyk_psd_decode(read_at,f,&in,emit,&s);
    CHECK(st==GLIMS_CMYK_PSD_INPUT_READ_FAILED,"each RLE decode read failure propagates");
    CHECK(f->calls==i,"RLE reader stops at first failed callback");
    CHECK(f->callbacks_after_failure==0,"failed RLE read stops both callback families");
  }
  f->fail_at=0;
  for(size_t i=1;i<=emit_total;i++) {
    f->calls=0;f->failure_seen=false;f->callbacks_after_failure=0;s=(Sink){.fixture=f,.fail_at=(unsigned)i};
    CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&s)==GLIMS_CMYK_PSD_INPUT_EMIT_FAILED,"each RLE emitter failure propagates");
    CHECK(s.calls==i,"RLE emitter stops at first failed callback");
    CHECK(f->callbacks_after_failure==0,"failed RLE emission stops both callback families");
  }
}
static void mutations(Fixture *f) {
#define BASE() make(f,7,3,16,0,128)
  BASE();f->bytes[0]='X';refused(f,GLIMS_CMYK_PSD_INPUT_NOT_PSD,"foreign signature is distinguished");
  BASE();f->size=0;refused(f,GLIMS_CMYK_PSD_INPUT_NOT_PSD,"empty input is not PSD");
  for(unsigned n=1;n<26;n++) {BASE();f->size=n;refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"matching truncated PSD prefix/header is malformed");}
  BASE();u16(f->bytes+4,2);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"PSB is explicitly unsupported");
  BASE();f->bytes[7]=1;refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"reserved header byte refuses");
  BASE();u16(f->bytes+24,3);refused(f,GLIMS_CMYK_PSD_INPUT_OTHER_MODE,"ordinary RGB PSD is distinguished");
  BASE();u16(f->bytes+12,5);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"alpha/extra channels refuse preserving import");
  BASE();u16(f->bytes+22,32);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"float PSD refuses this integer reader");
  BASE();u32(f->bytes+18,0);refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"zero width refuses");
  BASE();u32(f->bytes+14,0);refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"zero height refuses");
  BASE();u32(f->bytes+18,30001);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"dimension limit refuses");
  BASE();u32(f->bytes+26,1);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"nonempty mode data refuses");
  BASE();u32(f->bytes+30,0xffffffffu);refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"overflowing resource extent refuses before read");
  BASE();f->bytes[f->resource]='x';refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"invalid resource signature refuses");
  BASE();u16(f->bytes+f->resource+4,1005);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"unknown resource is not silently discarded");
  BASE();f->bytes[f->resource+6]=255;refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"Pascal name outside resource span refuses");
  BASE();u32(f->bytes+f->icc-4,0xffffffffu);refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"ICC length outside resource span refuses");
  BASE();u32(f->bytes+f->icc,127);refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"ICC declared size mismatch refuses");
  BASE();memcpy(f->bytes+f->icc+16,"RGB ",4);refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"wrong ICC space refuses");
  BASE();memcpy(f->bytes+f->icc+12,"link",4);refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"unsupported ICC class refuses structural contract");
  BASE();f->bytes[f->icc+36]='x';refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"wrong ICC signature refuses");
  BASE();u32(f->bytes+f->layer,2);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"nonempty layer section refuses");
  BASE();u16(f->bytes+f->compression,1);refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"RAW bytes falsely labelled RLE refuse");
  BASE();u16(f->bytes+f->compression,2);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"ZIP refuses explicitly");
  BASE();f->size--;refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"truncated final sample refuses preflight");
  BASE();f->bytes[f->size++]=0;refused(f,GLIMS_CMYK_PSD_INPUT_MALFORMED,"unexplained trailer refuses");
  /* No resource: shift layer/compression/pixels over the complete ICC block. */
  BASE();size_t removed=f->layer-f->resource;memmove(f->bytes+34,f->bytes+f->layer,f->size-f->layer);f->size-=removed;u32(f->bytes+30,0);
  refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"missing ICC refuses");
  BASE();size_t resource_len=f->layer-f->resource;memmove(f->bytes+f->layer+resource_len,f->bytes+f->layer,f->size-f->layer);memcpy(f->bytes+f->layer,f->bytes+f->resource,resource_len);f->size+=resource_len;u32(f->bytes+30,(unsigned)(resource_len*2));
  refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"duplicate ICC refuses even when equal");
#undef BASE
}
static void failures_and_arguments(Fixture *f) {
  make(f,4097,2,16,0,128);GlimsCmykPsdInput in=inspect(f);size_t inspect_reads=f->calls;
  for(size_t i=1;i<=inspect_reads;i++) {f->fail_at=i;refused(f,GLIMS_CMYK_PSD_INPUT_READ_FAILED,"each structural read failure propagates");}
  f->fail_at=0;f->calls=0;f->failure_seen=false;f->callbacks_after_failure=0;Sink s={.fixture=f};
  CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&s)==GLIMS_CMYK_PSD_INPUT_OK,"capture successful bounded decode call count");size_t total=f->calls;
  for(size_t i=1;i<=total;i++) {
    f->calls=0;f->fail_at=i;f->failure_seen=false;f->callbacks_after_failure=0;s=(Sink){.fixture=f};
    CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&s)==GLIMS_CMYK_PSD_INPUT_READ_FAILED,"each decoder read failure propagates");
    CHECK(f->calls==i,"reader stops at the first failed callback");
    CHECK(f->callbacks_after_failure==0,"failed read stops both callback families");
  }
  f->fail_at=0;
  for(unsigned i=1;i<=16;i++) {
    f->calls=0;f->failure_seen=false;f->callbacks_after_failure=0;s=(Sink){.fixture=f,.fail_at=i};
    CHECK(glims_cmyk_psd_decode(read_at,f,&in,emit,&s)==GLIMS_CMYK_PSD_INPUT_EMIT_FAILED,"each emitter failure propagates");
    CHECK(s.calls==i,"emitter stops at the first failed callback");
    CHECK(f->callbacks_after_failure==0,"failed emission stops both callback families");
  }
  f->failure_seen=false;f->callbacks_after_failure=0;
  GlimsCmykPsdInput bad=in;bad.pixel_offset++;s=(Sink){.fixture=f};
  CHECK(glims_cmyk_psd_decode(read_at,f,&bad,emit,&s)==GLIMS_CMYK_PSD_INPUT_MALFORMED && s.calls==0,"forged layout refuses before emission");
  bad=in;bad.icc_size++;s=(Sink){.fixture=f};
  CHECK(glims_cmyk_psd_decode(read_at,f,&bad,emit,&s)==GLIMS_CMYK_PSD_INPUT_MALFORMED && s.calls==0,"profile layout mismatch refuses before emission");
  memset(&bad,0x55,sizeof bad);
  CHECK(glims_cmyk_psd_inspect(NULL,f,f->size,&bad)==GLIMS_CMYK_PSD_INPUT_MALFORMED && zero(&bad,sizeof bad),"null reader clears output");
  CHECK(glims_cmyk_psd_inspect(read_at,f,f->size,NULL)==GLIMS_CMYK_PSD_INPUT_MALFORMED,"null layout refuses");
  CHECK(glims_cmyk_psd_decode(read_at,f,NULL,emit,&s)==GLIMS_CMYK_PSD_INPUT_MALFORMED,"null inspected layout refuses");
  CHECK(glims_cmyk_psd_decode(read_at,f,&in,NULL,&s)==GLIMS_CMYK_PSD_INPUT_MALFORMED,"null emitter refuses");
  memset(&bad,0x55,sizeof bad);f->calls=0;
  CHECK(glims_cmyk_psd_inspect(read_at,f,UINT64_MAX,&bad)==GLIMS_CMYK_PSD_INPUT_UNSUPPORTED && zero(&bad,sizeof bad),"enormous declared input refuses with no result");
  CHECK(f->calls==0,"file limit checked before reading");
}
int main(void) {
  Fixture *f=calloc(1,sizeof *f);if(!f)return 2;
  rle_shapes(f);rle_packbits_controls(f);rle_multichannel_rows(f);valid_shapes(f);
  mutations(f);rle_malformed(f);rle_structure(f);rle_preflight_no_emit(f);rle_forged_fields(f);
  rle_budget(f);rle_max_packed_row(f);failures_and_arguments(f);rle_failures(f);free(f);
  printf("%u CMYK PSD reader checks, %u failures\n",checks,failures);
  return failures?1:0;
}
