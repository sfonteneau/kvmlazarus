# MeshKVM v9 - interface cliente escamotable

## Objectif

Afficher le bureau distant sur **toute la zone cliente** de la fenetre, sans
bandeau fixe de 124 pixels. Ne rien changer au protocole ni au serveur.

## Usage

1. Au demarrage, les champs hote/port/token et les boutons sont visibles.
2. Des que le serveur repond `OK CTRL` ou `OK VIEW`, le panneau se masque.
3. Une petite poignee `...` en haut a droite ou la touche **F8** affiche le panneau.
4. Le bouton `X` ou F8 le masque ; la position et la taille de l'image restent
   inchangées car le panneau est en surimpression (`alNone`).
5. Le titre de la fenetre garde le statut. En cas de deconnexion, le panneau
   revient pour se reconnecter.

**F8 est reserve au client**, et n'est pas transmis au systeme distant.
Pour reprendre la saisie clavier distante apres la fermeture du panneau,
cliquer dans le bureau distant. L'ouverture du panneau relache les touches
et boutons distants maintenus, afin d'eviter les entrees bloquees.

## Installation

Remplacer seulement `client/kvm_view_form.pas` et reconstruire `MeshKVMClient.lpi`.
Les parametres serveur et client restent inchanges. Il n'est pas necessaire de
recompiler `MeshKVMServer`.

## Verification

`python3 tests/test_client_ui_overlay.py` controle les chemins essentiels du
code (il ne lance pas la LCL). `python3 tests/check_project.py` valide la
structure generale. Les interactions doivent ensuite etre essayees sur une
session GTK2/Qt/Cocoa et les raccourcis testés sur des claviers locaux.
