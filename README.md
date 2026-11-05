**Fluidite v9 :** voir [FPS_V9_OPTIMISATION.md](docs/FPS_V9_OPTIMISATION.md) pour les optimisations X11, JPEG et les nouvelles mesures de debit.

## Client : commandes escamotables (v9 UI)

Le bandeau de 124 pixels ne reserve plus de hauteur au-dessus du bureau distant.
Pendant la connexion, l'image occupe toute la surface utile de la fenetre.

- A l'ouverture, les champs hote/port/token sont visibles par-dessus la zone d'image.
- Apres authentification, le bandeau se masque automatiquement. Un bouton discret
  `...` en haut a droite permet de le rouvrir et `X` de le masquer.
- **F8** ouvre/ferme les commandes sans utiliser la souris, meme pendant une session.
  F8 est reserve au client et n'est plus transmis a la machine distante.
- A la deconnexion ou si la connexion echoue, les champs reapparaissent.
- L'etat de connexion reste lisible dans le titre de la fenetre et dans le panneau.
- L'ouverture des commandes libere les entrees distantes eventuellement maintenues.
  Cliquer de nouveau sur le bureau distant pour reprendre la saisie clavier.

Aucune modification serveur/protocole. Recompiler uniquement `MeshKVMClient`.

## Correctif v9 WebSocket / Lazarus

La négociation WebSocket utilise désormais le chemin externe `/kvm` et la
route interne mORMot2 `kvm`. Le client conserve les fonctions v9 et utilise
`SetCaptureControl`/`GetCaptureControl` pour la souris. Voir
`docs/CORRECTIF_CONNEXION_WEBSOCKET_V9.md`.

# MeshKVM v9 - sessions, clavier, securite et encodage materiel

Evolution effective de l'archive v8 fournie, en Lazarus / Free Pascal + mORMot2.
Les services, launchers multi-utilisateurs et le packaging restent hors de cette
livraison. Aucun service systeme ni installateur n'est ajoute.

**Sources de developpement. Le serveur et le client Pascal, ainsi que le pont
FFmpeg, n'ont pas ete compiles ici.** Le garde de session Linux et plusieurs
fonctions C ont ete compiles et testes. Les resultats exacts, notamment la
separation entre tests reels et simulations, sont dans
[VALIDATION_V9.md](docs/VALIDATION_V9.md). Ne pas deployer comme serveur public
qualifie ni presenter les chemins GPU comme valides sur toutes les machines.

## Ajouts de cette version

| Domaine | Implementation |
| --- | --- |
| Session courante | Garde Linux logind, etat Windows WTS/bureau d'entree, session console macOS + etat ScreenCaptureKit. Pause, retrait du controle, nouvelle image apres reprise. |
| Texte compose | Requetes UTF-8 numerotees, receipts explicites, deduplication dans la connexion, file d'entrees ordonnee ; aucun rejeu automatique apres resultat inconnu. |
| Clavier distant | Mode `--keyboard remote` pour transmettre les touches au clavier/IME installe sur le bureau distant ; mode texte local conserve. |
| Securite | TLS requis hors loopback sauf derogation explicite ; fournisseur TLS POSIX charge ; plafonds de connexions, delai AUTH, quotas, fermeture des pairs invalides. |
| GPU | Pont FFmpeg facultatif pour H.264 NVENC/QSV/AMF/VAAPI/VideoToolbox, decodeur H.264 CPU cote client, negociation et repli JPEG en mode auto. |
| Mesures | Compteurs CSV serveur et outils de mesure codec, transport, CPU/RSS, plus suites de tests reseau/TLS a executer contre les vrais binaires. |

Le protocole est **`meshkvm7`**, chemin WebSocket `/kvm`. Utiliser exclusivement
le serveur et le client v9 ensemble : aucune retrocompatibilite, aucun protocole
RFB/VNC ni compatibilite directe MeshAgent.

## Construire

Installer Free Pascal, Lazarus avec son widgetset, et enregistrer/construire
le paquet `packages/lazarus/mormot2.lpk` de ton archive mORMot2. Respecter les
options du framework et ses dependances/objets statiques pour la cible choisie ;
ces sources tierces et objets ne sont pas embarques dans ce ZIP.

