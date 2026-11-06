# Correctif Windows autonome : mpr.dll

Symptome reproduit dans le journal utilisateur `tototest`, pendant la compilation
`--arch x86` :

```
952 lines compiled, 0.4 sec
RESULTAT: ECHEC: mpr.dll (DLL hors liste systeme)
```

Le programme de test Free Pascal a ete lie. Le processus de construction s'arrete
ensuite parce que `tools/audit_standalone.py` refuse `mpr.dll`.

`mpr.dll` (Multiple Provider Router) est une DLL Windows, utilisee notamment par
les API de connexions reseau. La distribution en un seul EXE autorise l'utilisation
des DLL Windows standard : `mpr.dll` est donc autorisee explicitement.

La liste reste restrictive : `turbojpeg.dll`, `libgcc_s_dw2-1.dll`,
`libstdc++-6.dll`, `libwinpthread-1.dll` et les DLL privees restent interdites.

Le rapport d'inspection brut `objdump` n'est plus recopie dans le terminal par
defaut, ce qui evite des fichiers de journal de plusieurs centaines de Ko.
Il reste disponible avec `--report rapport.txt` ou `--verbose`.

## Relance

Depuis `cmd.exe`, a la racine du projet :

```bat
build_standalone_windows.cmd ^
  --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a"
```

Les tests de l'auditeur ont ete executes sous Linux. La compilation FPC/Windows
complete doit encore etre validee sur la machine Windows. Une autre DLL systeme
legitime peut etre signalee par l'auditeur ; verifier son origine avant de
l'ajouter a la liste.
