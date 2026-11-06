# Ajout clipboard bidirectionnel - livraison du 2026-11-06

**Recompiler serveur et client ensemble : protocole `meshkvm8`.**
Dans F8, deux interrupteurs independants et desactives par defaut :
`Mon presse-papiers -> distant` et `Distant -> mon presse-papiers`.
Texte Unicode uniquement (64 Kio), controle exclusif requis; aucun collage
simule. Windows / X11 / macOS : backends fournis; Wayland clipboard non fourni.
Compilation autonome conservee, pas de nouvelle DLL privee sous Windows.

Guide : [docs/CLIPBOARD.md](docs/CLIPBOARD.md).
Validation et limites : [docs/VALIDATION_CLIPBOARD.md](docs/VALIDATION_CLIPBOARD.md).
Les nouveaux executables et tests Pascal n'ont pas ete compiles ici.
Les sections suivantes conservent l'historique : le protocole courant est
`meshkvm8`, meme si un ancien chapitre mentionne `meshkvm7`.

---

# MeshKVMClient - controle en CLI, fenetre maximisee

Le client accepte `--control` pour demander le controle exclusif des que le
serveur a valide son jeton et que le bureau est actif. La fenetre demarre
**maximisee par defaut**; `--windowed` revient a 1080 x 730. Voir
[docs/CLIENT_CONTROLE_CLI_ET_FENETRE.md](docs/CLIENT_CONTROLE_CLI_ET_FENETRE.md).
Le protocole et les sources mORMot2 ne sont pas modifies.

---

# MeshKVM v9 - P1 / P2 / P3 (sources)

Base : `kvmlazarus-main.zip` fourni dans la conversation.
Decodage hors GUI, ACK apres composition CPU, envoi du cache independant de la
capture, GDI BGR24 et rendu DIB Windows. Protocole meshkvm7 conserve.

**Recompiler serveur ET client avec le script autonome habituel.** Les scripts
x86/x64 et les sources externes mORMot2 ne sont pas modifies. La compilation des
applications n'a pas ete executee ici : voir les limites avant utilisation.

- Guide et commandes : [docs/P1_P2_P3.md](docs/P1_P2_P3.md).
- Validation de cette passe : [docs/VALIDATION_P123.md](docs/VALIDATION_P123.md).
- Tests Pascal : `python tests/run_p123_tests.py --help`.
- Les anciens rapports ci-dessous sont historiques.

---

# MeshKVM v9 - autonome avec choix Windows x86 / x64

Base de ce correctif: `MeshKVM_v9_autonome_sources.zip`.
Choix Windows ajoute: `--arch x86` ou `--arch x64`.
Voir `docs/WINDOWS_X86_X64.md` pour les commandes et la validation de cette passe.
Correctif MinGW32: voir `docs/CORRECTIF_LINKER_MSYS2.md` (GCC prefixe + ld.exe non prefixe).
Protocole: **meshkvm7**, inchange. JPEG 4:4:4, client BGR direct,
bandeau F8, journal GUI, controles de flux et correctifs precedents conserves.

**Cette archive contient des sources et des scripts, pas des executables deja
compiles.** La compilation Pascal complete n'a pas ete realisee dans
l'environnement de livraison. Le garde Linux a ete compile, lie dans un
executable de test via une vraie archive statique, puis execute sous sanitizers.
Voir `docs/VALIDATION_STANDALONE.md` pour la portee exacte.

## Resultat vise et perimetre

Un fichier executable pour le serveur, et un autre pour le client. Copier
seulement celui necessaire sur chaque machine. Pas de `.so`/`.dll`/`.dylib`
MeshKVM a cote, pas d'extraction de bibliotheques au demarrage. Ce n'est PAS
un ELF entierement statique et ce n'est PAS un fichier universel pour tous les OS.

| Composant | Profil autonome |
| --- | --- |
| TurboJPEG serveur et client | Code lie depuis une vraie archive `.a` |
| Garde Linux | Code C integre; `libsystemd.so.0` reste un runtime systeme |
| Windows | GDI en Pascal; DXGI integrable avec `--with-dxgi` (experimental) |
| macOS | Pont ScreenCaptureKit integre, frameworks Apple dynamiques |
| Wayland | Pont integre avec `--with-portal`; GIO/PipeWire/portail systeme requis |
| H264 | Pont integre avec `--with-codec` sous Linux/macOS; FFmpeg systeme requis |
| Lazarus client | LCL compilee, widgetset/systeme graphique toujours necessaire |
| TLS | Fournisseur systeme/mORMot2 conserve, certificats et cles non embarques |

