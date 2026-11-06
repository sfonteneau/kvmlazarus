# Correctif : resolution native multi-ecrans

Installer le correctif a la racine de `C:\tranquilit\kvmlazarus`, en conservant
les sous-dossiers et en remplaçant les fichiers correspondants.

Puis reconstruire le serveur ET le client avec la commande autonome existante.

- `--monitor 0` sous Windows GDI = bureau virtuel complet, tous les moniteurs.
- `--monitor 1` = premier moniteur uniquement.
- Ne pas passer `--max-width` ni `--max-height` pour transmettre les
  dimensions natives. `--native-resolution` est un alias explicite facultatif.
- `--adaptive` devient opt-in (il peut degrader la taille), et
  `--no-adaptive` est conserve.
- Limites de securite internes : 32768 pixels par cote et 67 108 864 pixels par image ;
  le serveur refuse les dimensions hors borne, sans changement silencieux d'echelle.

Exemple (conserver votre jeton de controle configure hors de cette commande) :

```bat
MeshKVMServer.exe --listen 0.0.0.0 --port 7900 --control --allow-insecure --backend gdi --monitor 0 --fps 20 --quality 90
```

La resolution originale envoyee n'est pas la taille d'affichage de la fenetre
cliente, qui peut rester ajustee a sa taille. Pour les bureaux ultra-larges,
recommander le build x64 et assez de RAM.

Pas de modifications de mORMot2 ni de nouvelles DLL natives. Le protocole reste
`meshkvm8`, mais le client ancien peut rejeter les nouvelles grandes dimensions.

Voir `docs/RESOLUTION_NATIVE_MULTI_ECRANS.md` pour les details.
