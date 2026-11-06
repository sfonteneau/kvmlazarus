# Correctif : lazbuild --add-package-link (Windows x86 / x64)

## Erreur

```
+ lazbuild.exe "--add-package-link C:\tranquilit\mORMot2\packages\lazarus\mormot2.lpk"
Error: (lazbuild) Invalid option at position 2: "add-package-link c:\tranquilit\mORMot2\packages\lazarus\mormot2.lpk"
```

La version du generateur concernée envoyait le commutateur de liaison du paquet
et son chemin dans un argument unique, ou sous la forme `--add-package-link=<fichier>`.
Lazarus 4.8 declare cette option comme un commutateur sans parametre : le chemin
`.lpk` doit etre un argument positionnel distinct.

## Correctif

Le constructeur execute maintenant via `subprocess` :

```python
run([lazbuild, '--add-package-link', mormot_package])
```

Il ne lance pas `cmd /c` et laisse Windows/Python citer individuellement les
chemins, y compris s'ils contiennent des espaces.

Pour verifier manuellement :

```bat
"C:\lazarus_4_8\lazarus\lazbuild.exe" --add-package-link "C:\tranquilit\mORMot2\packages\lazarus\mormot2.lpk"
```

Pour relancer la compilation complete :

```bat
cd /d C:\tranquilit\kvmlazarus
build_standalone_windows.cmd ^
  --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a" ^
  --mormot-dir "C:\tranquilit\mORMot2"
```

`--mormot-dir` verifie que `src/lib/mormot.lib.sspi.pas` utilise la bonne
fonction `MsiEnumProductsA` et enregistre le paquet de cette copie avant de
reconstruire ses unites. Si le source n'est pas deja corrige, ajouter
`--fix-mormot-msi` (ce drapeau effectue une sauvegarde avant modification).

L'auditeur reste strict : il rejette l'import inexistant `MsiEnumProductA`,
ainsi que les DLL MinGW/TurboJPEG privees. Le test local ne remplace pas
une compilation executee avec le Lazarus Windows de l'utilisateur.
