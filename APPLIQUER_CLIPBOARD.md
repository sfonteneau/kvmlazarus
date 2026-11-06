# Appliquer le clipboard bidirectionnel

Base : MeshKVM_v9_P123_FPS_libres_controle_CLI_sources.zip.

1. Fermer le client et le serveur. Conserver une copie du dossier source actuel.
2. Extraire TOUT le correctif dans C:\tranquilit\kvmlazarus, en conservant
   client/, server/, shared/, tests/, tools/ et docs/. Ne pas remplacer seulement
   kvm_view_form.pas : les nouvelles unites partagees sont indispensables.
3. Relancer le script build_standalone_windows.cmd avec les memes parametres.
   Aucun patch des sources mORMot2 ni aucune nouvelle DLL privee ne sont ajoutes.
4. Remplacer les DEUX executables : le protocole est desormais meshkvm8.
5. Se connecter avec le droit de controle, puis ouvrir F8. Les cases
   "Mon presse-papiers -> distant" et "Distant -> mon presse-papiers"
   sont independantes et desactivees par defaut. Leur activation transmet le
   texte courant, puis les nouvelles copies. Aucun Ctrl+V n'est simule.

Unicode texte uniquement, 64 Kio, pas d'images/fichiers ni clipboard Wayland.
Les sources Windows/X11/macOS sont fournies, mais les nouveaux programmes
Pascal n'ont pas ete compiles dans l'environnement de livraison.

Guide complet : docs/CLIPBOARD.md.
Etat des essais : docs/VALIDATION_CLIPBOARD.md.
