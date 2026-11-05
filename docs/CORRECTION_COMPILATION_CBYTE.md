# Correction compilateur : CByte non defini (Linux X11)

Dans `server/kvm_x11_api.pas`, `TXkbState` utilisait `CByte`, qui n'est pas un nom de type reconnu ici par Free Pascal.
Les champs de `XkbStateRec` sont des `unsigned char` dans l'en-tete X11 `XKBstr.h` : on utilise des `Byte` (8 bits non signes).
Les champs `CUShort` restent inchanges, ainsi que `{$packrecords c}` pour l'alignement C.

Deux remplacements aux lignes 78 et 80. La correction de `kvm_transport.pas` (import mormot.core.os) est conservee.

Validation : comparaison avec l'en-tete C X11 local, recherche globale de CByte, controle de structure statique. Pas de compilation FPC/Lazarus dans cet environnement.
