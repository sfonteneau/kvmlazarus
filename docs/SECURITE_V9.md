# Securite et sessions - perimetre v9

Prototype source, pas audit de securite independant ni certification. La v9 ne
contourne ni l'autorisation locale Wayland, ni Accessibilite/capture macOS, ni
UAC/Winlogon. L'operateur doit etre autorise a partager la session concernee.

## Transport et authentification

Une IPv4 d'ecoute hors 127.0.0.1 exige TLS, sauf `--allow-insecure`. Le client
applique le meme principe et n'assimile pas un nom DNS a une loopback de confiance.
La verification des certificats est toujours active pour TLS. Un fichier CA est
optionnel, selon le fournisseur mORMot2 de la plateforme. OpenSSL est importe
explicitement sous POSIX ; cela corrige une dependance manquante dans la v8,
mais ne vaut pas preuve de fonctionnement TLS. Le backend Windows du framework
peut etre different ; executer le probe sur chaque plateforme.

Tokens principal et vision distincts ; controle des droits au serveur. Aucun
controle sans acquisition exclusive ni bureau disponible. Garder des tokens
aleatoires longs, des fichiers de cle prives proteges et un certificat dont le
nom couvre exactement l'hote de connexion. Les tokens en CLI peuvent etre exposes
par les outils de processus ; les variables d'environnement ne protegent pas
contre un compte local suffisamment privilegie.

La comparaison de token parcourt 256 positions sans sortie anticipee sur les
octets differents. Elle ne doit pas etre vendue comme une primitive constant-time
formellement verifiee. TLS est necessaire pour la confidentialite des tokens,
images et entrees ; ne pas exposer ce prototype directement a Internet.

## Concurrence et ressources

32 WebSockets reserves maximum, 16 authentifies. AUTH en 5 secondes. Budget global
32 upgrades en rafale /4 par seconde. Par session authentifiee : 1000 commandes
puis 500/s, 65536 octets puis 32768/s ; commits texte 512 scalaires puis 128/s.
Les commandes invalides ne rafraichissent pas l'activite. Trois erreurs syntaxiques
ferment la session. Expiration de 15 s sans activite valide et de 20 s sans ACK.

La file de transport visee est limitee a 4 Mio/64 messages, avec reservation d'un
lot entier sans attendre le verrou d'un pair lent. Les controles WebSocket, TCP,
TLS, le parsing initial HTTP et les autres objets du framework ont leurs propres
allocations. Ce n'est pas un plafond de memoire du processus ni un dispositif
anti-DoS complet, et le quota d'upgrade est global, non par IP.

Le client utilise 16 Mio/128 messages dans sa file binaire et 64 Kio/512 entrees
locales. Debordement video : fermeture, non ACK d'images perdues. Trame framework
maximale 4 Mio ; les trames applicatives d'entree sont ensuite restreintes a 1029
octets. Le decodeur FFmpeg a des garde-fous de taille, references, allocation,
mais reste une bibliotheque native non sandboxee, avec ses risques residuels.
Un budget de temps de boucle n'interrompt pas un appel OS/pilote bloque.

## Identite de session et lock screen

Le garde se refere au processus en cours, pas a une session choisie depuis le
reseau. Linux lie l'ID logind/UID et exige une classe utilisateur ; les statuts
Active/LockedHint proviennent du bureau et de logind. LockedHint est declaratif :
un bureau qui ne le renseigne pas empeche une garantie independante du verrouillage.
Le timeout du bus est 150 ms par requete, pas une borne totale de 150 ms pour un
premier poll qui peut faire plusieurs requetes.

Windows verifie WTSActive et le nom du bureau d'entree ; la session 0 et Winlogon
sont refuses. La capture peut encore refuser des fenetres proteges ou des privileges
superieurs. macOS utilise des cles publiques de session console et les etats SCK ;
aucune API privee ni certitude universelle sur tous les lock screens.

