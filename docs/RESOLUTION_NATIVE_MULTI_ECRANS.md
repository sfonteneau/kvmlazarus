# Bureau multi-ecrans : resolution native par defaut

## Changement

- `--monitor 0` cible le bureau virtuel complet (tous les ecrans) sous Windows GDI ; `--monitor 1` cible seulement le premier ecran.
- Le profil standard n'applique PLUS `1920x1080`. Il conserve les dimensions de capture d'origine par defaut.
- Le mode adaptatif est **desactive par defaut** pour eviter une reduction de qualite/resolution en cas d'ACK lent. `--adaptive` permet de le reactiver explicitement ; `--no-adaptive` reste accepte.
- `--max-width` et `--max-height` restent disponibles pour demander volontairement une reduction ; `--native-resolution` restaure les valeurs natives si la commande contient des limites explicites plus tot.
- Les valeurs maximales de la CLI sont des limites de mise a l'echelle, **pas** une taille d'image a allouer ! Le maximum produit `32768*32768` n'est donc plus rejete a la lecture de la CLI ; seules les vraies dimensions de capture sont controlees.

## Garde-fous necessaires

Une vraie absence de limite memoire permettrait a un pair de forcer des allocations arbitraires. Le protocole conserve des dimensions u16 et les allocations sont desormais refusees au-dela de **32768 px par cote** ou **67 108 864 pixels par image**. Le profil natif ne reduit PAS silencieusement une image depassant ces seuils : la capture est refusee. Une reduction volontaire `--max-width` / `--max-height` est possible.

Exemples compatibles avec ces garde-fous :

- 2 x 3840x2160 cote a cote : **7680x2160** (pas de reduction)
- 4 x 3840x2160 cote a cote : **15360x2160** (pas de reduction)
- 8 x 3840x2160 cote a cote : **30720x2160** (pas de reduction, RAM/CPU importants)

Pour Windows, apres recompilation du serveur **et du client** :

```bat
MeshKVMServer.exe --listen 0.0.0.0 --port 7900 --control --allow-insecure --backend gdi --monitor 0 --fps 20 --quality 90
```

La capture native n'empeche pas l'interface cliente de reduire l'image pour l'ajuster a la fenetre. Cette mise a l'echelle de presentation ne change pas la resolution des pixels transmis. Des bureaux tres larges peuvent exiger une version **x64**, les tampons JPEG/RGB/BGRX et les references de changement consommant beaucoup de memoire, notamment en x86.

Les ponts FFmpeg/Wayland/macOS utilisent leurs propres API et peuvent encore etre limites par les pilotes et l'environnement graphique. Le nouveau code Wayland alloue progressivement son tampon selon les vraies dimensions du flux (code de retour -2 du pont natif) et non selon la taille plafond.

**Compatibilite** : les nouveaux programmes utilisent toujours le sous-protocole `meshkvm8`. Il est recommande de reconstruire les deux executables pour accepter les nouvelles dimensions et les regles de securite identiques.

**Validation** : tests structurels et C executes ici ; compilation Pascal/Lazarus sur Windows non disponible dans cet environnement.
