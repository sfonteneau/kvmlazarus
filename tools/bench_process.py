#!/usr/bin/env python3
"""Sample CPU/RSS of an existing PID, without launching/installing a service.
Requires psutil (tool dependency only). Does not record command lines or secrets.
"""
import argparse
import csv
import time
from pathlib import Path

def main():
    import psutil
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pid',type=int,required=True)
    p.add_argument('--seconds',type=float,default=30)
    p.add_argument('--interval',type=float,default=.5)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if a.pid<=0 or not 1<=a.seconds<=3600 or not .1<=a.interval<=10:p.error('Arguments out of bounds')
    proc=psutil.Process(a.pid); proc.cpu_percent(None)
    start=time.monotonic()
    with a.output.open('x',newline='') as f:
        writer=csv.writer(f);writer.writerow(['elapsed_s','cpu_percent_1core','rss_bytes','threads'])
        while time.monotonic()-start<a.seconds:
            time.sleep(a.interval)
            try:
                with proc.oneshot(): values=(time.monotonic()-start,proc.cpu_percent(None),proc.memory_info().rss,proc.num_threads())
            except psutil.NoSuchProcess:break
            writer.writerow(values);f.flush()
    print('Process samples saved; CPU may exceed 100% on multiple cores.')
if __name__=='__main__':main()