Politique strict : UNKNOWN, LOCKED, INACTIVE, CHANGED ou capture indisponible
suspendent. Une identite differente observee reste verrouillee jusqu'au redemarrage.
Backend : UNKNOWN seulement peut etre accepte, avec moins de garanties. Un snapshot
de garde age de plus de 1 s est UNKNOWN. Le reseau et les threads imposent une
fenetre entre la detection, la suspension, le message D et l'effacement client.
Un lot deja envoye ne peut pas etre repris sur le reseau.

Ni service multi-session, ni broker d'ouverture de session, ni ecran de login ne
sont ajoutes. L'integrateur choisit et lance une instance dans le contexte utilisateur
adequat. Un changement de compte n'est jamais une autorisation de continuer a
partager un nouveau bureau avec les anciens spectateurs.

## Clavier, IME et resultat inconnu

U est valide completement avant injection. Le dernier resultat est deduplique
dans la connexion et la file client attend son I avant de poursuivre. En cas de
receipt perdu, le client ferme sans renvoyer le texte. Le serveur peut avoir
injecte tout ou partie avant la coupure : l'operateur doit verifier l'application,
pas cliquer sur un bouton de renvoi suppose sans risque.

Les receipts ne rendent pas atomique une succession d'evenements clavier. Le
compteur est celui des appels completes, pas des caracteres acceptes par l'application.
Les changements de focus, droits, disposition et IME peuvent alterer le resultat.
Le mode remote transmet les virtual keys LCL a l'IME distant ; les touches
consommees localement et certains raccourcis peuvent manquer. Le mode text utilise
l'IME local ; il ne transporte pas la preedition/les candidats d'un IME distant.
X11 refuse les caracteres absents du groupe actif plutot que modifier la keymap.

La deconnexion/perte de controle relache les entrees suivies. Les relachements
ayant echoue sont reessayes dans la session disponible avant un nouveau controleur.
Aucune promesse de liberation en cas de crash, de fermeture X11 ou de refus durable
par l'OS. Les injections transitoires d'un caractere peuvent etre partielles.

## Recette de securite executable

Dans une session graphique de test isolee, apres compilation :

```sh
export MESH_KVM_TOKEN='secret-principal-de-test-long'
export MESH_KVM_VIEW_TOKEN='autre-secret-vision-de-test-long'
# Demarrer volontairement le serveur local avec --control et les deux tokens.
python3 tests/test_security_network.py --host 127.0.0.1
# Test supplementaire de possession du controle, toujours sans taper/clic :
python3 tests/test_security_network.py --host 127.0.0.1 --control-tests
```

Ces tests couvrent pre-auth, token faux, timeout AUTH, droits vision, demande de
controle, receipt refuse/deduplication/conflit, malformed, taille, rafale de
commandes et, en option, exclusion des deux controleurs. Ne pas les diriger sur
un bureau de travail ou un service tiers. Pas de test de frappe automatique ici.

Pour tester le TLS du vrai code mORMot2 :

```sh
lazbuild tests/test_tls_probe.lpi
python3 tests/test_tls_network.py --probe tests/test_tls_probe
# Windows : fournir le chemin vers test_tls_probe.exe
```

Le probe utilise `kvm_tls_policy` comme le client. Le harnais cree des certificats
et cles temporaires puis les supprime ; cas valide, CA erronee, nom errone,
expiration. `--self-test` teste le client Python du harnais, **pas mORMot2**.
Les tests precedents ne remplacent pas une session GUI, le serveur TLS reel ni
une qualification des backends de certificat de tous les OS.

## References techniques de l'implementation

- Sources mORMot2 fournies : `src/net/mormot.net.sock.pas`, `mormot.net.ws.core.pas`,
  `mormot.net.ws.server.pas`, `src/lib/mormot.lib.openssl11.pas`.
- [login1, proprietes de Session](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html).
- [sd_pid_get_session](https://www.freedesktop.org/software/systemd/man/latest/sd_pid_get_session.html).
- [WTS_INFO_CLASS](https://learn.microsoft.com/en-us/windows/win32/api/wtsapi32/ne-wtsapi32-wts_info_class).
- [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).
- [CGSessionCopyCurrentDictionary](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary()).
- [RemoteDesktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html).

Ces references expliquent les interfaces utilisees ; elles ne certifient pas
leur integration dans MeshKVM ni le fonctionnement du produit.
