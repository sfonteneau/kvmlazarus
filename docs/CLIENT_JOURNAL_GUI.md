# Journal du client graphique (Windows / Linux / macOS)

Le client Lazarus peut etre compile en application graphique Windows sans console.
Aucun `WriteLn` n'est utilise dans `client/` : les messages de diagnostic
FPS, TurboJPEG, WebSocket et etat de connexion passent par `kvm_client_log`.

Par defaut le journal est enregistre dans le repertoire **utilisateur**
`GetAppConfigDir(False)` de Free Pascal, sous le nom `meshkvm-client.log`.
Ce chemin depend du systeme, de Lazarus et de la configuration utilisateur.
Le chemin reel est affiche dans l'**infobulle du statut** du panneau F8.

Pour choisir un chemin explicite, definir l'environnement avant de lancer
le programme (le chemin doit etre accessible en ecriture) :

Linux/macOS :

```sh
MESHKVM_CLIENT_LOG=/tmp/meshkvm-client.log ./MeshKVMClient
```

Windows (`cmd.exe`) :

```bat
set "MESHKVM_CLIENT_LOG=%TEMP%\meshkvm-client.log"
MeshKVMClient.exe
```

Windows (PowerShell) :

```powershell
$env:MESHKVM_CLIENT_LOG = Join-Path $env:TEMP 'meshkvm-client.log'
.\MeshKVMClient.exe
```

Les messages apparaitront dans le fichier meme si la fenetre du client
n'est lancee depuis aucun terminal. Le journal est uniquement local, ne
contient pas le token et n'est pas transfere au serveur. Eviter de partager
le journal sans relire son contenu (les adresses et erreurs y figurent).

Le fichier est ferme apres chaque message, ce qui permet sa lecture pendant
que le client reste ouvert. Un verrou RTL protege les ecritures simultanees
au sein d'un meme processus. Si le dossier est inaccessible, le journal
est ignore sans interrompre la connexion.

**Validation** : verification statique des sources ; compiler et tester la
creation du fichier avec Lazarus/FPC sur la machine cible.
