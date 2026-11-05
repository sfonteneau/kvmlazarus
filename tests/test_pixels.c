/* Tests the actual shared C converter used by DXGI/PipeWire, not a model. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../native/common/kvm_pixels.h"
static unsigned rng=0x167fe34u;
static unsigned next(void) { rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; }
static void valid_cases(void) {
    unsigned trial;
    for (trial=0;trial<20000;trial++) {
        unsigned sw=1+next()%23,sh=1+next()%19,rot=next()%4,order=next()%2;
        unsigned cx=next()%sw,cy=next()%sh,cw=1+next()%(sw-cx),ch=1+next()%(sh-cy);
        unsigned dw=1+next()%31,dh=1+next()%29,stride=sw*4+next()%9;
        int reverse=next()%2;
        size_t size=(size_t)stride*sh,capacity=(size_t)dw*dh*3;
        uint8_t *src=malloc(size),*dst=malloc(capacity+2);
        size_t off=reverse ? (size_t)(sh-1)*stride : 0;
        unsigned x,y; uint32_t rw=(rot&1)?ch:cw,rh=(rot&1)?cw:ch;
        assert(src && dst); memset(src,0xcc,size); memset(dst,0xa7,capacity+2);
        for (y=0;y<sh;y++) for (x=0;x<sw;x++) {
            uint8_t *p=src+(reverse ? sh-1-y : y)*stride+x*4;
            p[0]=(uint8_t)x; p[1]=(uint8_t)y; p[2]=(uint8_t)(x+y*3); p[3]=255;
        }
        assert(kvm_pixels_rgb(src,size,off,reverse?-(int32_t)stride:(int32_t)stride,
            sw,sh,cx,cy,cw,ch,rot,order,dst+1,capacity,dw,dh));
        for (y=0;y<dh;y++) for (x=0;x<dw;x++) {
            unsigned rx=(unsigned)((uint64_t)x*rw/dw),ry=(unsigned)((uint64_t)y*rh/dh),sx=0,sy=0;
            if (rot==0) { sx=rx;sy=ry; }
            if (rot==1) { sx=ry;sy=ch-1-rx; }
            if (rot==2) { sx=cw-1-rx;sy=ch-1-ry; }
            if (rot==3) { sx=cw-1-ry;sy=rx; }
            sx+=cx;sy+=cy;
            const uint8_t *p=dst+1+((size_t)y*dw+x)*3;
            assert(p[0]==(uint8_t)(order?sx:sx+sy*3)); assert(p[1]==sy);
            assert(p[2]==(uint8_t)(order?sx+sy*3:sx));
        }
        assert(dst[0]==0xa7 && dst[capacity+1]==0xa7);
        assert(!kvm_pixels_rgb(src,size,off,(int32_t)stride,sw,sh,sw,0,1,1,0,0,dst,capacity,dw,dh));
        free(dst);free(src);
    }
}
static void malformed_cases(void) {
    unsigned i; uint8_t src[256],dst[257]; memset(src,7,sizeof(src));
    for(i=0;i<100000;i++) {
        unsigned sw=1+next()%17,sh=1+next()%17,cx=next()%20,cy=next()%20;
        unsigned cw=next()%20,ch=next()%20,dw=1+next()%12,dh=1+next()%12;
        int32_t stride=(int32_t)(next()%161)-80;
        size_t sz=next()%257,off=next()%300,cap=next()%257;
        memset(dst,0x5e,sizeof(dst));
        kvm_pixels_rgb(src,sz,off,stride,sw,sh,cx,cy,cw,ch,next()%6,next()%3,dst,cap,dw,dh);
        // Always preserve memory immediately beyond the advertised capacity.
        assert(dst[cap]==0x5e);
    }
    assert(!kvm_pixels_rgb(src,SIZE_MAX,SIZE_MAX-1,INT32_MIN,1,1,0,0,1,1,0,0,dst,256,1,1));
    assert(!kvm_dimensions(8192,8192)); assert(kvm_dimensions(8192,2048));
}
int main(void) {
    uint8_t sample[24]={0},out[18]={0};
    const uint8_t expect[4][6]={{1,2,3,4,5,6},{4,1,5,2,6,3},{6,5,4,3,2,1},{3,6,2,5,1,4}};
    unsigned i,r;
    for(i=0;i<6;i++) sample[i*4+2]=(uint8_t)(i+1);
    for(r=0;r<4;r++) {
        assert(kvm_pixels_rgb(sample,24,0,12,3,2,0,0,3,2,r,0,out,18,(r&1)?2:3,(r&1)?3:2));
        for(i=0;i<6;i++) assert(out[i*3]==expect[r][i]);
    }
    valid_cases();malformed_cases();
    puts("PASS: actual C converter: 20000 valid crop/rotation/stride/scale cases + 100000 bounded malformed cases");
    return 0;
}
