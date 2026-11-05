# MeshKVM v9 - correctif pipeline RGB / JPEG / X11

Base exacte : `MeshKVM_v9_optimisation_FPS_X11_JPEG444.zip`, la derniere
version dont les connexions et la capture fonctionnaient sur le poste Linux.
Protocole **meshkvm7** conserve ; pas de modification des tokens, WSS,
permissions, fichiers de service ou packaging systeme.

## Diagnostic issu du CSV fourni

Pour `meshkvm_fps_test.csv`, compteurs cumules sur 54.916 s (dont environ
6 s sans client) : 322 captures, **5.86 captures/s sur la duree totale**,
175 lots acquittes, 33.44 ms en moyenne pour capture+conversion,
18.70 ms par traitement d'image, 95.70 ms par ACK. Aucune saturation de
file relevee. Ces chiffres caracterisent **la version precedente** et ne
sont pas des resultats du correctif.

## Modifications

1. `server/kvm_video.pas` : a taille native, l'encodeur utilise le RGB deja
   construit par le backend, sans recopier l'integralite de l'image dans
   un second buffer de profil. La reference locale est liberee avant que
   le thread ne recommence la capture. Si le profil exige une mise a
   l'echelle, le chemin de redimensionnement existant est conserve.
2. `shared/kvm_damage.pas` : copie uniquement les rectangles modifies vers
   la frame precedente. Le premier ecran et les changements de geometrie
   conservent une copie complete. Tous les rectangles sont valides avant
   la modification, avec protection des alias de chaine Pascal.
3. `server/kvm_capture_x11.pas` : suppression d'un XSync redundant avant
   `XShmGetImage` / `XGetSubImage`. Le XSync qui suit la capture et detecte
   les erreurs asynchrones est conserve.
4. `server/kvm_cursor_x11.pas` : l'existence de l'extension XFixes est mise
   en cache par connexion X11 plutot que testee a chaque capture.
5. `client/kvm_turbojpeg_decode.pas` (nouveau) : decodage optionnel des
   rectangles JPEG avec `tjDecompressHeader3` / `tjDecompress2`, dimensions
   verifiees, ecriture BGR24 bottom-up dans un BMP borne a 4 Mio.
6. `client/kvm_view_form.pas` : reutilisation du buffer BMP et du TBitmap
   temporaire. La mise a jour du TBitmap principal reste dans le thread
   principal Lazarus. Si libturbojpeg n'est pas disponible, repli sur le
   decodeur `TJPEGImage` fonctionnant auparavant. Le journal `client-video`
   distingue TurboJPEG et fallback.

Le transport conserve le stop-and-wait par ACK, les NACK, les limites des
files et le JPEG 4:4:4. Aucune compatibilite avec les anciennes versions
n'est ajoutee.

## Test reproductible sous Linux

Installer si necessaire `libturbojpeg0` (serveur obligatoire, client conseille).
Recompiler **serveur et client** depuis la meme archive v9 :

```sh
sh build/build_linux.sh
sh tests/run_pipeline_tests.sh
```

Le test Pascal de decodage utilise `tests/fixtures/turbo_5x3.jpg`. Il exige
la bibliotheque TurboJPEG. Il controle le BMP, les dimensions et les
lignes rouge/bleue. Le test de copie partielle controle les zones disjointes,
les alias et les rectangles hors limites.

Demarrer le serveur (remplacer le token par un secret de test) :

```sh
./server/MeshKVMServer --listen 127.0.0.1 --port 7900 \
  --token 'remplacer-par-un-token-de-test-long' --control \
  --fps 20 --quality 80 --max-width 1920 --max-height 1080 \
  --no-adaptive --encoder turbojpeg \
  --metrics-csv /tmp/meshkvm_pipeline_nouveau.csv
./client/MeshKVMClient --host 127.0.0.1 --port 7900 \
  --token 'remplacer-par-un-token-de-test-long'
```

Lancer le client dans un autre terminal. Animer la meme fenetre pendant
30-60 s et comparer le nouveau fichier a l'ancien :

```sh
python3 tools/summarize_metrics.py /tmp/meshkvm_pipeline_nouveau.csv
```

Le terminal client affiche `TurboJPEG=N LCL=M` sur des intervalles de
5 secondes. Si `TurboJPEG=0`, verifier `libturbojpeg.so.0` et le chargement
de la bibliotheque. Les ACK/s ne correspondent pas necessairement aux FPS
physiquement affiches.

## Validation effective dans cet environnement

- `tests/check_project.py` : 450 verifications structurelles reussies.
- `tests/test_pipeline_static.py` : invariants sources + 1000 scenarios
  independants de reference de regions reussis (**modele Python**, pas Pascal).
- `tests/test_fps_structure.py`, `test_quality_size.py`, tests client overlay
  et diagnostic : reussis (lexicaux).
- `tests/run_native_pixels.sh` : tests **C** executes sous ASan/UBSan :
  20 000 cas valides et 100 000 malformes bornes.
- `tests/test_x11_native_abi.py` : ABI X11/SHM, XTest et XFixes executes sur Xvfb.
- `tests/run_pipeline_tests.sh` : **non execute**, aucun compilateur FPC disponible.
- **Aucun test de compilation de l'ensemble serveur/client** ni mesure des
  nouveaux FPS n'a pu etre realise ici. Aucun gain chiffre n'est garanti.

## Limitations restantes

Le decodage TurboJPEG est execute dans le thread d'interface et le BMP
reste importe via LCL/GTK. Si les captures deviennent rapides mais les ACK
restent lents, mesurer le decodage et envisager un worker de decodage avec
file bornee, sans dessiner depuis le thread reseau. Sous Wayland/macOS,
les changements d'optimisation RGB/rectangles sont generiques, mais le
correctif X11 ne s'applique qu'a Linux X11.
