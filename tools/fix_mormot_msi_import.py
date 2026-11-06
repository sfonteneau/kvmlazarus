#!/usr/bin/env python3
"""Correct one wrong Windows Installer import in a local mORMot2 source tree.

This utility intentionally patches only the implementation-side external name,
not the Pascal declaration/call sites, and never modifies third-party code
without an explicit file/directory argument.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import os
import re
import shutil
import tempfile

BAD = re.compile(
    rb"(?im)^([ \t]*function[ \t]+MsiEnumProductA[ \t]*;[ \t]*external[ \t]+msidll)[ \t]*;(?=[ \t]*(?:\r?\n|\Z))"
)
GOOD = re.compile(
    rb"(?im)^([ \t]*function[ \t]+MsiEnumProductA[ \t]*;[ \t]*external[ \t]+msidll)[ \t]+name[ \t]+'MsiEnumProductsA'[ \t]*;"
)


def find_source(request: Path) -> Path:
    if request.is_file():
        if request.name.lower() != 'mormot.lib.sspi.pas':
            raise ValueError('Fichier attendu: mormot.lib.sspi.pas')
        return request
    if request.is_dir():
        source = request / 'src' / 'lib' / 'mormot.lib.sspi.pas'
        if not source.is_file():
            raise ValueError('Racine mORMot2 attendue: src\\lib\\mormot.lib.sspi.pas introuvable dans '+str(request))
        return source
    raise ValueError('Chemin introuvable: '+str(request))


def change_import(data: bytes) -> tuple[bytes, str]:
    if GOOD.search(data) and not BAD.search(data):
        return data, 'deja-corrige'
    matches=list(BAD.finditer(data))
    if len(matches) != 1:
        raise ValueError('La declaration externe attendue est absente ou ambiguë (%d correspondances); fichier non modifie.' % len(matches))
    if GOOD.search(data):
        raise ValueError('Source mixte (declarations externes correctes et incorrectes): correction manuelle requise.')
    result,number = BAD.subn(lambda m:m.group(1)+b" name 'MsiEnumProductsA';",data)
    assert number==1
    return result,'corrige'


def patch(request: Path) -> tuple[Path,str,Path | None]:
    source=find_source(request)
    original=source.read_bytes()
    modified,status=change_import(original)
    if status=='deja-corrige':
        return source,status,None
    backup=source.with_name(source.name+'.meshkvm-backup')
    if backup.exists():
        raise ValueError('Sauvegarde preexistante: '+str(backup)+' (aucun fichier modifie).')
    shutil.copy2(source,backup)
    temp=None
    try:
        with tempfile.NamedTemporaryFile(dir=source.parent,prefix='msi-fix-',suffix='.tmp',delete=False) as f:
            temp=Path(f.name)
            f.write(modified)
        # Preserve the source's permissions before replacing it atomically.
        os.chmod(temp,source.stat().st_mode)
        os.replace(temp,source)
    except Exception:
        if temp and temp.exists(): temp.unlink()
        raise
    return source,status,backup


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true',help='Verifier le symbole sans modifier les sources')
    parser.add_argument('mormot',type=Path,help='Racine de mORMot2 ou chemin du fichier mormot.lib.sspi.pas')
    args=parser.parse_args()
    try:
        if args.check:
            path=find_source(args.mormot)
            contents=path.read_bytes()
            if GOOD.search(contents) and not BAD.search(contents):
                print('OK: import MSI valide dans '+str(path))
                return 0
            if BAD.search(contents):
                raise ValueError('Import MSI invalide dans '+str(path)+
                                 '. Relancer sans --check pour corriger cette copie de mORMot2.')
            raise ValueError('Declaration MSI inconnue dans '+str(path)+
                             '. Verifier manuellement la version de mORMot2.')
        path,status,backup=patch(args.mormot)
    except (OSError,ValueError) as exc:
        parser.exit(2,'ERREUR: '+str(exc)+'\n')
    print('Fichier: '+str(path))
    if status=='deja-corrige':
        print('OK: import MSI deja corrige; aucune modification.')
    else:
        print('OK: external msi.dll -> MsiEnumProductsA ; nom Pascal inchange.')
        print('Sauvegarde: '+str(backup))
    print('Recompiler toutes les unites mORMot2 (lazbuild --build-all) et regenerer le client/serveur.')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
