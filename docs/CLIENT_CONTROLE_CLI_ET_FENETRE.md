# MeshKVMClient : controle CLI et fenetre maximisee

Le client ouvre maintenant la fenetre **maximisee par defaut** (pas en mode
plein ecran exclusif). `--windowed` revient au format normal 1080 x 730.
`--maximized` est egalement accepte pour forcer le comportement par defaut.

Sous Windows, pour demander automatiquement le controle exclusif apres
connexion :

```bat
"C:\tranquilit\kvmlazarus\dist\i386-win32\MeshKVMClient.exe" ^
  --allow-insecure --host 10.11.9.30 --port 7900 ^
  --token VOTRE_NOUVEAU_JETON ^
  --control
```

- `--control` (alias `--auto-control`) : **demande** le controle au serveur
  quand le client a recu `OK CTRL` et que le bureau est disponible.
- Le client attend toujours la reponse `CTRL GRANTED`. Le serveur doit etre
  lance avec `--control`, la connexion doit etre faite avec un **jeton de
  controle** et non un jeton de consultation.
- Si le serveur repond `OK VIEW` ou `CTRL BUSY`, le client ne contourne pas le
  refus. Il ne relance pas `G` en boucle. En cas de deconnexion/reconnexion,
  la preference CLI est re-appliquee pour la nouvelle session.
- Une session verrouillee/inaccessible empeche la demande automatique.
  Si le bureau se verouille apres une prise de controle, l'utilisateur peut
  redemander le controle manuellement une fois revenu.
- Pour la saisie clavier a distance, cliquer dans l'image puis utiliser
  `--keyboard remote` si l'on veut les touches de l'agencement distant.
- `F8` continue d'afficher/masquer les commandes. Le controle peut etre
  libere par la case a cocher.
- Le client n'obtient **jamais** le controle sans validation serveur.

Le parametrage ne modifie ni mORMot2, ni la couche TLS, ni les archives de
liaison statique. Recompiler le **client** apres application des sources.

Securite : `--allow-insecure` desactive la contrainte TLS pour le reseau
non-local. Ne l'utiliser que sur un LAN de confiance ou sur VPN ; preferer
TLS pour des sessions sensibles. Ne pas reutiliser les jetons rendus publics.

## Tests

- `python tests/test_client_autocontrol_startup.py` : verifications de structure
  uniquement, aucun test Lazarus runtime.
- `sh tests/run_cli_tests.sh` : teste le vrai parseur Pascal si FPC est installe.
- Validation sous Windows requise : connexion CTRL, refus VIEW, CTRL BUSY,
  bureau verrouille, reconnexion, demarrage maximise, `--windowed`.
