# MeshKVM v9 - protocole meshkvm7

WebSocket `/kvm`, sous-protocole **meshkvm7 uniquement**. Entiers little-endian,
coordonnees pointeur normalisees 0..65535. Pas de compatibilite v8, VNC ou MeshAgent.
TLS exige hors loopback sauf opt-in `--allow-insecure`. Cette exception ne
modifie jamais la verification des certificats d'une connexion TLS.

## Connexion et droits

Premier message texte : `AUTH <token> <jpeg|h264>` (ASCII, <=272 octets).
Le token contient 16..256 caracteres sans espace. La capacite `h264` signifie
**JPEG et H.264**, pas H.264 exclusif. Le serveur peut rester/revenir a JPEG.
Reponses positives `OK CTRL` ou `OK VIEW`. Un mauvais token ou un plafond depasse
ferme la connexion, sans attendre une reponse d'erreur applicative.

Avant activation, aucune video ni entree. `OK CTRL` autorise seulement une demande
de controle ; la possession exige `G` puis `CTRL GRANTED`. Un seul possesseur.
Autres statuts texte : `CTRL BUSY`, `CTRL RELEASED`, `ERR INPUT`. Cette derniere
reponse ne signifie pas que l'OS n'a applique aucun effet avant l'erreur.

32 reservations WebSocket maximum, 16 sessions authentifiees. AUTH doit arriver
en moins de 5 s. Budget global d'upgrades : rafale 32 puis 4/s. Ce sont des bornes
applicatives apres/pendant l'upgrade, pas une limite de toutes les connexions TCP
ou de toutes les allocations du framework.

## Serveur vers client

Les tailles incluent le prefixe. `n` vaut le nombre d'octets de la donnees utile.

| Message | Champs apres prefixe | Taille |
| --- | --- | --- |
| D | available:u8, reason:u8, epoch:u32 | 7 |
| S | largeur:u16, hauteur:u16 | 5 |
| T | x:u16, y:u16, largeur:u16, hauteur:u16, JPEG | 9+n |
| V | codec:u8=1, largeur:u16, hauteur:u16, n:u32, H.264 Annex-B | 10+n |
| C | visible:u8, x:u16, y:u16 | 6 |
| B | serial:u32 | 5 |
| I | input_serial:u32, status:u8, applied:u16 | 8 |

`D` : raisons 0 inconnu, 1 actif, 2 verrouille, 3 inactif/deconnecte,
4 identite changee, 5 capture indisponible. Epoch non nul, incremente aux
transitions du serveur. `available=1` exige reason=1. D0 efface l'image et retire
le controle a sa reception. D1 permet une reconstruction complete, pas une
reprise implicite du controle. **D reste ordonne avec les images et B** ; il n'est
pas traite en avance comme un simple label. Un D isole ne demande pas d'ACK.

JPEG : rectangles fusionnes issus d'une grille 256 pixels, limites heritees
512x512 et 2 Mio par JPEG (TurboJPEG 4:4:4). En-tetes de taille controles avant decodage dans le worker CPU.
H.264 : dimensions paires, un access unit <=2 Mio, avec SPS/PPS/IDR autonome ;
pas d'image P/B faisant reference a un lot precedent. Les conversions AVCC/Annex-B
sont bornees. Le scan de NAL n'est pas une validation semantique H.264 : celle-ci
reste confiee au decodeur FFmpeg, avec contraintes de dimensions/allocation.

Ecran <=8192 par axe et <=16 777 216 pixels. Le callback d'allocation H.264 accepte
un petit padding de macroblocs, puis les dimensions visibles sont exigees exactes
au retour du decodeur. Pas de HDR ni de decodage arbitraire de conteneurs/media.
`C` sert au curseur de secours X11 sans XFixes ; normalement le curseur est inclus
dans la capture, donc pas de protocole de forme de pointeur separe.

## Client vers serveur

| Message | Champs apres prefixe | Role |
| --- | --- | --- |
| A / N | serial:u32 | ACK apres application du lot / rejet |
| P | aucun | Activite, env. toutes les 3 s |
| R | aucun | Demander un snapshot sans annuler un lot en vol |
| G / L / Z | aucun | Demander / rendre / relacher les entrees du controleur |
| M | action:u8, bouton:u8, x:u16, y:u16 | Mouvement=0, appui=1, relachement=2 ; boutons gauche=1,droit=2,milieu=3 |
| K | pressed:u8, virtual_key:u16 | Code Lazarus/Windows-style 1..255 |
| W | pas:i16 | Molette bornee par le parseur |
| U | input_serial:u32, UTF-8 | Commit de 1..256 scalaires, <=1024 octets de texte |

