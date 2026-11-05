# MeshKVM v9 — correction de netteté (TurboJPEG et résolution)

## Problème confirmé dans les sources

Le serveur compressait les rectangles en JPEG **4:2:0** avec `TJFLAG_FASTDCT`.
Les détails de couleur des textes et bordures étaient dégradés même à `--quality 80`.
La limite de taille par défaut est **1920×1080** et l'adaptation automatique peut
réduire à 75 % puis 50 % de cette limite avec une qualité de 55 puis 35.

Sous X11, la réduction de résolution de capture est actuellement par
échantillonnage au pixel le plus proche. Le client utilise `StretchDraw` ; toute
réduction puis ré-agrandissement dégrade le rendu. Une meilleure qualité JPEG
ne peut pas reconstruire les pixels déjà éliminés.

## Correction effectuée

- TurboJPEG encode en **4:4:4** sans `TJFLAG_FASTDCT` : les chrominances
  sont conservées à pleine résolution, et la DCT standard est utilisée.
- Les rectangles fusionnés passent de **1024×512 à 512×512** pour rester
  dans la borne existante de 2 Mio : en 4:4:4, `tjBufSize` peut demander
  jusqu'à `largeur * hauteur * 6 + 2048` octets. Pour 512×512, cela vaut
  **1 574 912 octets**, inférieur à 2 097 152.
- La ligne de démarrage affiche le plafond de résolution, le mode adaptatif
  et la compression 4:4:4. Tests de regroupement mis à jour ; test TurboJPEG
  ajouté pour contrôler les facteurs d'échantillonnage du JPEG réellement produit.

## Essai local conseillé

Choisir des bornes correspondant à l'écran physique. Pour une dalle jusqu'en 4K :

```sh
./MeshKVMServer --listen 127.0.0.1 --port 7900 \
  --token 'REMPLACER-PAR-VOTRE-JETON' --control \
  --encoder turbojpeg --fps 15 --quality 90 \
  --max-width 3840 --max-height 2160 --no-adaptive
```

Comparer la taille réelle affichée dans le client (« Bureau distant : W x H »)
avec `xrandr --current` (sur X11). **Le mode 4:4:4 augmente la taille des JPEG**
et peut diminuer les FPS sur une connexion lente ; ne pas interpréter FPS max
comme cadence mesurée. Sur écran 1920×1080, ne pas forcer 4K artificiellement.

## Validation

- Contrôles structurels et vérifications mathématiques du tampon effectués.
- Les suites Pascal ont été mises à jour **mais non exécutées ici** : pas de FPC,
  de runtime TurboJPEG ou de machine avec session graphique valide.
- La correction de netteté n'optimise ni le rendu `StretchDraw` GTK2, ni
  l'échantillonnage spatial X11, ni la latence du décodeur JPEG client.
- Le protocole reste `meshkvm7` : pas de mécanisme de compatibilité ajouté.
