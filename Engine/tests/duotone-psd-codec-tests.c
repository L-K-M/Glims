#include "duotone-psd-codec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks,failures;
#define CHECK(c,label) do { bool ok=!!(c);checks++;failures+=!ok;printf("%s %s\n",ok?"ok":"FAIL",label); } while(0)
typedef struct { uint8_t *bytes;size_t used,capacity; unsigned reads,writes,fail_read,fail_write;uint32_t depth,max_read;size_t max_write; } Fixture;
static bool read_samples(void *context,uint32_t y,uint32_t x,uint32_t count,uint8_t *samples)
{
  Fixture *f=context;f->reads++;if(count>f->max_read)f->max_read=count;if(f->fail_read && f->reads==f->fail_read)return false;
  for(uint32_t i=0;i<count;i++) { unsigned v=(x+i+y*2u)&255u;
    if(f->depth==8)samples[i]=(uint8_t)(v*64u);
    else {samples[i*2u]=(uint8_t)v;samples[i*2u+1]=(uint8_t)(255u-v);} }
  return true;
}
static bool write_bytes(void *context,const uint8_t *bytes,size_t size)
{
  Fixture *f=context;f->writes++;if(size>f->max_write)f->max_write=size;if(f->fail_write && f->writes==f->fail_write)return false;
  if(size>f->capacity-f->used)return false;memcpy(f->bytes+f->used,bytes,size);f->used+=size;return true;
}
int main(void)
{
  const uint8_t metadata[]={1,2,3}; uint8_t output[128]={0};
  GlimsDuotonePsdSpec spec={2,2,8,metadata,sizeof metadata};uint64_t size=99;
  const uint8_t expected8[]={
    '8','B','P','S',0,1,0,0,0,0,0,0,0,1,0,0,0,2,0,0,0,2,0,8,0,8,
    0,0,0,3,1,2,3,0,0,0,0,0,0,0,0,0,0, 0,64,128,192
  };
  Fixture f={.bytes=output,.capacity=sizeof output,.depth=8};
  CHECK(glims_duotone_psd_size(&spec,&size)==GLIMS_DUOTONE_PSD_OK && size==sizeof expected8,"exact 8-bit size");
  CHECK(glims_duotone_psd_write(&spec,read_samples,&f,write_bytes,&f)==GLIMS_DUOTONE_PSD_OK &&
        f.used==sizeof expected8 && !memcmp(output,expected8,sizeof expected8),"literal Duotone header, metadata and 8-bit pixels");
  const uint8_t expected16[]={
    '8','B','P','S',0,1,0,0,0,0,0,0,0,1,0,0,0,2,0,0,0,2,0,16,0,8,
    0,0,0,3,1,2,3,0,0,0,0,0,0,0,0,0,0, 0,255,1,254,2,253,3,252
  };
  spec.depth=16;f=(Fixture){.bytes=output,.capacity=sizeof output,.depth=16};
  CHECK(glims_duotone_psd_write(&spec,read_samples,&f,write_bytes,&f)==GLIMS_DUOTONE_PSD_OK &&
        f.used==sizeof expected16 && !memcmp(output,expected16,sizeof expected16),"16-bit samples retain big-endian bytes");
  GlimsDuotonePsdSpec bad=spec;bad.depth=32;size=99;
  CHECK(glims_duotone_psd_size(&bad,&size)==GLIMS_DUOTONE_PSD_INVALID && size==0,"unsupported depth refuses and clears size");
  bad=spec;bad.metadata=NULL;CHECK(glims_duotone_psd_size(&bad,&size)==GLIMS_DUOTONE_PSD_INVALID,"missing metadata refuses");
  bad=spec;bad.metadata_size=0;CHECK(glims_duotone_psd_size(&bad,&size)==GLIMS_DUOTONE_PSD_INVALID,"empty metadata refuses");
  bad=spec;bad.metadata_size=GLIMS_DUOTONE_PSD_MAX_METADATA+1u;CHECK(glims_duotone_psd_size(&bad,&size)==GLIMS_DUOTONE_PSD_INVALID,"oversized metadata refuses");
  bad=spec;bad.width=0;CHECK(glims_duotone_psd_size(&bad,&size)==GLIMS_DUOTONE_PSD_INVALID,"zero width refuses");
  bad=spec;bad.height=30001;CHECK(glims_duotone_psd_size(&bad,&size)==GLIMS_DUOTONE_PSD_INVALID,"oversized dimensions refuse");
  CHECK(glims_duotone_psd_size(NULL,&size)==GLIMS_DUOTONE_PSD_INVALID && size==0 &&
        glims_duotone_psd_size(&spec,NULL)==GLIMS_DUOTONE_PSD_INVALID,"null arguments refuse");
  f=(Fixture){.bytes=output,.capacity=sizeof output,.depth=16,.fail_write=1};
  CHECK(glims_duotone_psd_write(&spec,read_samples,&f,write_bytes,&f)==GLIMS_DUOTONE_PSD_WRITE_FAILED && f.reads==0,"header failure never reads source");
  f=(Fixture){.bytes=output,.capacity=sizeof output,.depth=16,.fail_read=1};
  CHECK(glims_duotone_psd_write(&spec,read_samples,&f,write_bytes,&f)==GLIMS_DUOTONE_PSD_READ_FAILED,"source failure is reported");
  f=(Fixture){.bytes=output,.capacity=sizeof output,.depth=16,.fail_write=4};
  CHECK(glims_duotone_psd_write(&spec,read_samples,&f,write_bytes,&f)==GLIMS_DUOTONE_PSD_WRITE_FAILED,"pixel write failure is reported");
  CHECK(glims_duotone_psd_write(&spec,NULL,&f,write_bytes,&f)==GLIMS_DUOTONE_PSD_INVALID &&
        glims_duotone_psd_write(&spec,read_samples,&f,NULL,&f)==GLIMS_DUOTONE_PSD_INVALID,"missing callbacks refuse");
  size_t large_meta_size=GLIMS_DUOTONE_PSD_METADATA_CHUNK+1u;
  uint8_t *large_meta=malloc(large_meta_size);
  if(!large_meta)return 2;
  for(size_t i=0;i<large_meta_size;i++)large_meta[i]=(uint8_t)(i*17u);
  spec=(GlimsDuotonePsdSpec){5001,1,8,large_meta,large_meta_size};
  if(glims_duotone_psd_size(&spec,&size)!=GLIMS_DUOTONE_PSD_OK)return 2;
  uint8_t *wide=malloc((size_t)size);if(!wide)return 2;
  f=(Fixture){.bytes=wide,.capacity=(size_t)size,.depth=8};
  CHECK(glims_duotone_psd_write(&spec,read_samples,&f,write_bytes,&f)==GLIMS_DUOTONE_PSD_OK &&
        f.used==size && f.reads==2 && f.max_read==GLIMS_DUOTONE_PSD_CHUNK_PIXELS &&
        f.max_write==GLIMS_DUOTONE_PSD_METADATA_CHUNK && !memcmp(wide+30,large_meta,large_meta_size),
        "large metadata and wide rows stream in bounded exact chunks");
  f=(Fixture){.bytes=wide,.capacity=(size_t)size,.depth=8,.fail_write=3};
  CHECK(glims_duotone_psd_write(&spec,read_samples,&f,write_bytes,&f)==GLIMS_DUOTONE_PSD_WRITE_FAILED && f.reads==0,
        "late metadata write failure never reads pixels");
  free(wide);free(large_meta);
  spec=(GlimsDuotonePsdSpec){30000,30000,16,metadata,sizeof metadata};
  CHECK(glims_duotone_psd_size(&spec,&size)==GLIMS_DUOTONE_PSD_OK && size==UINT64_C(1800000043),"maximum dimensions size without overflow");
  printf("%u checks, %u failures\n",checks,failures);return failures?1:0;
}
