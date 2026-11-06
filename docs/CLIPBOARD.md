# MeshKVM v9 - presse-papiers texte dans les deux sens

Base : MeshKVM_v9_P123_FPS_libres_controle_CLI_sources.zip fourni dans la conversation.
Date : 2026-11-06. Livraison de sources, pas d'executables precompiles.

## Utilisation

Recompiler le serveur ET le client. Le sous-protocole est maintenant `meshkvm8`.
Un ancien executable `meshkvm7` ne doit pas etre melange avec cette livraison.
La compression, les FPS libres, P1/P2/P3, la fenetre maximisee, le journal GUI,
les scripts autonomes Windows x86/x64 et `--control` au client sont conserves.
Aucune modification des sources mORMot2 n'est effectuee.

Dans le panneau F8 (ou bouton `...`), deux cases independantes sont ajoutees :

* **Mon presse-papiers -> distant** : le texte local courant, puis ses changements,
  sont copies dans le presse-papiers de la machine serveur.
* **Distant -> mon presse-papiers** : le texte distant courant, puis ses changements,
  sont copies dans le presse-papiers de la machine cliente.

Les deux cases sont DECOCHEES par defaut. Aucune option CLI ne les active.
Il faut d'abord obtenir le controle exclusif. Un jeton de visualisation seule
ne permet pas d'acceder au presse-papiers, dans aucun des deux sens. Le serveur
verifie cette regle, independamment de l'interface.

Cocher une case autorise le remplacement du presse-papiers de destination et
la transmission du texte deja present. Les deux sens peuvent etre actifs.
Si les deux sont actives avant la premiere transaction, la copie locale est
appliquee avant la lecture distante. Lors d'un changement simultane, une
nouvelle copie locale detectee pendant la requete prend la priorite en mode
bidirectionnel. Il ne s'agit pas d'une fusion de deux textes.

Le contenu recu n'est PAS colle dans l'application active et aucune touche
Ctrl+V n'est simulee. Utiliser ensuite le collage normal dans l'application
souhaitee. Images, fichiers et formats enrichis (HTML/RTF) ne sont pas transmis.
Si le texte local est deja identique au texte recu, l'ecriture est evitee pour
ne pas detruire inutilement des formats locaux plus riches.

Les cases sont remises a zero a la deconnexion, au retrait du controle et lors
d'une transition de session/bureau. Une reconnexion ne les reactive pas.
Une commande native ou un paquet deja en cours peut terminer : decocher ne
permet pas d'annuler retroactivement un contenu deja transmis ou applique.
Le contenu deja copie n'est pas efface a la deconnexion.

## Limites et reactivite

Texte UTF-8 valide, au maximum **65 536 octets** par copie. Pas de troncature :
un texte trop grand ou invalide est refuse et le statut l'indique. NUL interne
est refuse (incompatible avec CF_UNICODETEXT). Retours de ligne normalises en LF
sur le reseau, convertis en CRLF a l'ecriture Windows. Accents, caracteres
non latins et emoji sont geres par le codec UTF-8/UTF-16.

Le presse-papiers est interroge environ toutes les 250 ms, uniquement dans les
sens actives. Les operations natives et le transport du texte s'effectuent
hors du thread Lazarus et hors du worker video/capture. Une seule transaction
de presse-papiers est en vol; aucune file illimitee de copies n'est creee.
Le polling ajoute jusqu'a environ 250 ms, auquel s'ajoutent les temps OS/reseau.
Ce n'est pas une garantie de latence.

Apres reception, le texte et le compteur de changement local deviennent la
reference, pour ne pas renvoyer immediatement la meme copie au serveur. Sous
Windows et macOS, le compteur natif permet aussi de reconnaitre une nouvelle
copie du meme texte. Sous X11, la detection repose sur le contenu : recopier
exactement le meme texte sans changement intermediaire peut ne pas declencher
une nouvelle synchronisation.

Les reponses sont associees a une sequence et a l'epoque du bureau. Un resultat
perime apres changement d'option/session n'est pas applique localement. Une
reponse absente desactive la synchronisation : pas de rejeu automatique d'une
ecriture dont le resultat serait inconnu. Un etat OS "occupe" explicite peut
etre retente; une erreur generale n'est pas masquee comme un succes.

## Plateformes et dependances

| Plateforme | Backend fourni | Limites |
| --- | --- | --- |
| Windows x86/x64 | Win32 CF_UNICODETEXT, fenetre proprietaire cachee, memoire globale transferee a Windows | Implementation non executee ici; DLL systeme user32/kernel32 uniquement |
| Linux X11 | Connexion XCB privee, selection CLIPBOARD, UTF8_STRING, repli STRING ISO-8859-1, lecture INCR bornee | libxcb.so.1 du systeme; bibliotheque de developpement libxcb1-dev pour compiler. Ce n'est pas PRIMARY. |
| macOS | NSPasteboard via des declarations typees du runtime Objective-C | AppKit/Foundation/libobjc systeme; non compile/teste sur macOS ici |
| Wayland natif | Non implemente pour le presse-papiers | Refus explicite; pas de lecture silencieuse via XWayland, de commande wl-copy ou de contournement du portail |

