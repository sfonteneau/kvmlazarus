# Mesures et encodage materiel v9

Aucun resultat CPU/debit/FPS du produit complet n'a ete obtenu dans cet
environnement. Les commandes ci-dessous sont des outils executables a utiliser
apres compilation, pas des chiffres presentes comme deja mesures.

## Chemins a comparer

1. `--encoder turbojpeg` : rectangles modifies, bon point de reference.
2. `--encoder h264_nvenc`, `h264_qsv`, `h264_amf`, `h264_vaapi` ou
   `h264_videotoolbox` : selection explicite, meme resolution/FPS et meme bureau.
3. `--encoder auto` : inspection des logs obligatoire, car auto peut revenir a
   JPEG. Ne pas appeler ce test un benchmark GPU sans verifier le codec effectif.

Le H.264 de cette version est tout-intra/IDR avec SPS/PPS par image. Il n'a pas
la compression temporelle des flux P/B. Un changement de quelques pixels peut
necessiter une image H.264 complete tandis que JPEG ne transmet que des rectangles.
Le moteur n'encode pas les images strictement identiques. Le bitrate est une
consigne a l'encodeur, pas une borne du trafic instantane. Les plafonds de payloads
et la contre-pression restent actifs independamment du codec.

Conversion RGB24 vers NV12 et readback capture restent sur CPU ; VAAPI/QSV ont
un upload materiel supplementaire. Depuis P1/P2/P3, le client decode sur un worker CPU dans une surface BGRX32,
puis presente un DIB Windows ou importe une surface complete dans LCL. Pas de pipeline
capture-texture -> encodeur zero-copy, ni d'indicateur de latence photon a photon.
Un profil utilise un handle natif par encodeur, un client n'a pas son propre
encodeur dedie. Plusieurs profils/GPU sessions peuvent consommer de la memoire
ou atteindre des limites de pilote : a mesurer avec plusieurs spectateurs.

## Banc codec reel

Compiler d'abord `native/codec/build.sh` ou `build_msvc.cmd`, puis :

```sh
python3 tools/bench_codec.py \
  --library server/libmeshkvm_codec.so --encoder h264_vaapi \
  --device /dev/dri/renderD128 --width 1920 --height 1080 \
  --fps 15 --kbps 8000 --frames 120 --output codec-vaapi.json
```

Adapter le chemin de bibliotheque et l'encodeur a la cible. Le script charge
le vrai pont C avec ctypes : aucune substitution par une commande FFmpeg.
Source RGB synthetique, trois iterations de chauffe puis N encode/decode.
Rapport p50/p95 des temps encode/decode, CPU de ces appels, taille moyenne AU,
estimation de debit a la cadence demandee, ecart RGB echantillonne. L'ecart est
un smoke test, pas SSIM/VMAF ou une verification visuelle de la qualite du texte.
Les percentiles sont des statistiques d'echantillons du run, pas un intervalle
de confiance. Les FPS annonces restent une consigne, pas une mesure du bureau.

Pont/encodeur indisponible ou decode echoue : JSON avec `unavailable_or_failed`,
code de sortie 2, pas des valeurs de performance fictives. Dans cette livraison,
`docs/validation-v9/codec-unavailable.json` montre precisement cette situation.
Le cas 1920x1080 est important : le buffer interne peut etre 1920x1088, tandis que
le resultat visible doit etre 1920x1080. Tester aussi 640x360, 2560x1440 et 4K
selon les limites du materiel.

`KVM_CODEC_TEST_SOFTWARE=1` active uniquement pour un build de test l'encodeur
libx264, a appeler avec `--test-software --encoder libx264`. Cela peut aider a
verifier le codec sans GPU mais **n'est pas un resultat d'encodage materiel**.
Cette option ne doit pas etre confondue avec le repli de production : celui-ci
est TurboJPEG. Les composants et conditions de distribution du build FFmpeg
utilise doivent etre verifies dans ton travail de packaging.

## Compteurs du serveur

Demarrer avec `--metrics-csv run-serveur.csv` ; le fichier ne doit pas exister.
Il contient des compteurs cumulatifs, ecrits environ chaque seconde et a l'arret :

