# References MeshCentral et API natives - v8

L'archive MeshCentral fournie sert de reference pour les principes, notamment
`public/scripts/agent-desktop-0.0.2.js` (operations JPEG ordonnees, taille de
bureau, rafraichissement), `meshdesktopmultiplex.js` (spectateurs et etats
individuels) et `agents/meshcore.js` (orchestration et droits).
Elle ne contient pas le moteur natif MeshAgent en C/C++. Les ponts de ce
projet sont des implementations originales, pas une reprise ligne par ligne.

La v8 conserve Lazarus/mORMot2, TurboJPEG, le cache de rectangles et un
protocole specifique. Elle ajoute les chemins DXGI et Wayland/portail et les
formes natives du curseur composees dans les images. Ces ajouts ne prouvent
ni l'equivalence fonctionnelle, ni la maturite ou les performances de MeshAgent.

## Documents primaires utilises pour les contrats d'API

- XDG RemoteDesktop : https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html
  CreateSession, SelectDevices, Start, NotifyPointer/Keyboard, consentement,
  type string du session_handle et combinaison avec ScreenCast.
- XDG ScreenCast : https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html
  SelectSources, cursor_mode, streams, pipewire-serial/PW_KEY_TARGET_OBJECT
  et OpenPipeWireRemote.
- PipeWire : https://docs.pipewire.org/video-play_8c-example.html
  Negociation video, cycle des buffers et metadonnees de crop. Notre pont
  n'est pas une copie de cet exemple et ne reprend pas un moteur de rendu.
- Microsoft Desktop Duplication : https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api
  Surface BGRA, dirty/move regions, rotation et pointeur separe ou compose.
- Apple ScreenCaptureKit : https://developer.apple.com/documentation/screencapturekit
  SCStream, SCStreamConfiguration, showsCursor et statuts de frames.
- Declarations mORMot2 : archive utilisateur, src/net/mormot.net.ws.core.pas,
  mormot.net.ws.server.pas, mormot.net.http.pas et mormot.core.base.pas.
  L'acces aux files sortantes est specifique a ces declarations. La verification
  des sources ne remplace pas une compilation avec FPC/Lazarus.

## Permissions et redistribution

Wayland passe par une autorisation locale du portail, sans restore token
persistant. Windows/macOS requierent toujours un lancement autorise et les
permissions natives ; pas de barre de consentement par spectateur equivalente
a celle de MeshCentral. Ne pas utiliser sur une machine sans autorisation.

Aucun code MeshCentral/MeshAgent n'est copie dans les nouveaux ponts.
Conserver les licences des dependances separement distribuees : mORMot2,
TurboJPEG, FPC/Lazarus, GLib/PipeWire et leurs dependances, ainsi que les
conditions des outils/runtime de plateforme. Le ZIP contient nos sources,
pas les bibliotheques tierces ou leurs fichiers de police.
