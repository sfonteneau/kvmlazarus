# Correctif Windows FPC + MinGW : liaison statique sans startup MinGW

## Problème reproduit par le journal fourni

`test_standalone_link.lpr` se compile, puis `ld.bfd` échoue avec :

- `multiple definition of _tls_used` dans `libkvm_mingw32.a(...tlssup.o)` contre le RTL FPC (`sysinitpas.o`) ;
- des importations WinAPI non résolues (`_imp__GetCurrentProcess@0`, etc.) ;
- `__divdi3` non résolu, malgré la présence de libgcc, car la dépendance est découverte après son passage dans l'édition de liens.

Le test C natif TurboJPEG fonctionne séparément ; cela ne qualifie **pas** sa liaison dans un programme Pascal.

## Ce que fait le correctif

`build/build_standalone.py` :

1. **N'ajoute plus `libmingw32.a` à FPC.** Les deux runtimes tentent de fournir le TLS d'amorçage. Les bibliothèques MinGW nécessaires au code C sont conservées.
2. Copie `libmingwex.a`, `libgcc.a` et, pour Win32 DW2, `libgcc_eh.a` depuis le GCC **de l'architecture choisie**.
3. Crée `native/static/i386-win32/libkvm_wincrt.a` (ou `x86_64-win64`). Ce fichier est désormais une **vraie archive binaire ar** (`!<arch>\n`), fusionnée à partir de `mingwex`, `gcc`, `gcc_eh` en x86, `msvcrt` et `kernel32`. Elle ne contient jamais le démarrage `libmingw32.a`. Les références entre les objets sont résolues via l’index de l’archive commune. Un précédent script `GROUP (...)` est supprimé automatiquement.
4. Charge cette archive avec `{$LINKLIB kvm_wincrt}` après TurboJPEG. `libmsvcrt.a` et `libkernel32.a` sont des bibliothèques d'importation vers des **DLL Windows standard** : elles ne sont pas incorporées intégralement.
5. Teste les exécutables dans un répertoire temporaire, en enlevant MinGW du `PATH`, puis vérifie qu'ils ne dépendent d'aucune DLL MinGW ou privée.
6. Affiche les arguments de commande avec la syntaxe propre à Windows, et non des apostrophes Unix dans les erreurs du builder.

Ce correctif ne force pas la liaison entièrement statique de Windows et n'utilise pas `--allow-multiple-definition`.

## Compilation Windows 32 bits

Dans **cmd.exe** :

```bat
cd /d C:\tranquilit\kvmlazarus
build_standalone_windows.cmd ^
  --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a"
```

Le script régénère les fichiers de liaison depuis leurs sources. **Ne pas réutiliser manuellement un ancien** `kvm_turbojpeg_link.inc` ou un ancien `.lpi` `_Standalone`.

Avant de relancer, il est possible de supprimer `native\static\i386-win32\test-units` (et les `lib\standalone\i386-win32` si nécessaire) pour éliminer les unités compilées lors des essais antérieurs.

Si le test `test_standalone_link` échoue encore, fournir **les nouvelles références non résolues** et, si possible, le `link.res` produit par FPC avec `-s`. Ne pas réintroduire `libmingw32.a` entier ou désactiver l'erreur de définition multiple.

## Validation disponible

- Tests Python du générateur : exécutés sur Linux.
- Test réel de fusion GNU ar et de résolution d'une dépendance circulaire entre plusieurs bibliothèques C : exécuté sur Linux.
- Compilation et exécution du **vrai** `MeshKVMServer.exe`/`MeshKVMClient.exe` sur Windows x86 : **non effectuées** dans cet environnement.

Le runtime exact de MinGW peut contenir d'autres dépendances selon les versions ; si de nouvelles références apparaissent, il faudra les traiter sans faire entrer le démarrage MinGW en collision avec le RTL FPC.

## Correctif supplementaire (2026-11-06) : ld et scripts en double

Erreur Windows : `linker script file '...libkvm_wincrt.a (...linkNNNN.res)' appears multiple times`.
Le fichier `libkvm_wincrt.a` de la precedente version etait un script `GROUP`, pas une vraie archive. Certaines versions de binutils pour Windows signalent un doublon erroné avec le script `linkNNNN.res` produit par FPC. Le code du builder cree maintenant une archive ar binaire via `ar -M`, verifie sa signature et refait son index : plus aucun script GROUP a charger.

Pour verifier apres `--prepare-only` :

```bat
C:\msys64\mingw32\bin\ar.exe t C:\tranquilit\kvmlazarus\native\static\i386-win32\libkvm_wincrt.a
```

La commande doit afficher des noms de fichiers objets (et non une erreur de format). Une archive ar statique est distincte de la DLL MinGW; ce correctif n'affirme pas que la compilation Windows est validee ici.