Le profil de base est **JPEG**: Linux X11, Windows GDI ou macOS ScreenCaptureKit.
Il ne tente PAS de charger un ancien pont H264/Wayland/DXGI laisse a cote.
Un backend non integre et explicitement demande retourne une erreur descriptive.
Le build H264 monofichier Windows n'est pas automatise dans cette livraison.

## Demarrage rapide Linux x86_64 (ta VM)

Prerequis deja utilises: Lazarus/FPC, paquet mORMot2 et ses objets `static/`
pour la bonne architecture. En complement, sous Debian/Ubuntu:

```sh
sudo apt update
sudo apt install build-essential binutils python3 libturbojpeg0-dev
```

Le paquet de developpement est requis sur la machine de COMPILATION pour
`libturbojpeg.a`. Le profil autonome n'a pas besoin de `libturbojpeg.so` sur
la cible. Les dependances X11 de compilation restent celles du projet:
`libx11-dev libxext-dev libxtst-dev`, et le widgetset Lazarus choisi.

Depuis la racine du projet extrait:

```sh
# Inutile si le paquet mORMot2 est deja enregistre dans Lazarus.
# export MORMOT2_DIR=/chemin/vers/mORMot2-master
sh build/build_standalone.sh
```

Cette commande prepare les archives, verifie leur ABI par des tests natifs,
genere deux projets `_Standalone.lpi`, execute un test Pascal du codec puis
reconstruit serveur et client. Les dependances directes des binaires produits
sont inspectees. Elle s'arrete au premier echec, sans declarer un faux succes.

Sorties sur Linux x86_64:

```text
dist/x86_64-linux/MeshKVMServer
dist/x86_64-linux/MeshKVMClient
```

Lancement dans ta VM avec le mode de session que tu as valide:

```sh
export MESH_KVM_TOKEN='remplacer-par-un-jeton-secret-de-16-caracteres-minimum'
./dist/x86_64-linux/MeshKVMServer \
  --listen 127.0.0.1 --port 7900 --control \
  --session-policy backend --fps 20 --quality 80 --no-adaptive

# Depuis un autre terminal, definir le meme MESH_KVM_TOKEN.
./dist/x86_64-linux/MeshKVMClient --host 127.0.0.1 --port 7900
```

`backend` n'est pas active automatiquement. `strict` reste le defaut.
L'integration de code ne cree ni service logind, ni session graphique reconnue.
Une session connue comme verrouillee/inactive/changee reste refusee. `backend`
accepte seulement l'etat inconnu en s'appuyant sur le backend de capture;
ce choix reduit la garantie de detection du verrouillage.

## Options de construction

```sh
# Un seul des deux programmes:
sh build/build_standalone.sh --only server
sh build/build_standalone.sh --only client

# Construire les composants natifs puis finir dans Lazarus:
sh build/build_standalone.sh --prepare-only
# Ouvrir server/MeshKVMServer_Standalone.lpi et/ou
# client/MeshKVMClient_Standalone.lpi; pas les projets Default.

# Archive TurboJPEG d'un SDK pour LA MEME cible:
sh build/build_standalone.sh --turbojpeg-archive /chemin/libturbojpeg.a

# Ou compiler libjpeg-turbo depuis des sources deja presentes localement:
# Exige CMake, make et NASM sur x86_64. Aucun telechargement automatique.
sh build/build_standalone.sh --turbojpeg-source /chemin/libjpeg-turbo
```

Les anciens scripts/projets `Default` restent le mode historique a bibliotheques
separees. **Utiliser le script et les projets Standalone pour l'autonomie.**
Le mode apparait dans le terminal serveur et dans le fichier de log du client.
Les PPU des deux modes sont separees; reconstruire apres changement d'options.
Ne pas lancer deux preparations differentes simultanement dans le meme arbre.

## Wayland et H264 sous Linux (options de compilation)

