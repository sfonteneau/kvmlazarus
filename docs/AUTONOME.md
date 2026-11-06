# Implementation du build autonome

Date: 2026-11-06. Base: v9 client journal GUI sans console.

## Ce qui change dans le code

Le symbole de compilation `KVM_STANDALONE` active des declarations `external
name` pointant sur du code natif lie au programme. Les pointeurs de fonctions
utilises par les classes Pascal sont affectes a ces fonctions liees au lieu
d'etre recherches dans des DLL. Les proprietes du protocole ne changent pas.

Les unites statiques sont separees par role pour eviter d'imposer au client
les dependances systeme du serveur:

- `shared/kvm_turbojpeg_static.pas`: compression/decompression, archive
  `libkvm_turbojpeg.a` copiee d'une vraie `libturbojpeg.a`.
- `server/kvm_session_static.pas`: garde Linux, archive `libkvm_session.a`.
- `server/kvm_portal_static.pas`: portail, si demande a la compilation.
- `server/kvm_dxgi_static.pas`: DXGI, si demande a la compilation.
- `server/kvm_sck_static.pas`: ScreenCaptureKit sous macOS.
- `shared/kvm_codec_static.pas`: pont H264, si demande a la compilation.

Les noms d'archives dedies evitent qu'un `-lturbojpeg` choisisse par accident
une version partagee dans le meme SDK. Aucun `.dll.a` d'import n'est accepte
pour TurboJPEG. Les archives contiennent les definitions, pas seulement des
adresses importees. Le script n'utilise pas `-static` globalement: libc,
X11/GTK et les frameworks restent des bibliotheques systeme.

Les sources d'encodeur, de capture, de protocole, de permission et d'affichage
ne sont pas remplacees par des stubs. Quand un composant optionnel n'est pas
integre, il est signale explicitement comme indisponible, sans charger un
module tiers trouve dans le repertoire courant.

## Build reproductible sur la cible, pas binaire universel

Le script controle la cible de FPC (`-iTP`, `-iTO`) et celle du compilateur C.
Il se limite a Linux x86_64/aarch64, macOS x86_64/aarch64 et Windows x64.
Les architectures et les runtimes C ne sont pas interchangeables.
`--prepare-only` ne requiert pas FPC mais ne valide pas le lien Pascal.

Sous `native/static/<cpu>-<os>/`, le script cree les archives et les includes
`kvm_standalone_features.inc`, `kvm_*_link.inc`. Le fichier de fonctionnalites
est retire avant la preparation et recree seulement apres succes; une erreur
ne doit pas laisser croire que les nouvelles options sont pretes.

Chaque projet genere `_Standalone.lpi` utilise:

- `-dKVM_STANDALONE`;
- les chemins `-Fi`/`-Fl` de la cible preparee;
- un dossier PPU `lib/standalone/<cpu>-<os>`;
- une sortie `dist/<cpu>-<os>/MeshKVMServer` ou `MeshKVMClient`.

Ne pas copier ces fichiers intermediaires sur une machine cible d'une autre
architecture. Les binaires sont a construire sur un systeme compatible avec
le plus ancien systeme vise. Ce changement ne supprime pas les contraintes de
version glibc, widgetset, SDK Apple ou APIs Windows.

Le script ne telecharge ni compilateur, ni FFmpeg, ni mORMot2. Les fichiers
statiques mORMot2 deja installes restent des prerequis de compilation.
`MORMOT2_DIR` permet d'enregistrer le paquet Lazarus fourni par l'utilisateur.

## TurboJPEG

Le chemin natif classique conserve `tjCompress2`, `tjDecompressHeader3`,
`tjDecompress2`, JPEG 4:4:4 et les tampons reutilisables. Aucun repli du serveur
vers un encodeur Pascal lent n'est introduit. Un probleme de creation du
handle client garde le comportement de repli LCL existant.

Le script accepte une archive existante ou compile une arborescence source
libjpeg-turbo avec CMake. SIMD est demande et exige sur les cibles prises en
charge. Les dependances PNG/zlib de la compilation source sont configurees
pour utiliser leurs sources integrees lorsque cette version les propose;
le script ne les remplace pas par un autre paquet au hasard.

La premiere verification native lie `tests/test_static_turbojpeg.c` a
l'archive, encode/decode vraiment du JPEG, verifie le 4:4:4 et l'ordre BGR,
puis lance le test depuis un dossier temporaire ne contenant que l'executable.
Ensuite `tests/test_standalone_link.lpr` teste les declarations Pascal.
Ces deux tests sont automatises par le build, pas annonces comme executes ici.

## Linux: session et systeme graphique

