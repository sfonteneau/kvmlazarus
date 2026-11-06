# Correctif de l'import MSI du client MeshKVM Windows

La compilation de l'EXE passe, mais l'import PE suivant empêche Windows de
charger le programme : `msi.dll!MsiEnumProductA`. L'API Win32 correcte est
`MsiEnumProductsA` (avec un **s** final).

La source mORMot2 contient `function MsiEnumProductA; external msidll;`
dans `src/lib/mormot.lib.sspi.pas`. Le correctif conserve le nom Pascal
pour ne pas casser les autres unités, et ajuste uniquement le nom de l'export :

```pascal
function MsiEnumProductA; external msidll name 'MsiEnumProductsA';
```

Pour corriger depuis `cmd.exe`, identifiez le dossier de vos sources mORMot2 :

```bat
where /r C:\tranquilit mormot.lib.sspi.pas
```

Puis, après avoir extrait ce correctif dans `C:\tranquilit\kvmlazarus` :

```bat
cd /d C:\tranquilit\kvmlazarus
"C:\Program Files\Python314\python.exe" tools\fix_mormot_msi_import.py "C:\CHEMIN\VERS\mORMot2"
```

Le chemin fourni peut aussi être celui de `mormot.lib.sspi.pas`. Le script ne
modifie **que** l'import externe fautif, garde une sauvegarde
`mormot.lib.sspi.pas.meshkvm-backup`, vérifie les signatures attendues et
fonctionne à nouveau sans effet si déjà appliqué.

Ensuite, reconstruisez MeshKVM et les unités mORMot2 avec la commande Windows
`build_standalone_windows.cmd --arch x86 ...` habituelle. Le générateur invoque
`lazbuild --build-all`. Si Lazarus utilise encore une ancienne copie des .ppu,
vérifiez que le chemin des sources modifiées est bien celui de la version liée.

Enfin :

```bat
C:\msys64\mingw32\bin\objdump.exe -p dist\i386-win32\MeshKVMClient.exe > client-imports.txt
findstr /I /C:"MsiEnumProduct" client-imports.txt
```

On ne doit plus voir `MsiEnumProductA` (singulier) dans les imports. Le script
`tools/audit_standalone.py` refuse désormais cet import même si `msi.dll` est
bien une bibliothèque système autorisée.

Validation : tests Python sur des copies locales de sources mORMot fictives,
et sur la détection d'import PE. Pas de compilation FPC/Lazarus Windows dans
cet environnement.
