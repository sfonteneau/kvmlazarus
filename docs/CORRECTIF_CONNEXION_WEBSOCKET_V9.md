# Correctif connexion WebSocket et client Lazarus (v9)

## Problème confirmé par lecture des sources

Dans `mormot.net.ws.core.pas`, `TWebSocketProtocolList.ServerUpgrade` appelle
`TrimU(Http.CommandUri, uri)` puis retire le premier `/` avant la recherche du protocole.
Par conséquent, pour une requête HTTP `GET /kvm`, le nom d'URI interne est `kvm`.
La v9 enregistrait le protocole sous `/kvm`, puis rejetait de nouveau dans
`TKvmServer.AllowUpgrade` les URL dont `UpgradeUri <> '/kvm'`.
La négociation WebSocket pouvait échouer avant l'authentification.

## Corrections

- `shared/kvm_wire.pas` : deux constantes distinctes, `KVM_WS_PATH='/kvm'`
  pour l'URL client et `KVM_WS_ROUTE='kvm'` pour le routage mORMot2.
- `server/kvm_server.pas` : protocole enregistré avec `KVM_WS_ROUTE` et
  vérification de `Protocol.UpgradeUri` sur la même chaîne.
- `client/kvm_view_form.pas` : retour au *vrai* code client v9 (accusés de
  saisie, statut de session, capacité JPEG/H.264, contrôles TLS) avec la
  modification Lazarus qui a permis la compilation chez l'utilisateur :
  `SetCaptureControl`/`GetCaptureControl` au lieu de `MouseCapture`.
- `tests/test_websocket_route.py` : contrôle de régression lexical.

**Important** : le fichier client modifié collé par l'utilisateur revenait au
protocole v8. Il envoyait `AUTH <token>` alors que le serveur v9 attend
`AUTH <token> jpeg` ou `AUTH <token> h264`. Il ne connaissait pas non plus
les nouveaux paquets D/I/V. Ne pas remplacer le client v9 par ce fichier.

## Vérification sur la machine Linux

1. Recompiler **le serveur et le client** ; les changements de `shared/kvm_wire.pas`
   nécessitent les deux compilations.
2. Installer et rendre accessibles les bibliothèques natives nécessaires
   (dont TurboJPEG) ; l'absence de TurboJPEG empêchait auparavant le serveur
   de démarrer. Contrôler la présence d'une écoute :

   ```sh
   ss -ltnp | grep ':7900'
   ```

3. Examiner la réponse HTTP de la négociation, sans envoyer de token :

   ```sh
   curl -i --http1.1 --max-time 5 \
     -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
     -H 'Sec-WebSocket-Version: 13' \
     -H 'Sec-WebSocket-Protocol: meshkvm7' \
     -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
     http://127.0.0.1:7900/kvm
   ```

   Attendre `HTTP/1.1 101 Switching Protocols` si le serveur accepte l'upgrade.
   `429` peut signifier une limitation d'accès. `400` / `404` indiquent une
   négociation ou une route incorrecte. `Connection refused` indique
   généralement que le serveur n'écoute pas sur ce port.
4. Utiliser le client v9 corrigé avec le **même token**.

Le token de connexion n'apparaît pas dans la commande curl. Ne pas exposer
un service WS non chiffré sur un réseau non maîtrisé.

## Validation de cette livraison

Ce correctif est basé sur les sources exactes de mORMot2 et sur les fichiers
Pascal de l'archive v9. Les vérifications structurelles passent mais **ni le
serveur ni le client corrigés n'ont été compilés/exécutés ici** (Lazarus/FPC
indisponibles). Les commandes ci-dessus permettront de confirmer la connexion
sur ta machine cible.
