# MeshKVM v9 — qualité maximale et FPS libres

**Sources** : correctif à appliquer après P1/P2/P3 et le nettoyage du correctif local mORMot2.
Le protocole `meshkvm7`, les trames, les ACK/NACK et les limites de mémoire
restent identiques. Aucune DLL supplémentaire n’est nécessaire.

## Modifications

- `--quality` accepte **1 à 100**. TurboJPEG garde son sous-échantillonnage **4:4:4**.
  Une qualité JPEG de 100 n’est **pas** une compression sans perte : pour une
  fidélité pixel à pixel il faudrait un autre codec, par exemple PNG.
- `--fps 0` active la **cadence libre** : pas de délai de capture artificiel.
  Après une capture, le thread cède son temps CPU avec `Sleep(0)` sans
  attendre artificiellement 1 à 15 ms sous Windows. Les ACK, la capture, le
  codage, le CPU, le client et le réseau restent des limites réelles. Les tuiles inchangées ne sont pas retransmises.
- `--fps 1..1000` permet une fréquence de capture cible ; la minuterie du
  planificateur utilise des millisecondes. Au-delà de 1000, le réglage n’a pas
  de sens avec ce planificateur.
- `--no-adaptive` conserve **la qualité/résolution choisies** ; c'est maintenant
  le comportement par defaut. `--adaptive` reactive explicitement les profils
  adaptatifs qui diminuent la qualité et la résolution si les ACK ralentissent.
- La capture est désormais **native par défaut**, sans plafond de redimensionnement
  1920×1080. Les garde-fous mémoire internes sont de 32768 pixels par côté et
  **67 108 864 pixels par image**. `--max-width`/`--max-height` ne servent qu'à
  demander volontairement une réduction.

## Commande Windows GDI — qualité et cadence libres

```bat
set "MESH_KVM_TOKEN=REMPLACER_PAR_UN_SECRET_FORT_DE_32_CARACTERES"
"C:\Users\Administrator\Desktop\MeshKVMServer.exe" ^
  --listen 127.0.0.1 --port 7900 ^
  --control --backend gdi --monitor 1 ^
  --fps 0 --quality 100 --no-adaptive ^
  --max-width 3840 --max-height 2160
```

Si le client est sur une autre machine, configurer un tunnel chiffré (VPN/SSH),
ou fournir un certificat TLS avec `--tls-cert` / `--tls-key` avant de lier
`--listen 0.0.0.0`. `--allow-insecure` transmet également le jeton de session en
clair : à éviter sur des réseaux non protégés. Le jeton montré dans un ancien
journal de commande doit être remplacé.

## Conseils pratiques

Une qualité de **95–98** procure souvent un rapport netteté/latence plus efficace
que 100. Pour diagnostiquer un ralentissement, essayer `--quality 95 --fps 60`
puis `--fps 0`, en comparant les métriques sur les mêmes écrans. La cadence
libre peut saturer un cœur CPU sur un bureau en mouvement et **augmenter** la
latence, même sur un LAN.

## Portée des backends

- **Windows GDI / DXGI** : cadence JPEG libre, limitée par les performances et
  le protocole ACK, pas par `--fps 30` dans le code de MeshKVM.
- **Linux X11** : même principe (capture en boucle). **Wayland/portal** : le pont
  natif actuel accepte au plus 30 FPS. Il reçoit donc une valeur valide de 30.
- **macOS ScreenCaptureKit** : le pont natif actuel accepte au plus 30 FPS.
- **H.264 (optionnel)** : le pont FFmpeg accepte une fréquence nominale de 1 à
  60 FPS ; `--fps 0` lui transmet 60 comme fréquence temporelle nominale.
  Cela ne garantit pas 60 FPS réels ni un mode H.264 illimité.

## Compilation Windows x86 (exemple de la configuration utilisateur)

```bat
cd /d C:\tranquilit\kvmlazarus
build_standalone_windows.cmd --arch x86 ^
  --fpc "C:\lazarus_4_8\fpc\bin\i386-win32\fpc.exe" ^
  --lazbuild "C:\lazarus_4_8\lazarus\lazbuild.exe" ^
  --toolchain-bin "C:\msys64\mingw32\bin" ^
  --turbojpeg-archive "C:\msys64\mingw32\lib\libturbojpeg.a" ^
  --mormot-dir "C:\tranquilit\mORMot2"
```

Sous Windows x64, utiliser FPC, GCC et `libturbojpeg.a` tous en x64.
Le code ne modifie **aucun** fichier de mORMot2. La source mORMot2 corrigée
par son projet amont est une dépendance ordinaire.

## Tests ajoutés

- `tests/run_cli_tests.sh` : qualité 100, `--fps 0`, `--fps 144`, bornes invalides
- `tests/test_p123_core.lpr` : chronométrage libre / cadence à 144 et 1000 FPS
- `tests/test_v7_core.lpr` : profils adaptatifs avec base FPS=0
- `tests/test_turbo.lpr` : TurboJPEG 4:4:4 qualité 100 et refus qualité 101

Ces tests Pascal doivent être compilés et exécutés sur un poste équipé de FPC.
Les contrôles Python ne remplacent pas un benchmark Windows réel.
