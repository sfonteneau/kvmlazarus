> Historique v7 conserve pour tracabilite. Pour la livraison courante, lire les documents V8.

# Validation v7 - ce qui est prouve et ce qui ne l'est pas

Livraison de sources realisee dans un conteneur Linux x86_64. Aucun executable
MeshKVM n'est fourni. Le compilateur Free Pascal et Lazarus n'etaient pas
installes ; les tentatives de recuperation de FPC n'ont pas abouti (reseau du
conteneur indisponible). Aucun SDK macOS ni environnement Windows utilisable.

## Controles executes

### Structure et source : tests/check_project.py

Presence des unites, references internes, XML des projets Lazarus, noms du
nouveau protocole, integration ACK/NACK, options CLI, references des backends,
syntaxe `sh -n` de tous les scripts shell, existence des symboles X11 natifs.
Les declarations mORMot2 LoopDelay/SendDelay/SendFrame/protocole ont egalement
ete verifiees dans l'archive fournie lorsque MORMOT2_DIR etait renseigne.

**Ceci n'est pas une compilation ni une analyse semantique Pascal complete.**
Le journal est `validation/static_checks.txt`.

### Execution native Linux : tests/test_x11_native_abi.py

Le script ouvre son propre Xvfb 640 x 360, sans ecoute TCP, puis appelle les
vraies bibliotheques natives avec ctypes :

- creation d'un XImage MIT-SHM, structure/pixels 32 bits et masques verifies,
  segment SysV en 0600, attachement, dix captures et nettoyage ;
- dix mises a jour XGetSubImage avec conservation de l'adresse du XImage ;
- mouvement XTest puis verification de la position par XQueryPointer ;
- taille et appel XkbGetState, appels de preservation de CapsLock.

**Ce test n'execute pas les unites Pascal**, le serveur, le client, TLS,
TurboJPEG ni le protocole. Il valide des appels/structures natifs que le
backend utilise, pas la traduction Pascal ni tous les cas d'erreur.
Journal : `validation/x11_native_abi.txt`.

### Integrite de distribution

Les fichiers sont empaquetes a partir du repertoire v7, sans compilations
cachees, dependances tierces ou binaires. Le ZIP est relu avec verification CRC.
Un fichier `MANIFEST.sha256` permet de verifier les fichiers distribues.

## Tests ecrits mais NON EXECUTES dans cet environnement

| Test | Contenu |
| --- | --- |
| test_v7_core.lpr | Coordonnees multi-ecrans/origines negatives, etat de glisser Quartz, hysteresis/profils, redimensionnement et alias RGB, en-tetes JPEG |
| test_flow.lpr | Lot unique, ACK perime, versions de groupes, refresh sans abandon de lot, NACK, budget faible, progression |
| test_wire.lpr | Bornes des trames, curseur visible/invisible, ACK/NACK, UTF-8 |
| test_server_options / test_client_options | Options initiales et nouvelles, moniteurs sans token, plafonds, valeurs invalides |
| test_frame / test_damage | Reutilisation RGB, differences et fusion/cache de regions |
| test_turbo.lpr | Encodage reel avec TurboJPEG |
| test_linux_desktop.lpr | Capture et injection du backend Pascal, uniquement sur Xvfb |

`sh tests/run_v7_tests.sh` retourne explicitement le statut 2 si FPC manque.
Le journal de cette tentative est `validation/pascal_tests_status.txt`.
Aucun de ces tests n'est annonce reussi sans execution.

## Recette a executer sur les machines cibles

1. Compiler le paquet mORMot2, le serveur et le client sous Linux et Windows.
   Sous macOS, compiler aussi le pont ScreenCaptureKit puis le client Cocoa.
   Verifier leur architecture, permissions et bibliotheques d'execution.
2. Lancer `--list-monitors`. Tester index 0 et un moniteur secondaire, y compris
   a origine negative ; comparer l'image et les positions de clic aux bords.
3. Connexion locale puis client Linux vers serveur Windows, et l'inverse.
   Refaire depuis/vers macOS. Verifier que le token incorrect est refuse et
   qu'un token de visualisation ne peut pas prendre le controle.
4. Tester Shift/Ctrl/Alt, saisie accentuee, copier/coller par raccourcis,
   glisser-deposer gauche/droit/milieu, relachement hors fenetre et perte de
   focus. Tester les dispositions locales utilisees (AZERTY, QWERTY, etc.).
5. Couper une connexion pendant un appui ; verifier liberation et expiration.
   Demander un rafraichissement repetitif pendant un reseau lent ; aucun lot
   supplementaire ne doit s'empiler avant ACK/NACK.
6. Connecter deux clients, limiter le reseau de l'un dans un environnement de
   test. Observer les messages `[video] ... profil ...`, les dimensions S,
   les ACK et le retour progressif au profil haut, sans degrader l'autre.
7. Changer la resolution, debrancher/rebrancher le moniteur, fermer/rouvrir la
   session. Les restrictions de session X11/macOS/Windows doivent etre visibles,
   pas presentees comme une prise en charge des ecrans de connexion.
8. Tester TLS avec certificat valide, certificat inconnu, nom incorrect et
   expiration. Un mauvais certificat doit etre refuse, sans desactivation de
   la verification. Mesurer CPU/RAM/debit sur des scenarios comparables v6/v7.

## Ecarts explicites par rapport a un moteur mature

Wayland, DXGI/GPU, forme native du curseur, clavier universel/IME, consentement
local interactif, migration entre sessions graphiques, service Windows SCM,
validation des cas multiecrans et charge hostile ne sont pas realises.
Le code est plus complet, mais aucune equivalence de fiabilite ou de performance
avec MeshAgent n'est demontree par cette livraison.

## References primaires utilisees pour les API

- Apple : https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- Apple : https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration
- X.Org, Xlib : https://www.x.org/releases/X11R7.6/doc/libX11/specs/libX11/libX11.html
- X.Org, MIT-SHM : https://xorg.freedesktop.org/archive/X11R7.5/doc/Xext/mit-shm.html
- Microsoft, GetDC : https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdc
- Microsoft, SendInput : https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput
- mORMot2 : sources src/net/mormot.net.ws.core.pas et ws.server.pas de l'archive fournie.