Le garde C est inclus dans le serveur. `meshkvm_session_open_ex` retourne une
raison explicite si `libsystemd.so.0` ou un symbole de son ABI manque.
Il n'y a plus de resolution de `OpenGuard` dans `libmeshkvm_session.so` dans
le profil autonome. La bibliotheque du systeme continue d'etre chargee via
dlopen afin de pouvoir gerer son absence sans empecher le lancement du mode
`--session-policy backend` explicitement choisi.

La logique reste stricte par defaut. Un garde present ne garantit pas que le
processus appartienne a une session logind reconnue. `backend` ne desserre
que l'etat inconnu: pas un etat verrouille/inactif/changement d'identite connu.
Le programme ne cree pas de service, de PAM ou de session utilisateur.

X11/Xext/XTest et les bibliotheques graphiques du client restent necessaires.
XFixes garde son chargement systeme facultatif. `--with-portal` integre le
code MeshKVM du portail, mais pas les services du bureau ni PipeWire/GIO.
Il rend leurs bibliotheques obligatoires au chargement; garder le profil de
base pour une VM X11 sans ces composants.

## Windows

Le profil autonome de base utilise GDI, les APIs Windows et TurboJPEG lie.
Il exige une archive GCC/MinGW-w64 x64 compatible avec FPC, pas un `.lib`
MSVC ni une archive d'import DLL. Les runtimes C de compilateurs differents
ne sont pas automatiquement interchangeables.

`--with-dxgi` compile le pont C++ et prepare les runtimes statiques MinGW
necessaires. Une sonde C++ et un audit des imports sont executes avant la
construction Pascal. Le projet Pascal utilise le linker externe. Ce chemin
reste experimental: il n'a pas ete compile dans l'environnement de livraison.
En cas d'erreur de liaison, le build s'arrete; il ne copie pas une DLL pour
faire semblant d'avoir produit un executable autonome.

Le script refuse actuellement `--with-codec` sous Windows: la distribution
FFmpeg statique complete n'est pas automatisee. Copier ses DLL a cote ne
respecterait pas l'objectif choisi; le build autonome Windows livre est JPEG.
Le code H264 de la v9 reste disponible dans le profil historique dynamique.

## macOS

Le pont Objective-C ScreenCaptureKit est compile en archive et lie directement.
Les frameworks Foundation, ScreenCaptureKit, CoreMedia, CoreVideo, CoreGraphics
et le runtime Objective-C demeurent ceux du systeme. Le minimum demande est
macOS 12.3, avec une compilation native du meme CPU que FPC.

Le client utilise Cocoa et reste un executable sans bundle cree par ce script.
L'autorisation TCC, la signature/notarisation et l'identite de l'application
lors du deploiement ne sont pas gerees ici. Le fournisseur TLS POSIX existant
peut necessiter OpenSSL installe sur la cible: ce build n'integre pas OpenSSL.
L'option FFmpeg utilise egalement des bibliotheques installees sur le systeme,
qui ne font pas partie de macOS de base.

## FFmpeg optionnel sous Linux/macOS

`--with-codec` compile le pont prive dans le programme mais laisse
`libavcodec`, `libavutil`, `libswscale` et leurs dependances au systeme.
Leur presence devient une condition de lancement du binaire. Ce n'est pas
une integration statique complete de FFmpeg et de tous les pilotes GPU.
Ne pas annoncer H264 disponible sur une autre machine sans ces runtimes.

## Audit et distribution

`tools/audit_standalone.py` lit `readelf -d`, `objdump -p` ou `otool -L`.
Il refuse un import direct MeshKVM/TurboJPEG; sous Windows, il refuse aussi
les DLL hors liste systeme. Il n'execute pas l'executable inspecte.
Cela ne couvre pas tous les imports transitifs, plugins ou chargements tardifs.
L'audit doit etre accompagne d'un essai sur une machine cible propre.

Aucun installateur, service ou mecanisme d'extraction n'est ajoute. Les secrets,
cles, certificats et choix d'autorisation ne sont pas compiles dans le binaire.
Le fichier de journal du client reste produit dans le profil utilisateur.
Les mentions et notices des bibliotheques liees doivent rester disponibles
avec la distribution du produit; elles ne sont pas incluses implicitement par
ce script a partir d'un SDK arbitraire.

## References techniques de construction

References consultees pour les directives et les formats de bibliotheques;
ce ne sont pas des preuves de compilation de ce projet:

- FPC, liaison externe: https://www.freepascal.org/docs-html/prog/progsu149.html
- FPC, LINKLIB: https://www.freepascal.org/docs-html/current/prog/progsu46.html
- FPC, options: https://docs.freepascal.org/daily/doc/user/userap1.html
- libjpeg-turbo: https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/BUILDING.md
- Archive de developpement Debian: https://packages.debian.org/trixie/libturbojpeg0-dev
- logind: https://freedesktop.org/software/systemd/man/latest/sd-login.html
