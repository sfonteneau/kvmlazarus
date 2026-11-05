# Changements v7 -> v8

Base : archive MeshKVM_v7_Adaptatif_ScreenCaptureKit_Lazarus_mORMot2.zip fournie.
Cette livraison modifie cette base ; elle ne reecrit pas MeshAgent et ne copie
pas son moteur C/C++. La comparaison est architecturale, pas une certification
d'equivalence. Les nouveaux chemins non compiles sont experimentaux.

## Backends

### Windows DXGI

`native/windows/kvm_dxgi.cpp`, `server/kvm_capture_dxgi.pas`,
`server/kvm_windows_session.pas`, `native/common/kvm_pixels.h`.

Device D3D11 lie a l'adaptateur du moniteur, Desktop Duplication, copie des
regions sales et des destinations de mouvements depuis la surface courante,
repli copie complete. Les destinations ne sont pas copiees a partir d'un
ancien tampon dans un ordre potentiellement destructif. Surface de staging
reutilisee, detection des dimensions reelles de la texture, rotation 0/90/180/270,
redimensionnement RGB et gestion RAII de ReleaseFrame/Map/Unmap.
Perte d'acces -> destruction dans le thread de capture puis recreation.
`auto` peut revenir a GDI ; `dxgi` explicite exige un moniteur individuel et
le pont compile. Pas de DXGI sur le bureau virtuel assemble (index 0).

Les zones GPU sont optimisables mais le readback et la conversion sont encore
CPU ; TurboJPEG encode ensuite. Pas d'encodage GPU, HDR ni zero-copy integral.
Le controle Windows utilise maintenant SendInput avec verifications de retour.
Le bureau d'entree doit correspondre au bureau du thread, hors Winlogon.
Pas de changement de bureau securise, d'elevation ni de contournement UAC.

### Wayland

`native/linux/kvm_portal.c`, `server/kvm_wayland.pas`, `shared/kvm_keysym.pas`.

Session utilisateur XDG, selection d'un ecran par ScreenCast, clavier/pointeur
RemoteDesktop lorsque --control est demande, ouverture du FD PipeWire.
Abonnement au signal Response avant chaque demande pour ne pas perdre une
reponse rapide. Delai de consentement borne, fermeture des objets de demande,
aucune memorisation de restore_token. Revocation = nouvelle autorisation locale.

Selection PipeWire par object.serial lorsque le portail fournit pipewire-serial,
pour ne pas viser un identifiant de noeud recycle apres hotplug. Le node ID
reste utilise pour les commandes RemoteDesktop de la session.

Flux PipeWire BGRx/BGRA/RGBx/RGBA, memoire CPU mappee, tampon du dernier ecran
borne ; validation des dimensions, stride, offsets, taille, crop et metadonnees.
Coordonnees du pointeur corrigees selon la geometrie logique et le crop, pas
une supposition 1 pixel = 1 coordonnee logique. Les appels d'entree D-Bus sont
bornes ; les relachements restent possibles si la video se suspend.
Pas de DMA-BUF, pas de commande shell, de uinput/root ou de capture cachee.

### Curseur et macOS

`server/kvm_cursor_x11.pas`, `shared/kvm_cursor.pas`, les captures GDI/DXGI,
et `native/macos/kvm_sck.m`.

XFixes copie ses pixels ARGB au format unsigned long natif, important sur LP64,
respecte le hotspot et compose avec alpha premultiplie. Une copie privee protege
les alias de framebuffer. GDI utilise DrawIconEx. DXGI n'ajoute le curseur que
si le pointeur est separe de la surface acquise. ScreenCaptureKit demande
showsCursor ; PipeWire demande le mode embedded. Sans XFixes, croix de repli.

ScreenCaptureKit suspend l'image sur les statuts blank/suspended/stopped ;
l'etat du handle natif n'est interroge que par son thread proprietaire, pour
eviter une course lecture/liberation avec les threads reseau. Le flux suspendu
est garde lorsque possible, pas recree en boucle a chaque tick.

