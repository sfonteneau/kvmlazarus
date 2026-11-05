# MeshKVM v9 - validation de cette livraison

Base : v8 fournie dans la conversation. Livraison : **sources uniquement**.
**Les applications Pascal completes, le pont FFmpeg et les nouveaux chemins
Windows/macOS n'ont pas ete compiles/executables ici.** Les tests d'un helper
ou d'un harnais ne sont pas des tests de bout en bout du moteur KVM.

## Executions reelles reussies

| Element | Execution et portee |
| --- | --- |
| Helpers H.264 de production | `native/common/kvm_h264.h`, compile avec Clang + AddressSanitizer/UndefinedBehaviorSanitizer : fixtures Annex-B/AVCC, enveloppe d'allocation/padding, troncatures, sentinelles et 100 000 entrees malformees bornees. Les NAL synthetiques ne sont pas des images decodables. Aucun appel a libavcodec dans ce test. |
| Garde de session Linux | Le vrai `kvm_session_linux.c`, compile et execute sous sanitizers avec une facade libsystemd privee : actif, verrouille, inactif, UID/classe/session, erreurs de bus, reprise, 1000 cycles de duree de vie. C'est une simulation des reponses logind, pas un bureau verrouille reel. |
| Garde Linux + vraie libsystemd | Pont .so compile puis charge avec la libsystemd installee. UNKNOWN obtenu dans ce conteneur sans session login, comme attendu. Pas de validation d'un bureau utilisateur. |
| Conversion pixels heritee | Vrai `native/common/kvm_pixels.h`, 20 000 cas valides et 100 000 cas malformes bornes sous sanitizers ; regression v8. |
| X11 natif | Xvfb prive : capture SHM, repli XGetSubImage reutilise, mouvement du pointeur, XKB/CapsLock, XFixes. Appels via ctypes ; pas d'execution des wrappers Pascal modifies. |
| Client WebSocket des outils | Six tests Python : longueurs/masques, fragmentation/Ping, reprise apres timeout partiel, limites et erreurs de framing. |
| Resume de mesures | Quatre tests Python : moyennes/denominateurs, compteurs invalides ou remis a zero, absence d'ACK. Ne mesure pas le moteur. |
| Fixtures TLS | Quatre cas passes avec le client **Python du harnais seulement** : CA valide acceptee, mauvaise CA, mauvais nom et expiration refuses. Ne prouve pas la politique mORMot2. |
| Structure | 445 assertions structurelles/lexicales, XML des projets, resolution des unites propres au projet et `sh -n` ; compilation syntaxique des scripts Python. Ce n'est pas un compilateur Pascal/C ni un test de concurrence. |

Les nombres de cas aleatoires concernent des fonctions de parsing/conversion
bornees, pas autant de scenarii reseau ou de tests utilisateurs. Les sanitizers
n'etablissent pas l'absence de vulnerabilites hors des cas executes.

## Non execute / non valide

| Element | Etat exact |
| --- | --- |
| Serveur/client Lazarus et suites Pascal | FPC, ppcx64 et lazbuild absents. `run_v9_tests.sh` sort avec code 2 avant tout test Pascal. |
| Pont H.264 FFmpeg | Runtime FFmpeg present, mais en-tetes et bibliotheques de developpement pkg-config absents. `native/codec/build.sh` sort avec code 2, aucun pont codec produit. |
| Benchmark GPU | Execute pour constater l'absence de bibliotheque : JSON `unavailable_or_failed`, code 2, aucune mesure GPU/decode/FPS. |
| NVENC/QSV/AMF/VAAPI/VideoToolbox | Aucun encodeur de ce pont teste sur un GPU, aucun encode/decode reel du pont. |
| Probe TLS mORMot2 | Non compile. Le harnais sans probe retourne code 2. Les tests Python ne le remplacent pas. |
| Tests reseau contre MeshKVM | Non executes : aucun serveur Pascal compile. Les fichiers de tests sont livres pour la recette cible. |
| Transitions de session et IME reels | Pas de test de verrouillage/deconnexion/changement utilisateur sur Windows, Linux graphique ou macOS ; pas de matrice clavier/IME GUI. |
| Ponts DXGI/Wayland/SCK complets | Pas de nouvelle compilation native sur leurs cibles dans cette passe ; modifications macOS non compilees. |
| Mesures application | Aucun run CPU/RAM/latence/debit du serveur et du client ensemble. Les outils sont livres, les gains ne sont pas demontrables ici. |
| Services/packaging | Exclus a la demande de l'utilisateur, pas implementes ni testes. |

