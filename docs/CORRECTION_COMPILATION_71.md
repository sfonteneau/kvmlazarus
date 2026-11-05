# Correction kvm_transport.pas - erreur Illegal qualifier ligne 71

## Cause probable

La methode `Q.Safe.TryLock` est exposee par `TOSLock`, defini dans
`mormot.core.os`. Le fichier `server/kvm_transport.pas` importait
`mormot.net.ws.core` mais pas directement `mormot.core.os`.

## Correction

Ajout de `mormot.core.os` a la clause `uses` de `kvm_transport.pas`.
Aucune modification du protocole ni du verrouillage.

## Validation

Verification statique : `TWebSocketFrameList` herite de `TObjectOSLock`,
sa propriete `Safe` est un `TOSLock`, et `TOSLock.TryLock` / `UnLock`
sont publics dans la version de mORMot2 fournie.

Non compile dans cet environnement (FPC/Lazarus absents).
La correction cible precisement l'erreur signalee : ne pas la confondre
avec une validation du projet complet.

## Verification sur la machine cible

Relancer Build dans Lazarus avec la version de mORMot2 de l'archive.
Si le compilateur indique une autre erreur, noter fichier, ligne et message.
