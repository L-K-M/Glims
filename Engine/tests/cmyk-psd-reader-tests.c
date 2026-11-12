/* Independent literal PSD producer: never calls Glims's writer or parser to
 * construct expected bytes/samples. Synthetic ICC tests structure only. */
#include "../cmyk-psd-reader.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;
#define CHECK(c, m) do { checks++; if (c) printf("ok   %s\n", m); else { failures++; printf("FAIL %s (%d)\n", m, __LINE__); } } while (0)
typedef struct {
  unsigned char bytes[150000]; size_t size, pixel, resource, icc, layer, compression;
  unsigned width,height,depth; size_t calls, fail_at, outside, callbacks_after_failure; bool failure_seen;
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
  memset(f,0,sizeof *f);f->width=w;f->height=h;f->depth=depth;
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
    unsigned actual;
    if(f->depth==8)actual=((const unsigned char *)p)[i];
    else {uint16_t v;memcpy(&v,(const unsigned char *)p+2*i,2);actual=v;}
    if(actual!=sample(c,y,x+i,f->depth))s->bad=true;
  }
  s->samples+=n;return !s->bad;
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
  BASE();u16(f->bytes+f->compression,1);refused(f,GLIMS_CMYK_PSD_INPUT_UNSUPPORTED,"RLE refuses explicitly");
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
  valid_shapes(f);mutations(f);failures_and_arguments(f);free(f);
  printf("%u CMYK PSD reader checks, %u failures\n",checks,failures);
  return failures?1:0;
}
