# Validation - clipboard bidirectionnel

Date : 2026-11-06. Base exacte :
`MeshKVM_v9_P123_FPS_libres_controle_CLI_sources.zip`.

## Execute ici

* **83 tests Python reussis** via `python3 -m unittest discover -s tests -p 'test_*.py'`.
  Ce total comprend les regressions des outils de construction (certaines
  avec des compilateurs simules), 8 nouveaux controles structurels clipboard,
  et 7 essais XCB natifs. Il ne s'agit PAS de 83 tests du moteur KVM en execution.
* **7 essais XCB natifs reussis sur un Xvfb prive** : echange UTF-8 (accents/emoji),
  texte vide, 64 Kio, changement de proprietaire, requestor detruit, transfert
  INCR, lecture de propriete bornee. Le test utilise les memes points d'entree
  scalaires et offsets X11 que l'unite Pascal, mais passe par Python/ctypes.
  Il valide ces appels/protocoles sous Linux x86-64, PAS la compilation ni
  l'execution de `kvm_clipboard_x11.pas`.
* **578 assertions structurelles/lexicales et controles de scripts** reussis
  par `tests/check_project.py`. Ce n'est pas une verification semantique Pascal.
* Integrite ZIP, manifeste SHA-256 et comparaison du correctif avec la base
  verifies lors du packaging. Les sources non modifiees sont preservees.

Journaux dans `docs/validation-clipboard/`.

## Ecrit mais NON execute ici

`test_clipboard_wire.lpr` : vrai encodeur/parseur Pascal, aller-retour, limites,
Unicode malforme, troncature, flags, sequence/epoque nulle, retours de ligne.

`test_clipboard_workers.lpr` : vraies classes de worker serveur/client avec des
backends OS simules. Consentement initial, sens unique, deux sens, copie du meme
texte via compteur natif, absence d'echo, refus apres retrait d'autorisation.

`tests/run_clipboard_tests.sh` a ete lance et sort **2 / NOT RUN**, car FPC et
Lazarus ne sont pas installes dans cet environnement. Les tentatives de
recuperation du compilateur n'ont pas abouti. Aucun resultat de test Pascal
n'est annonce comme reussi.

## Non valide

* Compilation des nouveaux executables Pascal serveur/client Windows x86/x64,
  Linux ou macOS, avec Lazarus/mORMot2.
* Execution du backend Win32 CF_UNICODETEXT et du backend NSPasteboard.
* Execution des workers Pascal, y compris sous Linux X11.
* Echange reseau complet avec de vraies applications et vrais presse-papiers.
* Rendu et clic des nouvelles cases dans le panneau Lazarus.
* Performances, TLS et transitions de session de bout en bout.

Les appels natifs peuvent eux-memes attendre une application proprietaire
(clipboard a rendu differe) ou le systeme. Les delais applicatifs ne peuvent
pas interrompre de facon sure un appel OS deja bloque. Le traitement est
isole du thread GUI/video, mais la fermeture attend le worker pour eviter
les callbacks vers un objet detruit.

## Portee et limites deliberees

Texte seulement, 64 Kio, pas HTML/RTF/images/fichiers ni collage automatique.
Wayland natif indisponible pour le clipboard. X11 utilise CLIPBOARD, pas PRIMARY;
la detection de changements identiques successifs est limitee sur X11.
Les deux interrupteurs exigent le controle exclusif et sont off par defaut.
Le protocole passe a `meshkvm8` : serveur et client doivent etre recompiles.
Aucune affirmation de validation production ou d'equivalence MeshCentral.