## Corrections du flux

`server/kvm_transport.pas` est un descendant de TWebSocketServer. Il utilise
les declarations de l'archive mORMot2 fournie, sans patch du framework. C'est
une integration aux structures internes/protegees de mORMot2 qui devra etre
revue si le framework change. Un controle lexical de noms ne prouve pas sa
compilation ni son comportement sur les architectures cibles.

Ajout atomique de D/S/T/C/B, limites 4 Mio/64 trames et TryLock non bloquant.
Une preparation refusee ne reste pas en attente d'un ACK qui n'arriverait pas.
Les payloads de sortie ne partagent plus leurs octets modifiables avec le
cache. Une allocation interrompue nettoie les nouveaux payloads sans toucher
le prefixe deja en file. Les verrouillages de l'etat client sont relaches
avant les verrous de la liste de connexions pour eviter une inversion d'ordre.

D0/D1 transitent dans la file binaire, pas dans une file texte traitee en avance.
Le client preserve D et B pendant les purges ; la reception de S ne peut plus
supprimer un D1 ou un B encore necessaire. A la pause, les captures anciennes
ne restent pas presentees comme une image en direct une fois D0 traite.
Le serveur invalide les snapshots, retire le controle et le redemande a la
reprise. Il ne considere pas un ACK d'une ancienne geometrie comme un reset.

Verification supplementaire des tampons avant CompareMem/Move, limite RGB
alignee sur 16 777 216 pixels, bouclage explicite des numeros de lots et de
tuiles (pas d'overflow implicite sous -Co).

## Corrections des entrees et du client

Le serveur accepte un commit UTF-8 entier borne, refuse tout le paquet s'il
est mal encode, relache temporairement les modificateurs et les restaure
individuellement. L'injection native reste faillible et peut etre partielle.
Un ERR INPUT explicite remplace certains echecs silencieux, notamment XKB.
Le bouton Texte / IME fait composer localement, sans promettre le protocole
IME distant complet. Pas de detournement du presse-papiers pour l'injection.

Le client distingue les touches supprimees pour saisie texte et les touches
reellement transmises. Un raccourci appuye puis repete ne perd plus sa touche
up parce que les modificateurs ont change entre-temps. Le masque de boutons
souris conserve la capture pour les glissers multiboutons ; sortie de la zone
image ramenee au bord pendant le glisser. Deltas de molette partiels cumules.
Bouton Texte desactive en attendant la nouvelle attribution de controle.

Les erreurs de liberation ne stoppent plus le relachement des autres touches.
Le serveur garde les key-up/button-up echoues et les retente avant une nouvelle
attribution de controle sur une capture valide. Une terminaison brutale, un
verrouillage durable ou un OS qui refuse l'injection reste hors garantie.

## Parametres et tests

Nouvelle option --backend auto|x11|portal|gdi|dxgi|sck, restrictions par OS dans
kvm_desktop. Sous Wayland la selection locale remplace l'index de moniteur.
Sous Windows DXGI explicite exige --monitor 1 ou plus. Options token/host/
listen/port/profils/TLS conservees ; aucune compatibilite d'ancien protocole.

Tests C du vrai convertisseur utilise par les ponts, avec ASan/UBSan et jeux
aleatoires bornes. Extension XFixes du test X11 sur Xvfb. Ajout de tests Pascal
UTF-8, overflow, copie/alias curseur, validation de framebuffer, file/ACK et CLI.
Ils sont fournis mais non executes faute de compilateur. Voir VALIDATION_V8.md.

## Ecarts restants

Pas de service multi-session ou d'acces au login/verrouillage, pas d'IME distant
complet, pas de protocole de curseur separe, pas de composition multiecran DXGI,
pas de presse-papiers/audio/fichiers. Pas de benchmark ni de validation de bout
en bout. Ne pas presenter cette version comme equivalente a MeshAgent teste.
