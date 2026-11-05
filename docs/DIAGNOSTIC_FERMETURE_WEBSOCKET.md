# Diagnostic de fermeture WebSocket (v9)

Correctif **de diagnostic**, pas de changement de protocole ni de strategie de reconnexion.

## Avant

Le client affichait le meme message « Connexion fermee par le serveur » pour deux causes distinctes :
- `focConnectionClose` reçu ;
- `ERR PROTOCOL` injecte localement par `IncomingFrame` lors d un paquet inattendu ou d une saturation.

De plus, `ProtocolClosed` du serveur supprimait silencieusement les sessions ; trois NACK video ou des refus de trame pouvaient provoquer un abort sans trace.

## Maintenant

Le client affiche dans sa fenetre et son terminal :
- `LOCAL PROTOCOL: trame ...` si une trame a une longueur incorrecte ;
- `LOCAL PROTOCOL: file reception pleine ...` en cas de saturation ;
- `CLOSED <code>` si la WebSocket a emis une trame de fermeture avec un code ;
- `ERR PROTOCOL` si une erreur est envoyee explicitement par le serveur.

Le serveur journalise les fins de session WebSocket, refus de trame/quota, erreurs AUTH sans exposer le jeton, et NACK video.

## Test

1. Recompiler **serveur ET client** avec les deux unites corrigees.
2. Demarrer le serveur et le client en terminal, avec stdout et stderr visibles.
3. En cas de coupure, envoyer les messages `[client-ws]` et `[ws]` ou `[video]` de ces deux terminaux.
4. Si le client affiche `LOCAL PROTOCOL: ...`, inutile d accuser le serveur : transmettre la longueur et le type de trame mentionnes. Si `CLOSED <code>`, le code oriente vers le transport/protocole mais ne prouve pas a lui seul qui a initie la fermeture.

Pas de compilation FPC/Lazarus dans l environnement ayant produit ce correctif : les changements sont revus statiquement, a verifier avec Lazarus.