```sh
sudo apt install pkg-config libglib2.0-dev libpipewire-0.3-dev libspa-0.2-dev
sh build/build_standalone.sh --with-portal

# Ajouter H264, avec les bibliotheques FFmpeg fournies par la distribution:
sudo apt install libavcodec-dev libavutil-dev libswscale-dev
sh build/build_standalone.sh --with-portal --with-codec
```

Ces options rendent les runtimes systeme correspondants necessaires au
chargement du programme, y compris lorsqu'on utilise ensuite JPEG/X11.
Elles ne compilent pas tout FFmpeg/PipeWire statiquement. Aucun
`libmeshkvm_codec.so`/`libmeshkvm_portal.so` n'est alors a distribuer.
La disponibilite reelle des encodeurs GPU depend toujours de FFmpeg, du pilote
et du GPU. Le dialogue de consentement Wayland reste obligatoire.

## Windows et macOS

Les chemins sont implementes mais non compiles sur ces OS dans cette livraison.
Les details, limites et commandes sont dans `docs/AUTONOME.md`.

Windows x86 ou x64: Python 3, FPC/Lazarus et MinGW pour la cible choisie.
Les chemins MinGW/TurboJPEG ci-dessous sont des exemples a adapter:

```bat
build_standalone_windows.cmd --arch x86 --toolchain-bin C:\toolchains\mingw32\bin --turbojpeg-archive C:\deps\turbojpeg\x86\libturbojpeg.a
build_standalone_windows.cmd --arch x64 --toolchain-bin C:\toolchains\mingw64\bin --turbojpeg-archive C:\deps\turbojpeg\x64\libturbojpeg.a
rem Ajouter --fpc et --lazbuild avec leurs chemins si necessaire.
rem Option DXGI experimentale sur les deux cibles: ajouter --with-dxgi.
```

Les projets Windows generes sont `_Standalone_x86.lpi` et `_Standalone_x64.lpi`.
Les sorties sont `dist/i386-win32/` et `dist/x86_64-win64/`. Le script passe
explicitement les cibles a FPC et lazbuild, et refuse un melange de fichiers.
`--arch` n'installe pas les compilateurs, leurs unites ni TurboJPEG.

macOS 12.3+, Xcode CLI tools, Lazarus Cocoa/FPC et archive TurboJPEG de la cible:

```sh
sh build/build_standalone.sh --turbojpeg-archive /chemin/libturbojpeg.a
```

## Verification et limites

```sh
python3 tools/audit_standalone.py dist/x86_64-linux/MeshKVMServer
python3 tests/test_standalone_build.py
sh tests/run_standalone_native.sh
```

L'audit lit les imports directs sans executer le binaire. Il ne certifie pas
les chargements tardifs du systeme, les plugins GTK/Qt, les pilotes GPU, la TLS
ou le fonctionnement KVM. Les tests du protocole et de capture existants restent
necessaires sur les machines cibles.

Ni service, ni installateur n'est ajoute. Les secrets, certificats et cles TLS
restent externes au programme. Conserver les notices des composants tiers lies
lors de ta distribution. Les journaux precedents et le README historique dans
`docs/` ne constituent pas une validation de ce nouveau mode.

**Liaison statique Windows MinGW/FPC :** voir `docs/LIEN_STATIQUE_WINDOWS_FPC_MINGW.md` pour le conflit `_tls_used`, les imports WinAPI et le groupe de bibliotheques genere.

Correctif liaison Windows : `docs/CORRECTIF_WINCRT_ARCHIVE.md` (suppression du script GNU ld GROUP, vraie archive ar CRT).

## mORMot2 amont (sans patch local)

Le constructeur ne modifie plus `mormot.lib.sspi.pas`. Le correcteur MSI
local et `--fix-mormot-msi` ont ete retires. `--mormot-dir` continue a
selectionner et reconstruire le paquet mORMot2 utilise par Lazarus.
L'audit final des imports reste actif en lecture seule.
Voir `docs/INTEGRATION_MORMOT2_AMONT.md`.


## Profil Windows LAN : JPEG qualite 100, FPS libres

Le profil `--quality 100 --fps 0 --no-adaptive --max-width 3840
--max-height 2160` evite les plafonds de 90/30 et la reduction de qualite
adaptative, tout en conservant le controle de flux et les limites memoire.
Voir `docs/LAN_QUALITE_FPS_LIBRES.md` pour les conditions et limites reelles.
