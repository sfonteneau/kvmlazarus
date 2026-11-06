# Correctif de detection du linker MSYS2 (2026-11-06)

## Erreur rencontree

```
Cible demandee: i386-win32 (--arch x86)
i686-w64-mingw32-gcc.exe -dumpmachine
ERREUR: Nom du linker incompatible avec le prefixe GCC: .../ld.exe
```

Le GCC choisi annonce bien `i686-w64-mingw32`. Le script initial rejetait
`ld.exe` car il exigeait le nom `i686-w64-mingw32-ld.exe`. C'etait un
controle de nom trop strict, pas une preuve d'incompatibilite.

## Modifications

- `build/build_standalone.py` : controle `ld --verbose` et `OUTPUT_FORMAT`
  pour verifier l'architecture par defaut (`pei-i386` en x86,
  `pei-x86-64` en x64).
- `-XP` de FPC calcule d'apres le nom du linker choisi, pas le nom GCC.
  `ld.exe` => `-XP` (sans prefixe), linker prefixe => `-XPi686-w64-mingw32-`.
- Le choix `--toolchain-bin` garde sa priorite et n'utilise pas un autre
  `ld.exe` qui serait present sur le PATH.
- Tests de regression couvrant la combinaison MSYS2 reelle et les formats PE.

## Commande de lancement (cmd.exe)

```bat
C:\tranquilit\kvmlazarus\build_standalone_windows.cmd ^
  --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a"
```

Pour verifier seulement la cible des outils, ajouter `--check-toolchain`.
Cela ne teste pas encore le linker avec FPC ni la construction de l'application.

## Validation locale du correctif

31 tests Python Windows (avec simulation des outils et controle de formats)
et 11 tests de regression standalone : OK. La compilation native Windows
et le lien final avec FPC/TurboJPEG restent a tester sur Windows x86.
