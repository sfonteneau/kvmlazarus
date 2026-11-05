# Changements v8 -> v9

Base : archive utilisateur `MeshKVM_v8_Wayland_DXGI_Lazarus_mORMot2.zip`, SHA256
`4b92fed220ddbebc4a37d7fd8cde7841149bf4a514ddc5be96b86b4c226609be`.
Travail sur les sources existantes, pas reecriture du moteur MeshAgent et pas
revendication d'equivalence. Pas de service ni de packaging ajoute.

## P1 - sessions et verrouillages

`server/kvm_session_guard.pas`, `native/session/kvm_session_linux.c`,
`server/kvm_windows_session.pas`, `server/kvm_capture_mac.pas`,
`native/macos/kvm_sck.m`, `server/kvm_desktop.pas`, `kvm_server.pas`.

Sonde propre a la session du processus, identite epinglee, etat lu seulement par
le thread de capture puis snapshot verrouille utilisable par les entrees. Poll
a 200 ms au plus, y compris entre deux captures lentes ; snapshot age de plus
d'une seconde considere inconnu. Politique strict par defaut, option backend
moins protectrice pour UNKNOWN seulement. Changement d'identite observe latche
jusqu'au redemarrage. Les raisons/epochs passent au client dans le flux ordonne.

Linux : libsystemd chargee dynamiquement, UID/classe/ID du processus, Active et
LockedHint sur le bus systeme, timeout par appel 150 ms, reconnexion au bus sur
echec. Tests C avec facade logind et essai reel dans un conteneur sans session.
Windows : WTSActive et comparaison du bureau d'entree avec celui du thread ;
refus de session 0/Winlogon. macOS : cles publiques UID/console/login et gate du
stream SCK. Pas d'API privee de lock screen. Pas de session switching ou de login.

## P1 - clavier et texte compose

`shared/kvm_extwire.pas`, `kvm_input_queue.pas`, `kvm_keysym.pas`,
`server/kvm_server.pas`, `kvm_inject_x11.pas`, `kvm_inject_mac.pas`,
`client/kvm_view_form.pas`.

Commit UTF-8 U serialise et receipt I, validation complete avant injection,
cache du dernier resultat dans la connexion, conflit de numero refuse. File
client ordonnee et bornee, une requete de texte en vol, aucun renvoi automatique
apres timeout/partiel. Quota texte, budget de boucle, signalement de restauration
incomplete des modificateurs. Le nombre accuse n'est pas une verification de
l'application distante et l'injection n'est pas atomique.

Mode distant utilisant le clavier/IME deja installe cote serveur, mode compose
local conserve. Codes IME/F13+ ajoutes. X11 memorise le keycode reel des touches
maintenues ; un changement de disposition ne change pas le key-up. Une touche
non mappee dont le down n'a jamais ete injecte ne cree plus un key-up impossible
a relacher indefiniment. Mac ne declare plus succes pour un CGEvent nul et
reverifie Accessibilite. Pas de moteur TSF/IBus universel ni changement global de
keymap pour contourner les limites XKB.

## P1 - securite et bogues corriges

`shared/kvm_security.pas`, `kvm_tls_policy.pas`, `kvm_cli.pas`,
`server/kvm_server.pas`, `kvm_transport.pas`, client et executables.

- La v8 ne chargeait pas explicitement le fournisseur TLS mORMot2 sur POSIX.
  Ajout de `mormot.lib.openssl11` au serveur et au chemin TLS commun client/probe.
  La verification de certificat reste active ; tests reseau reel encore a faire.
- TLS exige hors loopback, derogation claire pour un tunnel de confiance.
  Token compare sans arret anticipe selon son contenu (pas une preuve formelle
  de temps constant du compilateur), pas de token ni texte saisi dans les logs normaux.
- Reservations d'upgrade, timeout pre-auth, nombre de sessions, buckets de
  commandes/octets/texte ; comparaison des droits au serveur ; fermeture effective
  du socket a l'expiration, au depassement ou apres trois NACK valides consecutifs.
