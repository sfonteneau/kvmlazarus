#!/usr/bin/env python3
"""Summarize cumulative server counters; no GPU/GUI latency inference."""
import argparse
import csv
import json
from pathlib import Path


def summarize(rows):
    if not rows:
        raise ValueError('No metrics rows')
    keys=('elapsed_ms','capture_calls','captures','capture_ms','pipeline_calls',
          'pipeline_ms','queued_batches','queued_bytes','queue_rejects','acks',
          'ack_total_ms','security_rejects')
    previous={key:0 for key in keys}
    for row in rows:
        current={key:int(row[key]) for key in keys}
        if any(current[key]<previous[key] for key in keys):
            raise ValueError('Negative or decreasing counters; use one process run per file')
        previous=current
    c=previous; seconds=c['elapsed_ms']/1000
    if seconds<=0:raise ValueError('Zero measurement duration')
    avg=lambda total,count:c[total]/c[count] if c[count] else None
    return dict(scope='server cumulative counters; not photon-to-photon latency',
        seconds=seconds,successful_captures=c['captures'],capture_calls=c['capture_calls'],
        capture_calls_per_second=round(c['capture_calls']/seconds,2),
        queued_batches_per_second=round(c['queued_batches']/seconds,2),
        acked_batches_per_second=round(c['acks']/seconds,2),
        mean_capture_call_ms=avg('capture_ms','capture_calls'),
        mean_profile_pipeline_ms=avg('pipeline_ms','pipeline_calls'),
        queued_batches=c['queued_batches'],queued_payload_mbps=c['queued_bytes']*8/seconds/1e6,
        queue_rejects=c['queue_rejects'],acks=c['acks'],mean_ack_ms=avg('ack_total_ms','acks'),
        security_rejects=c['security_rejects'])


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('csv',type=Path)
    p.add_argument('--output',type=Path)
    a=p.parse_args()
    with a.csv.open(newline='') as f: result=summarize(list(csv.DictReader(f)))
    text=json.dumps(result,indent=2)+'\n'
    if a.output:
        with a.output.open('x') as f:f.write(text)
    print(text,end='')
if __name__=='__main__':main()
