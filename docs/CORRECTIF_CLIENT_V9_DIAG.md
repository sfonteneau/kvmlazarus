# Correctif client v9 : compilation et diagnostic de connexion

## Ce que le dernier fichier utilisateur contient reellement

Le fichier `Texte colle(20261105-221338).txt` fourni est **un client v9**, pas un client v8 : il comprend les paquets D/I/V et les acquittements de saisie. Notre commentaire precedent disant le contraire etait une erreur.

Les deux changements de l'utilisateur par rapport a l'archive WS corrigee sont `Visible` -> `Visible1`, et `Text` -> `TextA` pour `SetStatus`. Le second renommage avait laisse `FStatus.Caption := Text`, qui doit etre `FStatus.Caption := TextA` (sinon erreur Pascal).

## Correctifs

- On conserve **exactement le code utilisateur v9**, en corrigeant `SetStatus` et en gardant `Visible1`.
- On remplace l'overload historique `WebSocketsConnect(aHost,aPort,...)`, qui transforme ses echec en simple `nil`, par l'overload **aUri: TUri + aOptions: THttpRequestExtendedOptions + aErrorMessage: PRawUtf8** existant dans les sources mORMot2 fournies. Le client affichera notamment `HTTP/1.1 404`, `429`, les echecs TLS ou `No server response`, sans exposer le token dans les logs.
- La methode d'upgrade mORMot2 retire le slash avant la recherche du protocole sur le serveur ; la route **interne** est `kvm`, l'URL **publique** reste `/kvm`.
- `mormot.net.client` importe le type `THttpRequestExtendedOptions`; le proxy est desactive comme dans l'ancien overload.

## Diagnostic local

**En premier :** demarrer `MeshKVMServer` et verifier qu'il affiche l'ecoute, sans exception TurboJPEG et sans crash. Dans un second terminal :

```sh
ss -ltnp | grep ':7900'
```

Si aucune ligne n'apparait, la connexion du client est impossible : le probleme est au **demarrage serveur**.

Puis :

```sh
curl -i --http1.1 --max-time 5 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Protocol: meshkvm7' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  http://127.0.0.1:7900/kvm
```

La reponse attendue est **HTTP/1.1 101 Switching Protocols**. `curl` peut ensuite afficher un timeout de lecture puisque cela ouvre un canal WebSocket sans jouer le protocole de l'application, ce qui n'est pas un echec de la negociation.

- `Connection refused` : serveur absent ou mauvaise interface / port.
- `HTTP/1.1 404` / `400` : route ou protocole incorrect, mauvaise compilation ou vieux binaire.
- `HTTP/1.1 429` : refus de l'upgrade (quota/limite serveur ou autre condition).
- `HTTP/1.1 101` : upgrade reussi ; chercher ensuite l'authentification ou le traitement des frames.

La compilation **doit** etre faite sur la machine Lazarus de l'utilisateur. Le contenu de ce ZIP a subi des controles statiques uniquement : ni fpc ni lazbuild ne sont disponibles dans notre environnement, et APT n'a pas pu joindre ses depots.