| Colonne | Signification |
| --- | --- |
| elapsed_ms | Temps monotone depuis creation des mesures |
| capture_calls, captures, capture_ms | Tentatives, reussites de l'API capture, temps total de toutes les tentatives |
| pipeline_calls, pipeline_ms | Appels et temps de `TKvmVideo.Update`, incluant redimensionnement, comparaison/cache ET encodage lorsqu'il y a un changement |
| queued_batches, queued_bytes | Lots acceptes et octets applicatifs mis en file, D/S/T/V/C/B compris ; pas les en-tetes WebSocket/TLS/TCP ni la preuve d'un envoi reseau |
| queue_rejects | Reservations refusees localement |
| acks, ack_total_ms | Acquittements video valides et somme des durees lot->ACK |
| security_rejects | Rejets des controles d'entree/auth/quotas instrumentes |

Une capture compte comme reussie avant une eventuelle revalidation de session ;
elle peut donc ne pas etre diffusee. Le temps du pipeline n'est pas le temps
pur du compresseur. Depuis P1/P2/P3, l'ACK intervient apres composition dans le framebuffer CPU
du worker, avant la peinture LCL ; il ne mesure pas le rafraichissement physique.

```sh
python3 tools/summarize_metrics.py run-serveur.csv --output resume-serveur.json
```

Le resume calcule les moyennes avec leurs vrais denominateurs et refuse des
compteurs qui reculent. Une erreur d'ecriture du CSV est signalee puis les
mesures sont desactivees ; l'application ne doit pas perdre sa capture pour
un disque de mesures plein. Conserver le log et verifier que le CSV contient
bien toute la duree, plutot que supposer le run complet.

## Debit transport et client lent

Utiliser un bureau de test qui bouge, definir le token dans l'environnement :

```sh
python3 tools/bench_network.py --host 127.0.0.1 --port 7900 \
  --capability h264 --seconds 30 --output reseau-normal.json
python3 tools/bench_network.py --host 127.0.0.1 --port 7900 \
  --capability h264 --seconds 30 --ack-delay-ms 750 --output reseau-lent.json
```

Ajouter `--tls --ca autorite.pem` pour le vrai serveur TLS ; hors loopback sans
TLS, la derogation `--allow-insecure` doit etre explicite. Le benchmark ne tape
ni ne clique et ne demande pas le controle. Il transmet une capacite de reception,
pas une preuve de decodage H.264. Le rapport compte les paquets JPEG/H.264 recus,
le debit de payload et les intervalles entre fins de lots. Il ACKe apres reception,
**pas apres decode ni affichage**. Ne pas presenter ces durees comme la latence GUI.
Le delai d'ACK simule un consommateur lent, pas une veritable perte de paquets TCP.

Tester deux spectateurs simultanes, dont un lent, puis reconnexion, changement
de profil, suspension et resolution. Verifier que le client rapide n'est pas
bloque, que les versions du cache sont coherentes et que la memoire ne croit pas
sans borne. Les 4 Mio du transport ne sont pas une limite du RSS total.

## CPU et RAM des vrais processus

`psutil` est une dependance des outils de mesure seulement, pas du moteur.

```sh
python3 tools/bench_process.py --pid 12345 --seconds 60 \
  --interval 0.5 --output processus-serveur.csv
```

Remplacer par le PID reel du serveur, puis refaire pour le client. Le script ne
lance pas de service, n'installe rien et n'enregistre pas les arguments du processus.
CPU est exprime par rapport a un coeur et peut depasser 100 % ; RSS est la memoire
residentielle observee du processus, pas toute la memoire GPU ni la VRAM pilote.
Un vrai benchmark GPU doit completer avec les outils de la carte/OS choisis.

## Matrice minimale de qualification

Conserver pour chaque run : OS/build, architecture, GPU/pilote, build FFmpeg,
widgetset LCL, backend de capture, codec effectif, resolution, FPS/bitrate/qualite,
profils actifs, nombre de clients, type de lien, duree et repetitions.

Comparer bureau statique, texte defilant, deplacement de fenetre et animation.
Effectuer plusieurs runs comparables, avec et sans TLS. Pour l'affichage reel,
une mesure instrumentee source/GUI synchronisee ou une capture haute vitesse
reste necessaire ; les outils livres ne sont pas un substitut a cette mesure.
Ne pas injecter des interactions automatiques sur un bureau de travail reel.

## References API

- [FFmpeg encoders](https://ffmpeg.org/ffmpeg-codecs.html).
- [FFmpeg send/receive](https://ffmpeg.org/doxygen/7.1/group__lavc__encdec.html).
- [AVCodecContext / get_buffer2](https://www.ffmpeg.org/doxygen/8.0/structAVCodecContext.html).
- [Dimensions internes de decode.c](https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/decode.c).

Les references documentent les API, pas la performance de notre integration.