La capture/control Wayland existante n'est pas retiree : seule cette nouvelle
fonction clipboard est indisponible sur ce backend. Sous X11, le processus qui
possede CLIPBOARD doit rester vivant pour fournir les donnees; sans gestionnaire
de presse-papiers, quitter ce processus peut faire perdre cette selection.

Les nouveaux composants sont des unites Pascal liees dans l'EXE. Aucun pont
MeshKVM prive additionnel, DLL GCC, DLL TurboJPEG ni extraction a l'execution
n'est ajoute par cette fonctionnalite. Les dependances natives du projet
preexistant restent celles du profil choisi.

## Compilation Windows autonome

Extraire le correctif a la racine `C:\tranquilit\kvmlazarus`, sans ajouter un
niveau MeshKVM intermediaire. Les nouvelles unites sont dans `shared/` et `client/`.

```bat
cd /d C:\tranquilit\kvmlazarus
build_standalone_windows.cmd --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a" ^
  --mormot-dir "C:\tranquilit\mORMot2"
```

Remplacer ensemble les deux EXE par ceux de `dist\i386-win32\`. Aucune nouvelle
option serveur n'est requise : `--control` et les droits du jeton restent
necessaires. L'activation du clipboard est exclusivement manuelle dans F8.
Pour x64, conserver la chaine de compilation et les options x64 habituelles.

## Securite et confidentialite

Le clipboard transporte des donnees potentiellement sensibles. Il utilise le
meme WebSocket que la video : **--allow-insecure ne chiffre ni le texte, ni le
jeton**. Preferer TLS ou un tunnel/VPN, meme sur un reseau local partage.

Aucun historique et aucune valeur de presse-papiers ne sont ecrits au journal.
Les erreurs n'incluent ni le texte ni les exceptions natives susceptibles de
le contenir. Les tampons sont bornes; cela ne constitue pas une promesse
que toutes les copies de memoire sont effacees de facon cryptographique.

Le serveur controle authentification, droit de controle, proprietaire exclusif,
epoque et disponibilite de session avant l'operation et avant la reponse.
Les quotas de clipboard sont separes des quotas clavier/souris. Aucune diffusion
aux autres spectateurs. La detection de verrouillage conserve les limites du
mode de garde choisi : `--session-policy backend` reste moins protecteur.

## Protocole ajoute

Nombres 32 bits little-endian. Encapsulation binaire WebSocket, sans JSON ni
base64. Ces messages sont separes des ACK/NACK video.

* Requete : `cQ | epoch:u32 | serial:u32 | flags:u8 | knownReadSerial:u32 | UTF8`.
  Flags : bit 0 ecriture, bit 1 lecture. Texte present uniquement si ecriture
  demandee; chaine vide valide pour une copie de texte vide. Taille entete 15.
* Reponse : `cR | epoch:u32 | serial:u32 | writeResult:u8 | readResult:u8 |
  hasText:u8 | UTF8`. Taille entete 13. Les valeurs de resultat sont definies
  dans `kvm_clipboard_wire.pas`. Une reponse "inchange" n'envoie pas le texte.

Un seul proprietaire du controle peut utiliser ce canal. Les sequences doivent
progresser exactement; les paquets malformes, repetitions et quotas depasses
ne sont pas traites comme une nouvelle commande native.

## Tests et recette

Voir `VALIDATION_CLIPBOARD.md`. Les suites Pascal utilisent des presse-papiers
simules et ne touchent PAS le presse-papiers personnel du poste.

```bat
set "FPC=C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe"
tests\run_clipboard_tests.cmd
```

Recette manuelle avec deux machines : copier un texte avec accents/emoji dans
chaque sens, tester une seule case, puis les deux, un texte de plus de 64 Kio,
une deconnexion, un retrait du controle et le verrouillage/reprise du serveur.
Verifier aussi que les cases restent eteintes apres reconnexion et que les
spectateurs sans controle ne peuvent pas les activer.

## References primaires utilisees

* Microsoft OpenClipboard : https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-openclipboard
* Microsoft SetClipboardData : https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setclipboarddata
* Microsoft GetClipboardSequenceNumber : https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getclipboardsequencenumber
* X11 ICCCM (selection/INCR) : https://xorg.freedesktop.org/releases/current/doc/xorg-docs/icccm/icccm.html
* XCB : en-tetes systeme xcb/xcb.h, xcb/xproto.h, xcb/xcbext.h utilises pour la verification ABI.
* Apple NSPasteboard : https://developer.apple.com/documentation/appkit/nspasteboard/
