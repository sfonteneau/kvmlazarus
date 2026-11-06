# Correctif du lien Windows x86/x64 - vraie archive CRT

Sur certains GNU ld Windows, une archive `.a` contenant du texte `GROUP(...)` declenche un faux doublon avec le script `linkNNNN.res` de Free Pascal.

Le build regenere `libkvm_wincrt.a` comme **archive ar binaire** (via `ar -M`) et non comme script. Elle fusionne les membres de `mingwex`, `gcc`, `gcc_eh` (x86 seulement), `msvcrt` et `kernel32`, sans `mingw32`/`tlssup.o`, et force un index.

Controle manuel :

```bat
cd /d C:\tranquilit\kvmlazarus
C:\msys64\mingw32\bin\ar.exe t native\static\i386-win32\libkvm_wincrt.a
```

Le protocole et les sources serveur/client ne sont pas modifies. Scripts et tests changes uniquement.

Validation disponible : tests de fusion d'archives et de references circulaires sous GNU ar/ld sur Linux, plus tests Python de construction simulee Windows x86/x64. **Pas de compilation Windows FPC/Lazarus effectuee ici.**
