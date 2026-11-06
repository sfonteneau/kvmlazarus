# mORMot2 : integration amont sans correctif local

MeshKVM utilise maintenant mORMot2 comme dependance externe, **sans modifier ses sources**.
Le script `tools/fix_mormot_msi_import.py` et l'option `--fix-mormot-msi`
ont ete retires du constructeur. Aucun correctif automatique de
`mormot.lib.sspi.pas` n'est applique ou exige.

L'option `--mormot-dir` reste disponible pour enregistrer le bon paquet
`packages/lazarus/mormot2.lpk` et recompiler ses unites depuis cette copie :

```bat
build_standalone_windows.cmd --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a" ^
  --mormot-dir "C:\tranquilit\mORMot2"
```

L'audit de l'executable conserve une detection **en lecture seule** des imports
Windows invalides. Il ne corrige aucun fichier. Si une ancienne version du
paquet a ete construite, mettre a jour mORMot2 et reconstruire les unites
avant de relancer MeshKVM.

En cas d'installation par-dessus un ancien ZIP, l'ancien fichier de correction
pourra rester sur disque, mais ne sera plus utilise. Le script de nettoyage
`supprimer_ancien_patch_mormot.cmd` le retire sur demande, sans toucher a mORMot2.