Les limites M/K/W sont controlees avant injection. Une trame applicative client
ne depasse pas 1029 octets. Le plafond de parsing mORMot2 reste 4 Mio, donc cette
limite applicative n'empeche pas toute allocation anterieure au callback.

## Commit de texte et ordre des entrees

U a un numero non nul, premier numero 1, puis suivant exact avec bouclage a 1.
Le serveur valide tout l'UTF-8 avant injection : sequences surlongues, controles,
surrogates et valeurs hors Unicode sont refuses. Les caracteres sont injectes
un a un ; les modificateurs maintenus sont temporairement relaches puis restaures.
Budget de boucle 500 ms et quota 512 scalaires en rafale / 128 par seconde.
Une API native bloquee n'est pas interrompue de force par ce budget.

I contient : 0 succes, 1 refuse, 2 partiel, 3 echec, 4 numero obsolete/conflit.
`applied` compte uniquement les scalaires entierement soumis aux fonctions
natives. Il ne prouve pas leur acceptation ou leur affichage par l'application.
Une erreur au milieu d'un scalaire peut avoir des effets non comptabilises.

Le dernier U et son I sont conserves **dans la connexion**. Repetition identique :
meme I, aucune reinjection. Meme numero mais contenu different : statut 4.
Numero non suivant : statut 4. Pas de garantie exactly-once apres redemarrage,
reconnexion ou crash entre l'OS et l'enregistrement du resultat.

Le client n'envoie qu'un U non acquitte. Les autres K/M/W/U attendent dans une
file <=512 messages /64 Kio. I succes doit confirmer exactement le nombre de
scalaires attendus. Refus/partiel : abandon des entrees non envoyees et Z.
Numero incoherent ou absence de I pendant 4 s : deconnexion sans rejeu. Les
commandes de securite Z/L peuvent interrompre la file. Une perte de focus ou un
changement de mode clavier ne doit pas rejouer une composition devenue obsolete.

## Flux video et limites

Un seul lot en vol par client, <=8 rectangles JPEG et <=3 Mio de payloads image ;
un V est une image complete <=2 Mio+10 octets. D/S/C/B ajoutent jusqu'a 23 octets.
Budget adaptatif souple 128 Kio..3 Mio ; le premier rectangle/image peut le
depasser, jamais la limite du paquet. La famille H.264 et la famille JPEG
conservent chacune trois profils partages, selectionnes selon les ACK par client.
Un profil H.264 auto qui echoue peut devenir un profil JPEG sans renego.

Ajout tout-ou-rien dans la file sortante visee : <=4 Mio /64 trames, verrou
non bloquant, copies privees des payloads. Refus local : preparation annulee,
pas d'attente d'un ACK impossible, pas de NACK penalise. Cette limite ne couvre
pas la RAM totale, caches de profils, allocations GPU, TLS, TCP ou toutes les
structures mORMot2. Le processus codec reste dans l'application, non sandboxe.

Le client limite sa file binaire a 128 messages /16 Mio. Debordement ou taille
fixe invalide : fermeture, pas de suppression silencieuse suivie d'un ACK faux.
Sur erreur de decodage, la resynchronisation conserve les marqueurs B/D/I.
Le reseau ne touche jamais directement au bitmap LCL ; le timer UI applique.

R est limite a une resynchronisation toutes les 2 s et n'efface pas un lot en
vol. Seul A/N avec le bon numero l'acquitte. Trois rejets valides consecutifs
ferment la session. Activite valide requise dans les 15 s ; lot expire apres
20 s sans ACK. Les expirations appellent maintenant l'abandon du socket vivant,
pas seulement la suppression de l'etat applicatif.

Limites de commandes par session : 1000 en rafale puis 500/s ; octets 65536 en
rafale puis 32768/s. Trois commandes malformees ferment le pair. Les droits sont
verifies au serveur et ne dependent pas d'une case du client. Une permission OS,
une session ou un contexte d'entree peut changer entre deux sondes : ce protocole
ne rend pas les API graphiques atomiques avec le verrouillage du bureau.

## Mise a jour P1/P2 - sans changement du format meshkvm7

A est emis apres composition du lot dans le framebuffer CPU du worker,
independamment de la peinture LCL. Les presentations peuvent etre coalescees,
jamais les deltas non appliques. Le serveur garde un lot en vol par client.
D/I conservent leur ordre ; une pause publie une surface vide. Voir P1_P2_P3.md.
