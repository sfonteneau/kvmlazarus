# MeshKVM v9 - choix Windows x86 / x64

Date: 2026-11-06. Base exacte: MeshKVM_v9_autonome_sources.zip.
Cette passe modifie la construction, pas le moteur KVM ni le protocole.

## Installation du correctif

Avec le ZIP de correctif: extraire son contenu dans la racine du projet,
la ou se trouve build_standalone_windows.cmd, en conservant build/ et tools/.
Le CMD seul ne suffit pas: build/build_standalone.py et tools/audit_standalone.py
sont egalement modifies. Le ZIP complet contient deja ces fichiers.

Aucun compilateur, archive TurboJPEG ou executable MeshKVM n'est livre ici.
Le script ne telecharge ni outil ni dependance.

## Choix explicite

| Option | CPU FPC | OS FPC | GCC attendu | Sortie |
| --- | --- | --- | --- | --- |
| --arch x86 | i386 | win32 | i686-...-mingw32 ou i386-...-mingw32 | dist/i386-win32/ |
| --arch x64 | x86_64 | win64 | x86_64-...-mingw32 | dist/x86_64-win64/ |
| --arch native | Architecture de Windows | win32 ou win64 | Meme cible | Selon la cible |

Le `mingw32` a la fin du triple GCC NE veut PAS dire que les objets sont
32 bits. Un triple `x86_64-w64-mingw32` cible bien Windows 64 bits.
`--arch` configure le build: il ne convertit pas un compilateur ni une archive.

## Exemples adaptes au journal fourni

Les commandes sont pour cmd.exe. Le caractere ^ doit etre le dernier de la ligne.
C:\toolchains\mingw32 et C:\deps\turbojpeg sont des EXEMPLES de dossiers locaux,
pas des composants inclus dans cette archive. Le chemin FPC x64 ci-dessous
est egalement a adapter a l'installation reelle.

32 bits, avec le FPC 32 bits du journal et un SDK MinGW 32 bits installe:

```bat
cd /d C:\tranquilit\kvmlazarus
build_standalone_windows.cmd --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\toolchains\mingw32\bin" ^
  --turbojpeg-archive "C:\deps\turbojpeg\x86\libturbojpeg.a"
```

64 bits, avec un FPC capable de cibler x86_64-win64 et le GCC Strawberry
qui annonce deja x86_64 dans le journal fourni:

```bat
cd /d C:\tranquilit\kvmlazarus
build_standalone_windows.cmd --arch x64 ^
  --fpc "C:\lazarus_4_8\fpc\bin\x86_64-win64\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\Strawberry\c\bin" ^
  --turbojpeg-archive "C:\deps\turbojpeg\x64\libturbojpeg.a"
```

Le deuxieme exemple ne suppose pas que ce FPC x64 est deja installe. Un
fpc.exe dispatcher avec le cross-compilateur et les unites de la bonne cible
peut aussi etre fourni. Le script lui passe explicitement -P et -T.
Un IDE Lazarus 64 bits n'impose pas de produire un exe 64 bits: les compilateurs,
les unites RTL/LCL, les objets mORMot2 et les archives natives doivent correspondre
a la cible demandee. Les deux preparations doivent etre executees successivement,
pas simultanement dans la meme installation Lazarus.

Pour choisir uniquement le serveur ou le client, ajouter --only server
ou --only client. Par defaut, les deux programmes sont construits.

## Tester seulement le choix des outils

Ajouter `--check-toolchain` a la commande. TurboJPEG et lazbuild ne sont alors
pas requis par ce diagnostic; FPC, GCC, ar, nm, ld et objdump sont controles.
Ce test n'effectue AUCUN lien executable et ne valide pas les unites RTL/LCL.

```bat
build_standalone_windows.cmd --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --toolchain-bin "C:\toolchains\mingw32\bin" ^
  --check-toolchain
```

Ordre de selection des outils:

1. --cc/--cxx/--ar/--nm/--objdump explicites, si fournis.
2. --toolchain-bin: outils dans ce repertoire; aucun repli vers Strawberry
   ou un autre repertoire du PATH si un outil requis y manque.
3. Sans --toolchain-bin: variables CC/CXX/AR/NM/OBJDUMP, puis PATH. Pour GCC
   Windows, un nom prefixe i686-w64-mingw32-gcc ou x86_64-w64-mingw32-gcc
   de la cible est prefere s'il est dans le PATH.

