# Correctif audit Windows : msi.dll

## Symptôme

La compilation de `dist\i386-win32\MeshKVMServer.exe` se termine, puis
`tools/audit_standalone.py` signale :

```
RESULTAT: ECHEC: msi.dll (DLL hors liste systeme)
```

`msi.dll` fournit le service Windows Installer, présent dans Windows. Son
import est compatible avec l'objectif d'un exécutable unique utilisant les
bibliothèques standards du système. Il ne nécessite pas de distribuer `msi.dll`.

## Modification

Ajout ciblé de `msi.dll` à `WIN_SYSTEM` dans `tools/audit_standalone.py`.
La vérification continue de refuser les imports privés, notamment
`libgcc_s_dw2-1.dll`, `libstdc++-6.dll`, `libwinpthread-1.dll`, `turbojpeg.dll`.
Le test couvre la liste exacte des 17 imports de `MeshKVMServer.exe` donnée
dans le journal, plus les imports interdits.

## Vérification immédiate (sans recompiler)

Depuis `cmd.exe` :

```bat
cd /d C:\tranquilit\kvmlazarus
"C:\Program Files\Python314\python.exe" tools\audit_standalone.py dist\i386-win32\MeshKVMServer.exe --objdump C:\msys64\mingw32\bin\objdump.exe --report dist\i386-win32\MeshKVMServer-dependencies.txt
```

Résultat attendu : `RESULTAT: aucune dependance directe privee ...`.
Puis relancer `build_standalone_windows.cmd` pour poursuivre la compilation
et l'audit du client. Si l'audit du client détecte une autre DLL, vérifier
qu'il s'agit bien d'une DLL standard du système avant de l'autoriser.

L'auditeur lit la table d'imports PE. Cela ne valide pas les bibliothèques
chargées dynamiquement par `LoadLibrary` ni les dépendances transitives.
