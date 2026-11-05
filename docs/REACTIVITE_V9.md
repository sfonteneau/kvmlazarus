# MeshKVM v9 - passe de reactivite (meme protocole meshkvm7)

Cette passe part de `MeshKVM_v9_correctif_nettete_JPEG444.zip`.
Elle conserve TurboJPEG 4:4:4, la verification d'authentification, les ACK/NACK
et les quotas de transport. Aucun changement de protocole, aucune compatibilite
avec les versions anciennes.

## Modifications effectives

- Client Lazarus : minuterie de reception `20 -> 10 ms` (meilleure latence de
  traitement des ACK, de l'affichage et des messages de controle).
- Souris : au lieu de **jeter** les mouvements survenant dans les 40 ms,
  on garde la position la plus recente et on l'envoie toutes les ~12 ms au
  plus, y compris si le pointeur s'arrete. Les boutons transmettent leur
  propre position et annulent toute ancienne position en attente.
- File d'entree : fusion de deux mouvements *non encore envoyes* consecutifs.
  Aucun mouvement ne traverse une touche, un clic, un relachement, une molette
  ou un commit de texte. Les garanties de file bornee et d'ordre des events
  significatifs sont conservees.
- Latence WebSocket : LoopDelay passe de 10 a 5 ms pour le serveur et le client.
  C'est une frequence de reveil plus elevee, pas une garantie de RTT de 5 ms.
- Temporisation de capture : boucle `Sleep(5) -> Sleep(3)` pendant l'attente
  de l'intervalle video. Les plafonds FPS restent inchanges.
- Batches : budget initial `1 MiB -> 512 KiB` ; estimation de 125 ms de debit
  observe au lieu de 250 ms, avec bornes 128 KiB / 2 MiB. Les ACK sont toujours
  obligatoires. La premiere vignette plus grosse que le budget peut toujours
  etre envoyee seule, comme auparavant.
- Affichage : `Canvas.Draw` sans interpolation si la taille cible correspond
  exactement a la resolution de l'image ; sinon `StretchDraw` demeure utilise.

## A tester sur une vraie machine

1. Compiler serveur et client dans Lazarus (meme code, protocole `meshkvm7`).
2. Tester une capture X11 locale en `--fps 20 --quality 80 --no-adaptive`.
3. Comparer avant/apres la fluidite du pointeur et des glissers, y compris
   les clics repetes, les touches maintenues et le changement de fenetre.
4. Activer les metriques pour distinguer les couts CPU, capture, encodage,
   refus de file et delais d'ACK : `--metrics-csv /tmp/meshkvm_latency.csv`.
5. Tester un client lent sur le reseau : un budget plus court peut reduire la
   latence mais augmenter le nombre d'aller-retour et reduire le debit total.

## Tests

`sh tests/run_latency_tests.sh` execute des assertions Pascal sur les mouvements
coalesces (avec ordre des clics/touches) et les budgets. Le test n'est pas
execute dans cet environnement, ou `fpc` n'est pas installe.

`python3 tests/check_project.py` realise seulement un controle structurel.
Les gains en millisecondes ne sont pas mesures : ils dependent du RTT, de la
resolution, du codec, de la charge CPU et du widgetset GTK/Qt du client.