L'acces aux paquets/outils de compilation n'a pas abouti dans cet environnement.
Il n'est pas fait de promesse de binaire Windows/Linux/macOS deja fonctionnel.
Les signatures mORMot2 ont ete examinees dans l'archive fournie, ce qui ne vaut
pas compilation ni garantie de compatibilite avec une autre version du framework.

## Journaux de cette passe

Dans `docs/validation-v9/` :

- `native.log`, `pixels-regression.log` : vraies executions C sous sanitizers.
- `session-build.log`, `session-real.log` : construction et essai contre libsystemd.
  Un log de compilation vide signifie sortie sans diagnostic, pas test complet.
- `x11-regression.log` : tests Xvfb natifs et mention explicite de leur portee.
- `tools.log`, `metrics-tool.log` : tests unitaires des outils Python.
- `tls-harness.log` : quatre cas **PYTHON HARNESS ONLY**.
- `structure.log` : assertions structurelles et outils absents.
- `pascal.log`, `codec-build.log`, `tls-mormot-not-run.log`, `not-run.txt` : etapes non executees et sorties d'indisponibilite.
- `codec-unavailable.json`, `codec-benchmark.log` : benchmark impossible, pas des resultats de performance.
- `environment.txt` : outils/architecture et empreinte de l'archive v8.

Les DLL/.so generees pour les tests et les caches Python ne sont pas inclus dans
l'archive source. Les certificats de tests etaient temporaires et sont supprimes.
Aucun token, cle TLS utilisable ou certificat prive de production n'est distribue.
Les documents de validation v7/v8 conserves sont des archives historiques.

## Recette avant utilisation reelle

1. Compiler serveur, client et tests Pascal dans la meme configuration que la
   cible mORMot2. Executer `run_v9_tests.sh` avec checks de range/overflow, puis
   compiler les ponts systeme et codec. Conserver les logs complets.
2. Lancer volontairement dans une session de test autorisee, d'abord loopback,
   puis une connexion inter-OS. Verifier JPEG avant H.264 et ne pas confondre
   chargement de DLL avec capacite d'encodage reelle du pilote.
3. Executer le probe TLS, puis les tests reseau de SECURITE_V9.md contre le vrai
   serveur. Valider aussi le listener TLS reel, ses formats de certificat et la
   verification CA/nom sur les trois plateformes, pas seulement le client probe.
4. Verrouiller, changer de VT/utilisateur, deconnecter/reprendre une session,
   retirer/reaccorder les permissions, revoquer le portail et retirer un ecran.
   Confirmer pause et effacement, absence d'entrees sur une autre session, controle
   retire puis explicitement redemande. Tester strict et comprendre tout UNKNOWN.
5. Tester AZERTY/QWERTY, accents, AltGr, touches mortes, un IME local et un IME
   distant, changement de mode, perte de focus, keymap modifiee pendant un appui,
   deconnexion pendant commit, refus/partiel. Verifier qu'aucun texte n'est rejoue.
6. Executer bench_codec sur les encodeurs reels et plusieurs resolutions, dont
   1080 non multiple de 16. Refaire avec deux clients de profils/capacites
   differents, reseau lent, NACK, reconnexion et changement de resolution.
7. Mesurer CPU/RSS et debit sur un bureau comparable, plusieurs repetitions.
   Inspecter le codec effectif et les logs ; aucun resultat ne doit etre annonce
   comme GPU si `auto` a choisi JPEG. Les ACK reseau ne sont pas la latence ecran.

## Conclusion

Les changements existent dans les sources et une partie du code C/outillage a
une execution reproductible. **La v9 n'est pas une version compilee et qualifiee
du produit complet.** Le travail de service/packaging est laisse a l'utilisateur.
Restent des limites fonctionnelles explicites : pas d'IME distant universel,
de broker multi-session/login securise, d'inter-frame/zero-copy ou de decodeur GPU.