Les nouvelles bibliotheques natives doivent avoir la meme architecture que les
executables. Le serveur utilise toujours TurboJPEG, meme lorsque H.264 est active,
pour les clients JPEG et le repli. Le client JPEG seul ne necessite pas FFmpeg.
Le pont codec lie `libavcodec`, `libavutil` et `libswscale`, jamais `libavformat`.
Les en-tetes et bibliotheques de developpement FFmpeg sont necessaires a sa
compilation ; installer le seul executable `ffmpeg` ne suffit pas.

### Linux

```sh
export MORMOT2_DIR=/chemin/vers/mORMot2-master
KVM_BUILD_CODEC=1 KVM_BUILD_PORTAL=1 sh build/build_linux.sh
```

Le script construit `libmeshkvm_session.so` pour le garde logind et, avec les
options ci-dessus, `libmeshkvm_codec.so` et `libmeshkvm_portal.so`.
Construire independamment les ponts est aussi possible :

```sh
sh native/session/build.sh
sh native/codec/build.sh
sh native/linux/build.sh
```

Le garde charge `libsystemd.so.0` dynamiquement ; ses en-tetes ne sont pas requis.
La session graphique doit etre connue de logind. Le portail requiert les modules
pkg-config `gio-2.0`, `gio-unix-2.0`, `libpipewire-0.3`, et une implementation de
portail du bureau. X11 utilise X11/Xext/XTest, XFixes facultatif, et le widgetset
Lazarus choisi pour le client. Pas de capture Wayland silencieuse via XWayland.

### Windows

Depuis un terminal configure pour Lazarus et les outils C/C++ natifs :

```bat
set MORMOT2_DIR=C:\src\mORMot2-master
set FFMPEG_SDK=C:\sdk\ffmpeg
set KVM_BUILD_CODEC=1
set KVM_BUILD_DXGI=1
build_windows.cmd
```

`FFMPEG_SDK` doit contenir `include` et les bibliotheques d'import dans `lib`.
`native/codec/build_msvc.cmd` construit `meshkvm_codec.dll` ; le pont DXGI reste
independant (`native/windows/build.cmd`, SDK Windows requis). Les dependances
runtime de ces bibliotheques et leurs licences relevent de ta distribution.
Le script codec suppose un MSVC acceptant `/std:c11`. Chemins Windows non testes.

### macOS

```sh
export MORMOT2_DIR=/chemin/vers/mORMot2-master
KVM_BUILD_CODEC=1 sh build/build_macos.sh
```

Pont ScreenCaptureKit Objective-C, cible macOS 12.3+, client Cocoa. Recompiler
`libmeshkvm_sck.dylib` : la v9 y ajoute la sonde de session publique.
Le codec facultatif est `libmeshkvm_codec.dylib`. Autorisations de capture d'ecran
et d'accessibilite requises, sans tentative de contournement. Signature,
notarisation et paquets ne sont pas traites ici.

Les ponts se chargent a cote de l'executable. Les scripts ne constituent pas un
installateur ; ils produisent les fichiers de developpement serveur/client.

## Lancer

Utiliser un secret aleatoire de 16 a 256 caracteres ASCII sans espace. Le token
est choisi au serveur, identique au client. L'environnement evite de le placer
dans la ligne de commande mais n'est pas un coffre-fort.

```sh
export MESH_KVM_TOKEN='remplacer-par-un-secret-aleatoire-long'
export MESH_KVM_VIEW_TOKEN='autre-secret-aleatoire-pour-la-vision'

./MeshKVMServer --listen 0.0.0.0 --port 7900 --control \
  --tls-cert server.pem --tls-key server.key \
  --encoder auto --bitrate-kbps 8000 \
  --session-policy strict --metrics-csv mesures-serveur.csv \
  --fps 15 --max-width 1920 --max-height 1080
```

Dans le terminal du client, definir le meme `MESH_KVM_TOKEN`, puis :

```sh
./MeshKVMClient --host nom-couvert-par-le-certificat --port 7900 \
  --tls --tls-ca autorite.pem --keyboard text
```

Pour un premier essai strictement local, conserver `127.0.0.1:7900` ; TLS y est
facultatif. Une ecoute distante sans certificat exige **`--allow-insecure`** au
serveur et au client : reserve a un tunnel/VPN de confiance, pas a Internet.
Le token n'assure pas le chiffrement. Aucun mode d'acceptation de certificat
invalide n'est ajoute. Format certificat/cle et magasin CA dependent du backend
TLS de mORMot2 ; les tests du client reel doivent etre executes sur chaque OS.