Le script refuse un GCC x64 en mode x86. Il n'ajoute pas automatiquement
-m32: une toolchain livree seulement en 64 bits n'a pas forcement les bibliotheques
et le runtime 32 bits. Le nom commercial MinGW-w64 ne suffit pas a definir
l'architecture de sortie: verifier son gcc -dumpmachine.

## TurboJPEG

Fournir une VRAIE archive statique .a de la meme architecture et du meme SDK/CRT.
Une .dll.a d'import, une DLL ou une .lib MSVC ne sont pas acceptees par ce profil.
Les membres COFF sont verifies avant la liaison. Les libs x86/x64 ne se reutilisent
pas l'une a la place de l'autre.

Autre possibilite: remplacer --turbojpeg-archive par
`--turbojpeg-source "C:\deps\libjpeg-turbo"` pour compiler un arbre source local.
Ce mode exige CMake, NASM, mingw32-make et windres; SIMD est conserve sur x86
comme sur x64. CMake recoit le compilateur selectionne et le format NASM
win32 ou win64. Les repertoires de build sont distincts selon l'architecture.
Aucun telechargement n'est effectue.

## Projets Lazarus et separation des artefacts

Pour finir dans l'IDE, ajouter --prepare-only. Les sondes C sont tout de meme
liees et executees; les applications Pascal ne sont pas construites par ce mode.

```text
server/MeshKVMServer_Standalone_x86.lpi
client/MeshKVMClient_Standalone_x86.lpi
server/MeshKVMServer_Standalone_x64.lpi
client/MeshKVMClient_Standalone_x64.lpi
```

Chaque paire est generee lors de la preparation de sa cible. Le CPU, l'OS,
le compilateur choisi et le chemin du linker MinGW sont dans le projet.
Ouvrir la bonne paire, pas un ancien _Standalone.lpi prepare pour une autre cible.

```text
native/static/i386-win32/           archives et includes x86
native/static/x86_64-win64/         archives et includes x64
server/lib/standalone/i386-win32/   unites serveur x86
server/lib/standalone/x86_64-win64/ unites serveur x64
client/lib/standalone/i386-win32/   unites client x86
client/lib/standalone/x86_64-win64/ unites client x64
dist/i386-win32/MeshKVMServer.exe
dist/i386-win32/MeshKVMClient.exe
dist/x86_64-win64/MeshKVMServer.exe
dist/x86_64-win64/MeshKVMClient.exe
```

Les checks FPC utilisent CPU386 pour i386 (pas CPUI386), CPUX86_64 pour x64,
WIN32/WIN64 pour l'OS. Le script verifie aussi le champ Machine de chaque
executable PE produit, puis controle les imports avec l'objdump du SDK choisi.
Les fichiers restent un executable par role/cible, pas un executable universel.

## Perimetre et limites

Le profil par defaut reste JPEG/GDI sur Windows. --with-dxgi peut etre demande
pour x86/x64 mais reste experimental, sans compilation Windows complete ici.
H264 autonome Windows n'est pas ajoute par ce correctif. Les fonctions
reseau, affichage, session, tokens, TLS et le protocole meshkvm7 sont inchanges.
Les chemins Linux/macOS restent natifs; ce correctif n'ajoute pas de
cross-compilation Windows depuis Linux.

La validation de cette passe est decrite dans VALIDATION_WINDOWS_ARCH.md.
Les journaux precedents dans docs/ sont historiques, pas des resultats de
compilation Windows pour cette livraison.

## References primaires

- FPC: -P/-T, choix du CPU/OS et du linker:
  https://www.freepascal.org/daily/doc/user/usersu15.html
- FPC: symboles conditionnels CPU386 et CPUX86_64:
  https://www.freepascal.org/docs-html/current/prog/progap7.html
- Source officielle lazbuild (options --cpu, --os, --compiler):
  https://gitlab.com/freepascal.org/lazarus/lazarus/-/blob/main/ide/lazbuild.lpr
- libjpeg-turbo: builds MinGW, archives statiques, NASM:
  https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/BUILDING.md
- GCC: cible annoncee par -dumpmachine:
  https://gcc.gnu.org/onlinedocs/gcc/Developer-Options.html