- La reception client verifie la taille des marqueurs. En cas de debordement,
  fermeture plutot qu'un flux dont les donnees perdues seraient ACKees. Les
  resynchronisations de decodage conservent D/B/I, pas des images corrompues.
- Un echec SendFrame du client n'est plus silencieux : fermeture par le timer,
  sans rejeu. Nettoyage des objets partiellement construits renforce.

Les limites applicatives ne remplacent pas un firewall ni une protection TCP/HTTP
complete. Le decodeur natif reste dans le processus ; aucune garantie de timeout
contre un driver ou codec bloque.

## P2 - encodage materiel et lecture H.264

`native/codec/kvm_codec.[ch]`, `native/common/kvm_h264.h`,
`shared/kvm_codec.pas`, `kvm_extwire.pas`, `kvm_rgb_bitmap.pas`,
`server/kvm_video.pas`, `kvm_server.pas`, `shared/kvm_flow.pas`, client.

Pont FFmpeg C charge a cote des executables avec ABI versionnee. Liste fermee
NVENC/QSV/AMF/VAAPI/VideoToolbox. Conversion RGB/NV12 puis encodeur materiel ;
upload de surfaces pour VAAPI/QSV. Pas de repli logiciel H.264 en production.
`auto` retombe sur TurboJPEG ; libx264 n'est qu'une option de compilation de test.
Le client negocie sa capacite et decode via libavcodec, puis compose un bitmap LCL.

Chaque AU est independant (SPS/PPS + IDR, sans B/P interdependants). Les ACK et
caches par client restent bornes sans historique de reference par spectateur.
Trois profils JPEG et trois H.264 possibles ; bitrates H.264 demandes proportionnels
au profil. Une image identique n'est pas reencodee. Une nouvelle geometrie recree
l'encodeur ; un repli auto invalide les caches avant le prochain snapshot.

AVCC/Annex-B borne, 2 Mio par AU. Decodeur limite en dimensions, refs/allocation,
format 8-bit 4:2:0 ; dimensions exactes apres decode. La garde d'allocation
**accepte le padding H.264 (ex. 1080 ->1088)** au lieu de rejeter les tailles
visibles non multiples d'un macrobloc. Les helpers sont testes ; le vrai pont
libavcodec n'a pas ete compile ici, donc le decodeur complet reste a qualifier.

Compromis explicite : ce n'est ni du zero-copy ni un encodeur inter-frame.
Le debit peut etre moins bon que JPEG sur du texte statique ou que H.264 avec
prediction temporelle. Le decodeur est CPU et les transferts/copies existent.
Aucun gain FPS/debit/CPU mesure sur l'application complete.

## P2 - instrumentation et bancs d'essai

`server/kvm_metrics.pas`, `tools/bench_codec.py`, `bench_network.py`,
`bench_process.py`, `summarize_metrics.py`, `kvm_ws.py`.

CSV cumulatif : tentatives/captures reussies, temps capture, cout du pipeline par
profil, lots/octets mis en file, refus, ACK et rejets de securite. L'echec d'ecriture
des metriques desactive seulement les mesures, pas le partage. Les fichiers de
mesure existants ne sont pas ecrases intentionnellement.

Banc codec contre le vrai pont compile, captures synthetiques, encode/decode
p50/p95 et CPU ; sortie d'indisponibilite si pont absent. Banc reseau ACK a la
reception uniquement, donc pas de mesure d'affichage. Sampler CPU/RSS d'un PID
existant sans creer de service, et resume des compteurs CSV. Tous les parametres
et champs mesures sont documentes dans PERFORMANCE_V9.md.

## Tests et statut

Suites Pascal v9, regressions CLI et coeur, tests reseau d'autorisations/quotas,
probe TLS mORMot2 utilisant exactement la politique du client, fixtures CA valide,
mauvaise CA, nom faux et expire. Tests des helpers C sous sanitizers et tests des
outils Python. **Un test ajoute n'est pas un test execute.** VALIDATION_V9.md
liste les executions et les absences sans les confondre.

Le protocole est uniquement meshkvm7. Les anciens documents sont historiques et
les anciennes suites servent aux regressions, pas au support des anciennes versions.