`--token SECRET`, `--view-token SECRET`, `--listen`, `--host` et `--port` restent
acceptes. `--listen` prend une IPv4, `0.0.0.0` signifie toutes les interfaces.
Le client vise l'IP reelle ou le DNS, jamais `0.0.0.0`. La CLI ne propose pas
encore IPv6. `--list-monitors` ne demande pas de token ni de connexion reseau.

## Session, verrouillage et reprise

`--session-policy strict` est le defaut. Un etat inconnu, trop ancien,
verrouille/inactif ou une capture suspendue interrompt le partage. Le client
efface son image apres reception de l'etat et doit redemander le controle apres
reprise. Un changement d'identite observe est verrouille jusqu'au redemarrage.
Il n'y a aucun changement de session graphique a l'insu de l'utilisateur.

Linux utilise la session du processus, `Active` et `LockedHint` de logind.
**LockedHint depend de ce que declare le bureau** : ce n'est pas un detecteur de
verrouillage independant. Windows refuse le bureau d'entree different, Winlogon
et la session 0. macOS combine les cles publiques de session console avec les
statuts du flux ScreenCaptureKit ; pas de detection universelle de tous les
ecrans de verrouillage prouvee. Les transitions reelles restent a tester.

`--session-policy backend` accepte seulement l'etat *inconnu* si le backend peut
capturer ; les etats explicitement verrouille/inactif/change restent refuses.
Cette derogation reduit la protection : usage de laboratoire ou environnement
sans logind maitrise. Un lancement via un service, SSH ou un autre compte peut
ne pas appartenir a la session graphique voulue. Le choix du bon processus par
session, son cycle de vie et les services sont laisses a ton integration.

## Clavier et IME

`--keyboard text` utilise les caracteres composes localement ; le bouton
**Texte / IME** offre un champ LCL normal. `--keyboard remote` transmet les
codes de touches pour laisser l'application et l'IME du bureau distant travailler.
La case du client change ce mode et libere les touches avant la transition.

La v9 numerote les commits de texte, attend un receipt avant les entrees suivantes,
ne rejoue pas un prefixe partiellement injecte et ferme la connexion si le receipt
reste inconnu pendant quatre secondes. Ce n'est pas une transaction atomique
avec l'application distante : le receipt compte les scalaires entierement soumis
aux API, pas les caracteres dont l'affichage a ete verifie.

X11 conserve le keycode des touches maintenues meme si la disposition change.
Le texte X11 reste limite aux caracteres du groupe XKB actif ; aucun remplacement
global de keymap. Plusieurs touches IME et F13+ sont ajoutees aux tables.
Le mode distant utilise les virtual keys de Lazarus, pas un flux de scancodes
physiques universel. Certains raccourcis et IME consomment les touches localement.
**Pas de protocole universel TSF/IBus avec preedition/candidats/caret.**
Voir [SECURITE_V9.md](docs/SECURITE_V9.md) et la matrice de recette.

## H.264 materiel : perimetre exact

`--encoder turbojpeg` reste le defaut, pertinent pour conserver le chemin JPEG
par rectangles. `auto` essaie les encodeurs materiels disponibles puis revient a
TurboJPEG en cas d'echec. Un nom explicite n'utilise pas de repli H.264 logiciel.
L'ouverture effective d'un encodeur a lieu a la premiere image du profil : une
bibliotheque chargee ne prouve pas que le GPU/pilote peut encoder.

| Valeur | Chemin demande au pont FFmpeg |
| --- | --- |
| `h264_nvenc` | NVENC ; option GPU par index avec `--gpu-device` |
| `h264_qsv` | QSV materiel ; `--gpu-device` configure le child_device |
| `h264_amf` | AMF ; choix explicite du GPU non implemente ici |
| `h264_vaapi` | VAAPI ; par exemple `--gpu-device /dev/dri/renderD128` |
| `h264_videotoolbox` | VideoToolbox ; repli logiciel interdit dans le pont |

Ces chemins sont **implementes mais non compiles/testes ici**. Leur disponibilite
depend du build FFmpeg, du pilote et du materiel. `--no-h264` force un client JPEG.
Un client avec decodeur peut recevoir H.264 ou JPEG ; le serveur garde les trois
profils adaptatifs par famille, sans forcer les autres clients a changer de codec.

