# MeshKVM v9 - passe de fluidite (sans nouveau protocole)

Base : `MeshKVM_v9_diagnostic_deconnexions.zip` (incluant JPEG 4:4:4,
interface escamotable et journalisation des fermetures). Cible de cette passe :
reduire les copies/conversions de pixels et le nombre d'aller-retour video,
sans supprimer les ACK ni augmenter la taille maximale de la file reseau.

## Correctifs dans les sources

- `server/kvm_capture_x11.pas` : lorsque l'image X11 est au format 32 bits
  little-endian habituel et que la capture est a sa resolution native, copie
  BGRA vers RGB par parcours lineaire des lignes : plus de division par pixel.
  Le chemin generique (formats differents et reductions de resolution) reste
  inchange. Le curseur XFixes est compose ensuite comme precedemment.
- `shared/kvm_flow.pas` : jusqu'a **20 rectangles** par lot contre 8. En y
  ajoutant D, S, C et B, cela tient dans 24 messages, taille deja traitee par
  un tick du client Lazarus. Le plafond de 3 Mio pour le lot et le plafond
  de 4 Mio / 64 trames de la file WebSocket serveur sont conserves.
- `shared/kvm_adaptive.pas` : budget de premier lot porte a 1 Mio. La
  borne basse vaut 512 Kio, la borne haute reste 2 Mio ; les acquittements
  continuent a prevenir les clients lents. L'adaptation de profil est
  independante de ces budgets ; `--no-adaptive` ne supprime pas les ACK.
- `client/kvm_view_form.pas` : `TJPEGImage` et `TMemoryStream` reutilises
  au lieu de deux creations/destructions par rectangle. Aucune instruction de
  dessin n'est lancee depuis le thread reseau. Chaque lot reste acquitte
  apres decode sur le thread GUI. Le titre et le panneau escamotable restent.
- Client terminal : mesure toutes les 5 secondes `ACK/s`, `JPEG/s` et
  `decodage total ms`. **ACK/s et JPEG/s ne sont pas des FPS affiches.**
  Une mise a jour peut inclure plusieurs rectangles, ou aucun si le bureau
  est immobile. Le log aide a localiser le cout du decodeur.
- `tools/summarize_metrics.py` : expose aussi les tentatives de capture/s,
  les lots mis en file/s et les ACK/s dans le JSON.

## Commande de test Linux (une machine, un client)

```sh
export MESH_KVM_TOKEN='secret-de-test-minimum-16-caracteres'
./MeshKVMServer --listen 127.0.0.1 --port 7900 --control \
  --fps 20 --quality 80 --max-width 1920 --max-height 1080 \
  --no-adaptive --encoder turbojpeg \
  --metrics-csv /tmp/meshkvm_fps_test.csv
```

Utiliser un *nouveau nom* de CSV a chaque lancement. Faire bouger une fenetre
pendant 15 secondes, puis Ctrl+C. Resumer :

```sh
python3 tools/summarize_metrics.py /tmp/meshkvm_fps_test.csv
```

La synthese est cumulative depuis le demarrage du serveur ; si l'attente
avant la connexion a dure plusieurs secondes, refaire une mesure plus longue.
En parallele, consulter la ligne `[client-video]` dans le terminal client.

### Lire les mesures

- `mean_capture_call_ms` eleve : extraction X11/SHM ou conversion des pixels.
- `mean_profile_pipeline_ms` eleve : comparaison, redimensionnement, TurboJPEG.
- `mean_ack_ms` eleve, avec serveur rapide : decodage LCL, charge du client,
  ordonnanceur ou reseau (ACK ne mesure pas l'affichage physique).
- `queue_rejects` qui augmente : pression sur la file de sortie WebSocket.
- Peu de `capture_calls_per_second` lorsque le bureau **bouge** : le client
  attend probablement des ACK ou le profil limite la cadence.

## Validation

Les scripts Python (`tests/check_project.py`, `tests/test_metrics_tool.py`)
passent. Les tests Pascal `tests/test_flow.lpr` et `tests/test_latency.lpr`
ont ete mis a jour, mais **pas executes** en l'absence de FPC/Lazarus.
Aucune acceleration chiffrable ni performance promise sans mesure sur le
poste cible. Sur une machine limitee par le decodeur JPEG GTK2, davantage de
rectangles par lot peut augmenter les a-coups : les metriques permettent
alors de mesurer cet effet.
