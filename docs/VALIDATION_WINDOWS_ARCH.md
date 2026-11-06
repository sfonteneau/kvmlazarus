# Validation - choix Windows x86 / x64

Date: 2026-11-06. Base: MeshKVM_v9_autonome_sources.zip.

## Resultat reel

- 28 tests automatises dans tests/test_windows_arch.py: reussis.
  Ils couvrent la selection x86/x64, Windows 32 bits, Python WOW64,
  les flags FPC, les triples C refuses, les chemins avec espaces,
  la selection du SDK, les formats COFF, les entetes PE et les LPI distincts.
- 11 tests de regression dans tests/test_standalone_build.py: reussis.
  Cette suite compile notamment l'archive C de garde Linux dans un temporaire.
- Controle structurel existant: 486 assertions et verifications shell reussies.
  Ce controle est lexical/structurel, PAS une compilation Pascal.
- py_compile des scripts Python modifies: reussi.
- Les 69 fichiers Pascal et projets d'origine (.pas/.lpr/.lpi) sont
  identiques octet pour octet a ceux de l'archive de base.

## Bien distinguer les deux types de test

1. Le test d'orchestration appelle le VRAI main() du builder mais SIMULE
   les reponses FPC/GCC/lazbuild. Il verifie les commandes et les fichiers
   generes pour les deux cibles. Les messages "Termine" dans ce test
   concernent des fixtures temporaires, PAS des executables MeshKVM compiles.
2. Le test RealCoffFixtures compile REELLEMENT une petite fonction C avec
   Clang pour i686 et x86_64 Windows, cree deux archives ar avec LLVM,
   et lie deux PE minimaux avec lld-link. Il verifie l'acceptation de la bonne
   architecture et le rejet de l'autre. Ces PE ne sont PAS executes et ne
   contiennent ni MeshKVM, ni TurboJPEG, ni Lazarus. Ils valident l'inspection
   des formats et des symboles, pas le produit KVM.

## Non valide ici

- Execution du wrapper .cmd dans cmd.exe sous Windows.
- Compilation complete FPC/Lazarus/MinGW, en 32 ou 64 bits.
- Liaison statique reelle TurboJPEG avec les runtimes du SDK de l'utilisateur.
- Application du projet genere par l'IDE Lazarus Windows.
- DXGI statique Windows, capture, affichage, controle et performance du moteur.

FPC/lazbuild et une installation MinGW Windows ne sont pas disponibles dans
l'environnement de cette passe. Les echanges reseau et le moteur n'ont pas
ete modifies ni requalifies.

## Journaux et reproduction

- docs/validation-windows-arch/architecture-tests.log
- docs/validation-windows-arch/standalone-regression.log
- docs/validation-windows-arch/project-structure.log
- docs/validation-windows-arch/preserved-sources.txt

```sh
python3 tests/test_windows_arch.py
python3 tests/test_standalone_build.py
python3 tests/check_project.py
```

Sur la machine Windows: commencer avec --check-toolchain, puis retirer
cette option pour effectuer les vrais tests natifs, le test de liaison Pascal
et la construction des applications. Ne pas utiliser --skip-smoke pour masquer
une erreur de liaison.

Conclusion: le choix et la propagation des cibles ainsi que les verifications
anti-melange sont testes; la compilation de MeshKVM Windows x86/x64 reste a
valider sur l'installation de l'utilisateur.
