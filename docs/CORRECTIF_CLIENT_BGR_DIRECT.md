# MeshKVM v9 - traitement client BGR direct (experimental)

Base: `MeshKVM_v9_pipeline_RGB_TurboJPEG_corrige.zip`.

## Pourquoi

Les logs du client montrent 19 a 93 rectangles JPEG par fenetre de ~5 s,
avec 768 a 2500 ms passes dans `ApplyTile`. Le compteur precedent inclut
la decompression native, la conversion BMP/LCL et les appels Canvas.Draw.
Il ne constitue pas une mesure du seul TurboJPEG.

Le chemin precedent faisait: JPEG -> TurboJPEG(BGR) -> fichier BMP construit
en memoire -> TMemoryStream -> TBitmap.LoadFromStream -> Canvas.Draw.
Le nouveau chemin rapide fait: JPEG -> TurboJPEG(BGR24 top-down aligne 4 octets)
-> `TRawImage` -> `TBitmap.LoadFromRawImage(..., False)` -> Canvas.Draw.
Cela retire une serialization BMP complete et son parsing, mais ne retire
pas la copie exigee par LCL ni le cout de Canvas.Draw. Les resultats sont
a mesurer, et la correction ne promet pas 20 FPS.

## Compatibilite / garde-fou

- Pas de changement WebSocket ni de serveur.
- Le nouveau chemin n'utilise que des API documentees de Lazarus (`GraphType`,
  `TRawImageDescription.Init_BPP24_B8G8R8_BIO_TTB`, `LoadFromRawImage`).
- `LoadFromRawImage` copie son buffer, car `ADataOwner=False` : aucune
  reference a `RawByteString` n'est conservee apres l'import.
- Si cette API leve une exception, le client desactive le chemin direct
  pour la session et reessaie l'ancien import BMP. La verite en images
  (orientation/couleurs) reste a confirmer sur les widgetsets reels.
- Definir `MESHKVM_RAW_IMAGE=0` pour utiliser l'ancien chemin BMP.
- Fallback standard `TJPEGImage` conserve si la bibliotheque TurboJPEG
  n'est pas disponible sur le poste client.

## Mesures ajoutees au journal toutes les 5 s

`traitement total ms` : temps entier dans ApplyTile;
`decomp. native ms` : validation de l'entete et tjDecompress2 (chemin direct);
`import LCL ms` : import raw/BMP vers bitmap;
`dessin ms` : Canvas.Draw dans FBitmap;
`JPEG direct` : nombre de rectangles passes par le chemin BGR direct;
`PaintBox ms` : temps dans Draw/StretchDraw de la fenetre;
`PaintBox/s` : nombre de passages par le dessin du bureau (pas FPS reseau).

Ces categories ne mesurent pas la synchronisation GPU, ni le temps
`FView.Canvas.StretchDraw` dans OnPaint. Les nombres peuvent donc ne
pas sommer exactement au total.

## Validation

Contrôles lexicaux, tests Python et intégrité de l'archive possibles ici.
Free Pascal / Lazarus n'est pas disponible : aucune compilation de cette
modification ni test visuel réel sur GTK2/Qt/Windows/macOS n'a pu être exécuté.
Exécuter `tests/run_pipeline_tests.sh` sur la machine avec FPC et TurboJPEG.
Pour un diagnostic précis, comparer le journal du client avant/après et
les métriques du serveur sur la même charge vidéo.
