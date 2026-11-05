#!/usr/bin/env python3
"""Benchmark the REAL compiled codec bridge, with synthetic RGB and decode checks.
No FFmpeg CLI substitute. This measures encoding/decoding, not screen capture.
"""
from __future__ import annotations
import argparse
import ctypes as C
import json
import statistics
import sys
import time
from pathlib import Path
CAP=2*1024*1024

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library',type=Path,required=True)
    p.add_argument('--encoder',choices=['h264_nvenc','h264_qsv','h264_amf','h264_vaapi','h264_videotoolbox','libx264'],required=True)
    p.add_argument('--test-software',action='store_true')
    p.add_argument('--device',default='')
    p.add_argument('--width',type=int,default=1280);p.add_argument('--height',type=int,default=720)
    p.add_argument('--frames',type=int,default=60);p.add_argument('--fps',type=int,default=15)
    p.add_argument('--kbps',type=int,default=8000);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if a.output.exists():p.error('Output already exists')
    if a.encoder=='libx264' and not a.test_software:p.error('Software test requires --test-software and a test-built bridge')
    if not (2<=a.width<=8192 and 2<=a.height<=8192 and a.width*a.height<=16777216) or a.width%2 or a.height%2:p.error('Invalid even dimensions')
    if not 1<=a.frames<=10000 or not 1<=a.fps<=60 or not 128<=a.kbps<=100000:p.error('Invalid benchmark bounds')
    result={'scope':'compiled codec bridge, synthetic RGB; not capture/network/GUI', 'encoder':a.encoder,
            'hardware_requested':a.encoder!='libx264','width':a.width,'height':a.height}
    enc=dec=None; status=2
    try:
        lib=C.CDLL(str(a.library.resolve()))
        lib.meshkvm_codec_abi.restype=C.c_uint32
        if lib.meshkvm_codec_abi()!=0x00090001:raise RuntimeError('Unexpected ABI')
        ptr=C.c_void_p; size=C.c_size_t; integer=C.c_int; errtype=C.c_char_p
        lib.meshkvm_encoder_open.argtypes=[C.c_char_p,C.c_char_p,integer,integer,integer,integer,errtype,size]
        lib.meshkvm_encoder_open.restype=ptr
        lib.meshkvm_decoder_open.argtypes=[errtype,size];lib.meshkvm_decoder_open.restype=ptr
        lib.meshkvm_encode.argtypes=[ptr,ptr,size,ptr,size,C.POINTER(size),errtype,size]
        lib.meshkvm_decode.argtypes=[ptr,ptr,size,integer,integer,ptr,size,errtype,size]
        lib.meshkvm_encoder_close.argtypes=[ptr];lib.meshkvm_decoder_close.argtypes=[ptr]
        error=C.create_string_buffer(512)
        enc=lib.meshkvm_encoder_open(a.encoder.encode(),a.device.encode(),a.width,a.height,a.fps,a.kbps,error,512)
        if not enc:raise RuntimeError(error.value.decode(errors='replace'))
        dec=lib.meshkvm_decoder_open(error,512)
        if not dec:raise RuntimeError(error.value.decode(errors='replace'))
        nbytes=a.width*a.height*3; rgb=bytearray(nbytes)
        for y in range(a.height):
            for x in range(a.width):
                offset=(y*a.width+x)*3; rgb[offset:offset+3]=bytes(((x*255)//a.width,(y*255)//a.height,96))
        src=(C.c_ubyte*nbytes).from_buffer(rgb); output=(C.c_ubyte*CAP)(); decoded=(C.c_ubyte*nbytes)()
        enc_ms=[];dec_ms=[];sizes=[];cpu_ms=[];errors=[]
        for index in range(a.frames+3):
            y=index%a.height
            rgb[y*a.width*3:(y+1)*a.width*3]=bytes((30,160,index%256))*a.width
            used=size(); cpu=time.process_time_ns(); begin=time.perf_counter_ns()
            if lib.meshkvm_encode(enc,src,nbytes,output,CAP,C.byref(used),error,512)!=0:
                raise RuntimeError(error.value.decode(errors='replace'))
            middle=time.perf_counter_ns()
            if lib.meshkvm_decode(dec,output,used.value,a.width,a.height,decoded,nbytes,error,512)!=0:
                raise RuntimeError(error.value.decode(errors='replace'))
            end=time.perf_counter_ns();cpu_end=time.process_time_ns()
            # Sparse smoke check, not an image-quality score like SSIM/VMAF.
            delta=sum(abs(rgb[j]-decoded[j]) for j in range(0,nbytes,max(1,nbytes//2048)))/len(range(0,nbytes,max(1,nbytes//2048)))
            if delta>50:raise RuntimeError(f'RGB roundtrip deviation too large: {delta:.2f}')
            if index>=3:
                enc_ms.append((middle-begin)/1e6);dec_ms.append((end-middle)/1e6)
                sizes.append(used.value);cpu_ms.append((cpu_end-cpu)/1e6);errors.append(delta)
        pct=lambda values,q:sorted(values)[min(len(values)-1,int(q*len(values)))]
        result.update(status='passed',frames=a.frames,encode_p50_ms=statistics.median(enc_ms),encode_p95_ms=pct(enc_ms,.95),
                      decode_p50_ms=statistics.median(dec_ms),decode_p95_ms=pct(dec_ms,.95),
                      codec_cpu_ms=sum(cpu_ms),mean_access_unit_bytes=statistics.mean(sizes),
                      estimated_mbps_at_requested_fps=statistics.mean(sizes)*a.fps*8/1e6,
                      sparse_rgb_mean_absolute_error=statistics.mean(errors))
        status=0
    except Exception as exc:result.update(status='unavailable_or_failed',error=f'{type(exc).__name__}: {exc}')
    finally:
        if dec:lib.meshkvm_decoder_close(dec)
        if enc:lib.meshkvm_encoder_close(enc)
    a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));return status
if __name__=='__main__':sys.exit(main())
