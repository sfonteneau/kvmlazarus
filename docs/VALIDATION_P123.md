# Validation P1 / P2 / P3 - 2026-11-06

Base : kvmlazarus-main.zip, copie utilisateur. Livraison : sources uniquement.

## Execute ici

- Convertisseur C reel `native/common/kvm_pixels.h`, compile avec GCC,
  AddressSanitizer et UndefinedBehaviorSanitizer : 20 000 cas valides,
  100 000 entrees malformees bornees, 20 cas cibles du nouveau chemin natif
  (crop, padding, stride negatif, RGB/BGR, jusqu'a 1920x1080). Reussi.
- 57 tests Python existants des outils : 13 constructeur autonome, 31 selection
  Windows x86/x64, 3 archives/liaison, 4 metriques, 6 transport de l'outil Python.
  Reussis. Certains compilent/lient de vrais objets C sur Linux ; ils ne sont
  PAS des compilations Windows des applications Pascal.
- 521 controles structurels/lexicaux et syntaxe shell reussis. Ce nombre ne
  prouve pas l'absence d'erreurs Pascal, de courses ou de problemes graphiques.
- Controles sources JPEG 4:4:4, limites, overlay F8, diagnostic de fermeture,
  journal GUI et anciens invariants de copie actualises : reussis.
- Syntaxe Python du runner de tests et du constructeur verifiee.

Journaux reproductibles dans `docs/validation-p123/`. Les autres repertoires
validation-* du projet sont des historiques, pas des resultats de cette passe.

## Non execute ici

- Compilation FPC/Lazarus du serveur et du client, Windows x86/x64 / Linux / macOS.
- Tests Pascal nouveaux test_p123_core, test_p123_worker, test_p123_win_present.
- Benchmark GDI/DXGI, presentation dans une vraie fenetre LCL.
- Connexion mORMot2 client/serveur complete, TLS, plusieurs spectateurs,
  reconnexion et transitions reelles de session avec cette nouvelle version.
- Mesure de FPS, CPU, RAM et latence visuelle avant/apres sur les postes cibles.

FPC, ppcx64 et lazbuild sont absents ici. Le runner renvoie code 2 / NOT RUN.
La recuperation du compilateur via les depots Debian n'a pas abouti. Il ne faut
pas remplacer ce resultat par la reussite d'un controle lexical.

## Points sensibles a qualifier

1. ABI Win32/Win64 de la presentation DIB et format GDI 24 bits sur les pilotes
   cibles ; tester le repli MESHKVM_RAW_IMAGE=0 pour isoler le rendu natif.
2. ACK de composition CPU : verifier que la derniere image composee reste exacte
   apres blocage/deplacement de la fenetre, NACK et nouvelle geometrie.
3. Le worker detruit ses decodeurs seulement apres arret du thread. Tester
   fermeture/reconnexion repetee et deconnexion pendant un decodage.
4. Les events de controle ne sont pas perdus comme les presentations superflues.
   Verifier deconnexion, perte de focus, pause/reprise et controle exclusif.
5. Comparer GDI/DXGI sans confondre retours d'image inchangee avec nouveaux FPS.
6. La qualite depend encore des options de resolution et du zoom de presentation.

Aucun gain chiffre, aucun fonctionnement de production ni equivalence MeshAgent
ne sont attestes par ces controles. Les modifications sont implementees dans les
sources ; la qualification applicative reste a effectuer.

SHA-256 archive utilisateur de base : `e3d20f4e2c44abfcdcd2f3351a5cb91ab01b3dca33c39dd41bca53a6f6ce04d7`.