Chaque image H.264 est **intra/IDR autonome avec SPS/PPS**, sans images B ni
historique inter-images. Cela simplifie les ACK, changements de profil et
reconnexions, mais peut utiliser plus de bande passante qu'un encodeur inter-frame
ou que des rectangles JPEG sur un bureau peu anime. Le plafond demande en kbps
n'est pas une garantie de debit reseau. Pas de zero-copy : conversion RGB/NV12
et transferts restent presents ; decodage et affichage du client sont sur CPU.
Un encodeur qui retarde ses premieres sorties est refuse par ce chemin, pas
attendu indefiniment comme s'il produisait des images immediates.

## Tests et mesures

```sh
sh tests/run_v9_native.sh
sh tests/run_native_pixels.sh
python3 tests/test_tools.py
python3 tests/test_metrics_tool.py
python3 tests/test_tls_network.py --self-test  # harnais Python uniquement
python3 tests/check_project.py                # structure uniquement
sh tests/run_v9_tests.sh                      # exige Free Pascal
```

Les suites anterieures sont des regressions du coeur, pas une retrocompatibilite.
Les tests reseau du vrai serveur, le probe TLS mORMot2 et les benchmarks sont
detailles dans [PERFORMANCE_V9.md](docs/PERFORMANCE_V9.md) et
[VALIDATION_V9.md](docs/VALIDATION_V9.md). Aucun chiffre de performance du produit
n'est invente ; les traces de tests de cette passe sont dans `docs/validation-v9/`.
Les documents v7/v8 sont historiques, pas des validations de la v9.

## Limites restantes

Pas d'acces au login/desktop securise ni de broker multi-session, pas d'IME distant
universel, d'encodage inter-frame/GPU zero-copy ni de decodage GPU. Clipboard,
audio, transfert de fichiers, HDR et changement dynamique du moniteur depuis le
client ne sont pas ajoutes. Le decodeur natif n'est pas sandboxe et le blocage
d'un pilote GPU n'est pas interrompu par un timeout dur. Un arret du serveur X11
peut encore provoquer la terminaison via Xlib. Les captures DXGI/Wayland/SCK,
le TLS mORMot et les applications completes doivent etre qualifies sur leurs
systemes cibles avant toute affirmation d'equivalence avec MeshAgent.


## Correctif nettete v9

TurboJPEG 4:4:4, DCT standard, rectangles limites a 512x512.
Pour tests locaux, utiliser `--no-adaptive`, `--quality 90` et les options
`--max-width`/`--max-height` de la resolution reelle. Voir
`docs/CORRECTIF_NETTETE_V9.md`.

## Reactivite - passe de developpement v9

Le client traite maintenant les lots sur un timer de 10 ms ; les mouvements
souris sont coalesces avec une cadence maximale d'environ 83 evenements/s.
Les boucles WebSocket ont des reveils plus frequents et le budget de lot
vise une attente plus courte. Voir `docs/REACTIVITE_V9.md` pour les limites,
la commande de test et les regressions a valider sous Lazarus.


### Diagnostic des fermetures WebSocket

La v9 de diagnostic distingue erreur de reception locale, fermeture WebSocket et erreur serveur.
Voir `docs/DIAGNOSTIC_FERMETURE_WEBSOCKET.md`. Aucun changement du protocole `meshkvm7`.

## Correctif de performance du pipeline RGB/JPEG (v9)

Cette livraison reprend la v9 FPS avec des copies RGB evitees, un cache
precedent mis a jour par zones, et un decodeur client TurboJPEG optionnel.
Elle conserve le protocole `meshkvm7` et les controles de connexion de la v9.
Voir `docs/CORRECTIF_PERFORMANCE_PIPELINE.md` pour les tests et limites.

## Client : import rapide des rectangles JPEG (essai GTK2/Qt)

Le client essaye maintenant de decoder les rectangles TurboJPEG en BGR24 puis
de les importer directement dans `TBitmap.LoadFromRawImage`, au lieu de
construire puis relire un fichier BMP en memoire. Si le widgetset ne
supporte pas cet import, il revient au chemin BMP. Pour le desactiver :

```sh
MESHKVM_RAW_IMAGE=0 ./client/MeshKVMClient
```

Les lignes `[client-video]` distinguent les temps de decompression,
d'import LCL, de dessin des rectangles et de dessin de la fenetre.
Le protocole et le serveur ne sont pas modifies.
Voir `docs/CORRECTIF_CLIENT_BGR_DIRECT.md` pour les limites et tests.
