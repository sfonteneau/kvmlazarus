#!/usr/bin/env python3
"""Inspect direct link dependencies, without executing the input binary.

This is NOT a complete dlopen trace nor a test of session/capture permissions.
Use it for the executables produced by build_standalone.py.
"""
from __future__ import annotations
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

FORBIDDEN = re.compile(r'(?:meshkvm|libkvm_|turbojpeg)',re.I)
# Windows base profile uses only OS DLLs; reject other imports, not just a
# handful of known runtime names. API-set imports are Windows components too.
WIN_SYSTEM = {'kernel32.dll','kernelbase.dll','user32.dll','gdi32.dll','gdi32full.dll',
 'advapi32.dll','shell32.dll','shlwapi.dll','shcore.dll','ole32.dll','oleaut32.dll',
 'comdlg32.dll','comctl32.dll','uxtheme.dll','dwmapi.dll','imm32.dll','version.dll',
 'ws2_32.dll','wsock32.dll','mswsock.dll','iphlpapi.dll','dnsapi.dll','netapi32.dll',
 'crypt32.dll','bcrypt.dll','ncrypt.dll','secur32.dll','security.dll','wintrust.dll',
 'winmm.dll','msimg32.dll','msvcrt.dll','ucrtbase.dll','ntdll.dll','psapi.dll',
 'wtsapi32.dll','userenv.dll','d3d11.dll','dxgi.dll','dxguid.dll','opengl32.dll',
 'glu32.dll','setupapi.dll','cfgmgr32.dll','powrprof.dll','dbghelp.dll','rpcrt4.dll',
 'normaliz.dll','wininet.dll','winhttp.dll'}

def invoke(argv: list[str]) -> str:
    if not shutil.which(argv[0]):
        raise RuntimeError('Outil absent: '+argv[0])
    env=os.environ.copy(); env["LC_ALL"]="C"
    p=subprocess.run(argv,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env)
    if p.returncode:
        raise RuntimeError('Inspection impossible: '+p.stdout)
    return p.stdout

def inspect(path: Path, objdump: str = 'objdump') -> tuple[str,list[str],str]:
    with path.open('rb') as f: head=f.read(4)
    if head == b'\x7fELF':
        data=invoke(['readelf','-d',str(path)])
        return 'ELF',re.findall(r'\(NEEDED\).*?\[(.*?)\]',data),data
    if head[:2] == b'MZ':
        data=invoke([objdump,'-p',str(path)])
        return 'PE',re.findall(r'DLL Name:\s*(\S+)',data),data
    if head in [b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca']:
        data=invoke(['otool','-L',str(path)])
        return 'Mach-O',[line.strip().split(' (',1)[0] for line in data.splitlines()[1:] if ' (compatibility ' in line],data
    raise RuntimeError('Format executable non reconnu: '+str(path))

def violations(kind: str, deps: list[str]) -> list[str]:
    bad=[]
    for dependency in deps:
        if FORBIDDEN.search(dependency):
            bad.append(dependency)
        elif kind=='PE':
            name=dependency.lower()
            if name not in WIN_SYSTEM and not name.startswith(('api-ms-win-','ext-ms-win-')):
                bad.append(dependency+' (DLL hors liste systeme)')
    return bad

def main() -> int:
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('binary',type=Path)
    p.add_argument('--report',type=Path)
    p.add_argument('--objdump', default='objdump', help='Explicit MinGW/LLVM objdump path for PE files')
    args=p.parse_args()
    kind,deps,data=inspect(args.binary,args.objdump)
    bad=violations(kind,deps)
    lines=['Executable: '+str(args.binary),'Format: '+kind,
      'Dependances directes:']+['  '+d for d in deps]
    lines+=['RESULTAT: '+('ECHEC: '+', '.join(bad) if bad else 'aucune dependance directe privee MeshKVM/TurboJPEG detectee'),
      'Limite: ne couvre ni dlopen/LoadLibrary, ni plugins du bureau/GPU, ni toutes les dependances transitives.',
      'Les profils autonomes compilent les chargeurs de modules MeshKVM hors du binaire.',
      'Linux: verifier aussi les paquets systeme sur la machine cible. macOS: les dylibs non Apple restent externes.',
      '',data]
    text='\n'.join(lines)
    print(text)
    if args.report:
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(text,encoding='utf-8')
    return int(bool(bad))

if __name__=='__main__':
    try: sys.exit(main())
    except (OSError,RuntimeError) as exc:
        print('ERREUR: '+str(exc),file=sys.stderr); sys.exit(2)
