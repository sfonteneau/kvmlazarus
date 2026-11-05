# MeshKVM v8 - validation effectuee et limites

Date : 2026-11-05. Base : archive v7 fournie dans cette conversation.
Livraison : sources uniquement ; aucune preuve de compilation des applications
Pascal, aucune session cliente/serveur de bout en bout dans cet environnement.

## Resultats executes

| Verification | Resultat reel | Portee |
| --- | --- | --- |
| Convertisseur natif C partage | Reussi avec GCC, AddressSanitizer et UndefinedBehaviorSanitizer | Le vrai `native/common/kvm_pixels.h`, pas un modele Python |
| Rotations fixes | Reussi | Fixtures 0/90/180/270 degres |
| Jeux valides randomises | 20 000 cas reussis | Crop, strides signes, padding, canaux BGRA/RGBA, dimensions et redimensionnement |
| Jeux malformes bornes | 100 000 cas executes sans diagnostic des sanitizers | Tailles, offsets, stride, crop, rotation ; sentinelle apres capacite annoncee |
| X11 sur Xvfb prive | Reussi | ABI XImage/SHM, permissions 0600, dix captures SHM, repli XGetSubImage reutilise |
| Entrees X11 natives | Reussi | Mouvement XTest, coordonnees racine, structure XKB et appels de conservation CapsLock |
| Curseur XFixes | Reussi | Position, hotspot, dimensions, pixels unsigned long natifs ; appel via ctypes |
| Structure/syntaxe des scripts | 327 assertions reussies | Fichiers, declarations textuelles, projets XML, options, dependances d'unites, `sh -n` et presence de symboles natifs |

Les 120 000 cas concernent UNE fonction de conversion et ne sont pas 120 000
tests du moteur KVM. Les tests X11 passent par Python/ctypes sur un ecran
virtuel isole, pas par les wrappers Pascal du projet. Le controle statique
n'analyse pas la semantique du compilateur et ne peut detecter toutes les
erreurs de types, signatures ou threads.

## Non compile / non execute

| Element | Etat et raison |
| --- | --- |
| Serveur et client Lazarus/FPC | Non compiles : fpc/ppcx64 et lazbuild absents ; outils non recuperes dans cet environnement |
| Suites Pascal v8 et regressions | Non executees ; `run_v8_tests.sh` sort explicitement avec code 2 |
| Pont Wayland/portail | Construction non effectuee : fichiers de developpement pkg-config GIO/GIO-unix/PipeWire manquants ; script sort code 2 avant compilation |
| Session Wayland reelle | Non testee ; pas de session de bureau/portail de test configuree |
| Pont DXGI et entrees Windows | Non compiles/executables ici : pas de SDK Windows ni machine Windows de test |
| Pont ScreenCaptureKit modifie | Non compile : pas de SDK ni machine macOS |
| TurboJPEG de bout en bout | Non execute dans cette passe ; bibliotheque runtime absente ici |
| WSS/TLS, authentification reseau, GUI | Pas de test applicatif bout en bout |
| Charge, latence, debit, CPU, RAM | Aucun benchmark ni resultat quantitatif applicatif |
| Acces depuis Internet public | Non valide, non recommande |

La relecture des declarations mORMot2 est basee sur l'archive fournie. Le
nouveau descendant TWebSocketServer utilise les files et verrous exposes
par cette version. Leur presence dans les sources ne prouve ni la compilation
FPC ni l'absence de course a l'execution. Revoir l'integration lors d'une
mise a jour mORMot2.

## Journaux inclus

Dans `docs/validation-v8/` :
- `native_pixels.log` : sortie du test C sous ASan/UBSan.
- `x11_native.log` : appels X11/XFixes executes sur Xvfb.
- `structure.log` : resultat des controles structurels, outils absents.
- `pascal.log`, `portal-build.log`, `not-run.txt` : etapes NON executees et codes.
- `environment.txt` : architecture, compilateurs C presents, dependances manquantes.

Commandes depuis la racine du projet :

```sh
sh tests/run_native_pixels.sh
python3 tests/test_x11_native_abi.py
MORMOT2_DIR=/chemin/vers/mORMot2-master python3 tests/check_project.py
sh tests/run_v8_tests.sh       # exige FPC et, pour certaines suites, TurboJPEG
sh native/linux/build.sh      # exige les fichiers de developpement GIO/PipeWire
```

Les fichiers de validation v7 dans `docs/validation/` et les documents V7
sont historiques ; ils ne sont pas des resultats de tests applicatifs v8.
Le script v8 appelle les suites v7 comme regressions du coeur partage : cela
n'ajoute aucune retrocompatibilite du protocole.

## Recette de qualification a executer sur les machines cibles

1. Compiler serveur/client avec la meme architecture, mORMot2 et ses objets
   requis. Construire les ponts sur chaque OS cible, conserver les logs.
   Executer les suites Pascal avec range/overflow checks ; ne pas remplacer
   leur resultat par celui du controle structurel.
2. Premier essai en loopback avec un token distinct de toute production,
   puis deux machines sur reseau prive. Client Linux -> serveur Windows,
   Windows -> Linux X11/Wayland, Linux/Windows -> macOS. Tester plusieurs
   plateformes de client LCL, pas seulement un serveur de chaque OS.
3. Mauvais token, vision seule, deux demandes de controle simultanees,
   perte de focus, Ctrl/Shift/AltGr maintenus pendant deconnexion. Verifier
   la liberation ou le reessai des touches sans injection sur une session
   verrouillee. Refus natif => erreur visible, pas succes silencieux.
4. Saturer le lien d'un seul spectateur ; suivre la file d'envoi, RSS et CPU.
   Verifier que les autres continuent, que les 4 Mio/64 trames sont respectes
   pour la file visee, et que refus local, NACK/ACK et rafraichissement ne
   laissent pas un lot impossible a terminer. Ne pas confondre avec RAM totale.
5. DPI 100/150/200 %, moniteur portrait, origines negatives, debranchement,
   changement de resolution, curseurs couleur/monochrome et pointeur cache.
   Comparer notamment la rotation DXGI et les coordonnees logiques Wayland.
6. Wayland : accepter/refuser/revoquer, vision sans RemoteDesktop, pause du
   flux, bureau inactif, reconnecter un client sans relancer le dialogue.
   Une session revoquee exige un nouveau lancement/consentement. Tester
   plusieurs backends de portail ; ne pas annoncer une compatibilite generale.
7. macOS : refus/retrait des permissions, suspension/reprise, acces bureau
   et fermeture propre ; Windows : UAC/verrouillage/reprise, sans capturer
   l'ecran securise et sans reutiliser une vieille capture comme si elle etait live.
8. Texte ASCII, accents et texte compose ; verifier les refus XKB, le budget
   de commit, les relachements et les raccourcis. Le dialogue local n'est pas
   une implementation de tous les IME distants. Tester TLS avec CA correcte,
   mauvaise CA, nom de serveur incorrect et certificat expire.

## Conclusion

Les sources v8 ajoutent des chemins qui manquaient et corrigent des defauts
localises. Le convertisseur C et certains appels X11 ont une validation
reproductible. **Le produit complet reste non compile et non qualifie.**
Aucune affirmation d'equivalence MeshAgent, de gain FPS ou de disponibilite
production ne peut etre deduite de ces seuls controles. Les chemins natifs
ajoutes doivent etre consideres experimentaux jusqu'aux essais ci-dessus.
