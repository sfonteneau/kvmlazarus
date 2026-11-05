> Historique v7 conserve pour tracabilite. Pour la livraison courante, lire les documents V8.

# Revue et changements v6 -> v7

## Implementation livree

1. `kvm_capture_win.pas` conserve DC, DIB et pointeur de pixels tant que la
   geometrie ne change pas. Nettoyage explicitement execute par le thread
   de capture qui a acquis les DC ; capture de la region du moniteur choisi.
2. `kvm_x11_session.pas` centralise une connexion Display et son verrou.
   Capture, enumeration, injection et pieges d'erreurs X11 sont serialises.
   `kvm_capture_x11.pas` ajoute MIT-SHM, permissions SysV 0600, marquage de
   destruction apres attachement et repli reutilisable XGetSubImage.
   Le pointeur shmat est retire de XImage avant XDestroyImage pour eviter un
   free invalide. Nettoyage explicite du segment et du Display.
3. `native/macos/kvm_sck.m` ajoute un pont C ABI vers ScreenCaptureKit, ARC,
   callback serialise, validation des frames completes, retention d'un seul
   dernier CVPixelBuffer et copie RGB24 avec respect du stride. Enumeration
   et demarrage sont temporises ; arret et suppression du destinataire sont
   explicites. `kvm_capture_mac.pas` charge ce pont a cote de l'executable.
   Changement de dimensions/display/cadence : reconstruction du stream.
4. `kvm_adaptive.pas` fournit une moyenne des delais ACK, un budget de lot,
   trois niveaux et une hysteresis. `kvm_video.pas` isole chaque cache/encodeur.
   Un client lent n'impose pas sa qualite a tous les autres. Les buffers de
   capture sont dimensionnes d'apres toutes les sessions actives, pas seulement
   celles qui peuvent recevoir a cet instant, pour eviter des reconfigurations
   incessantes au rythme des ACK.
5. `kvm_monitors.pas` enumere les ecrans (EnumDisplayMonitors / XRandR / Quartz),
   expose `--list-monitors` et `--monitor`, suit leur identite et separe pixels
   de capture et coordonnees de bureau. `kvm_geometry.pas` centralise les
   conversions, y compris les origines negatives et les bords.
6. `kvm_mouse_state.pas` fournit les vrais evenements Quartz de glisser gauche,
   droit et milieu. Le backend macOS maintient aussi les modificateurs et un
   compteur de clics. Le client capture la souris pendant le geste et libere
   les entrees au changement de fenetre. Un bouton peut encore etre relache
   lorsque le moniteur vient de disparaitre.
7. Windows : SendInput pour les touches, flags etendus pour navigation,
   touches systeme et modificateurs droits. X11 : recherche de symbole dans
   le groupe XKB actif, niveaux Shift/AltGr, preservation de CapsLock.
   Le serveur relache temporairement ses modificateurs autour du texte UTF-8
   puis les restaure. Cela n'est PAS une solution universelle IME/clavier.
8. L'analyse des arguments accepte les nouveaux plafonds, moniteurs, cadence
   jusqu'a 30 et `--no-adaptive`. Les limites de taille sont communes au fil
   reseau et aux validations. Pas de vieux protocoles conserves.

## Defauts supplementaires corriges pendant cette passe

- Une demande R ne doit pas abandonner un lot non acquitte : c'etait une
  possibilite de contourner la contre-pression par rafraichissements repetes.
  R attend maintenant la terminaison du lot ; N rejette explicitement un
  numero de lot. Les ACK/NACK perimes ne liberent pas le lot courant.
- Le client qui rejette un JPEG doit conserver B, meme en purgeant sa file,
  faute de quoi il ne peut plus NACKer le lot. Cas du B declenchant lui-meme
  le depassement de file pris en compte.
- Validation des en-tetes JPEG baseline avant allocation du decodeur :
  dimensions, profondeur, composants, longueur SOF/SOS, rejet de SOF multiples.
  Cette validation ne remplace pas les protections du decodeur JPEG.
- Authentification : une session n'est eligible aux images qu'apres l'envoi
  de sa reponse OK, pour eviter la course entre admission et premier lot.
- Le curseur devient explicitement invisible lorsqu'il quitte le moniteur
  capture, plutot que d'etre bloque sur son dernier bord.
- AllocateFrame rend son buffer unique avant reutilisation : un alias ne
  doit pas etre modifie quand la capture suivante ecrit dans la meme chaine.
- Une erreur d'encodage apres changement de geometrie ne doit pas perdre la
  notification S : le cache conserve le changement en attente jusqu'au succes.
- Chaque cache valide tous ses JPEG avant de publier les nouvelles versions.
- Les erreurs natives de capture sont journalisees avec pause avant nouvelle
  tentative ; aucun buffer natif n'est detruit par un thread arbitraire.

## Choix conserves, pas des optimisations deja accomplies

Les rectangles restent fixes au maximum 1024 x 512, l'encodage CPU TurboJPEG
4:2:0 et le decodage client LCL. Le redimensionnement des profils en Pascal
utilise le plus proche voisin ; ce n'est ni un filtre de haute qualite ni une
acceleration GPU. Le calcul des differences lit encore toutes les tuiles.
Le protocole ne promet pas d'image complete atomique entre plusieurs lots.

Le passage de l'algorithme dans les sources a une implementation valide sur
les trois OS exige encore compilation et tests. Aucun pourcentage de gain
par rapport a v6 ou MeshAgent n'a ete mesure.
