#!/usr/bin/env python3
"""Receipt-only WebSocket benchmark. ACKs after receipt, NOT after decoding/display.
Use a moving test desktop. ACK delay simulates a slow consumer. No input injection.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import statistics
import time
from kvm_ws import WS, endpoint_args, connection_args

def main():
    p=argparse.ArgumentParser(description=__doc__); endpoint_args(p)
    p.add_argument('--seconds', type=float, default=30)
    p.add_argument('--ack-delay-ms', type=int, default=0)
    p.add_argument('--capability', choices=('jpeg','h264'), default='jpeg')
    p.add_argument('--output', type=Path, required=True)
    a=p.parse_args()
    if not 1<=a.seconds<=3600 or not 0<=a.ack_delay_ms<=10000: p.error('Duration/delay out of bounds')
    if a.output.exists(): p.error('Output already exists')
    token=os.environ.get('MESH_KVM_TOKEN','')
    if not token: p.error('Set MESH_KVM_TOKEN')
    intervals=[]; batches=jpeg=h264=payload_bytes=0
    start=last=heartbeat=time.monotonic()
    with WS(**connection_args(a)) as ws:
        ws.auth(token,a.capability)
        start=last=heartbeat=time.monotonic()
        while time.monotonic()-start<a.seconds:
            if time.monotonic()-heartbeat>2:
                ws.send(b'P'); heartbeat=time.monotonic()
            try: op,data=ws.receive(max(0.001,min(1.0,a.seconds-(time.monotonic()-start))))
            except TimeoutError: continue
            payload_bytes+=len(data)
            if op!=2: continue
            jpeg+=data[:1]==b'T'; h264+=data[:1]==b'V'
            if data[:1]==b'B' and len(data)==5:
                now=time.monotonic()
                if batches: intervals.append((now-last)*1000)
                last=now; batches+=1
                # Stay alive during an intentionally slow ACK.
                due=now+a.ack_delay_ms/1000
                while time.monotonic()<due:
                    time.sleep(max(0,min(.2,due-time.monotonic())))
                    if time.monotonic()-heartbeat>2: ws.send(b'P'); heartbeat=time.monotonic()
                ws.send(b'A'+data[1:])
        elapsed=time.monotonic()-start
    ordered=sorted(intervals)
    result=dict(scope='receipt-only transport; no decoder, no end-to-end display latency',
        elapsed_seconds=elapsed,batches=batches,batches_per_second=batches/elapsed,
        payload_bytes=payload_bytes,payload_mbps=payload_bytes*8/elapsed/1e6,
        jpeg_rectangles=jpeg,h264_access_units=h264,ack_delay_ms=a.ack_delay_ms,
        interval_p50_ms=statistics.median(ordered) if ordered else None,
        interval_p95_ms=ordered[min(len(ordered)-1,int(.95*len(ordered)))] if ordered else None)
    a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
