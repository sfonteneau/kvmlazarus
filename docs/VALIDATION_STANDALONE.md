# Validation du mode autonome - 2026-11-06

## Etat de livraison

Sources modifiees et scripts de construction. **Aucun executable MeshKVMServer
ou MeshKVMClient complet n'a ete compile dans cette passe.** Aucun resultat de
performance ou test de controle distant n'est annonce.

Base exacte: `MeshKVM_v9_client_journal_GUI_sans_console.zip`.
Les fichiers de protocole, video/capture X11, interface client et journal GUI
ont ete conserves, a l'exception des branches de chargement/liaison explicitement
listees dans AUTONOME.md. Une ancienne `.so` privee precompilee presente dans
l'archive de base a ete retiree de cette distribution de sources.

## Tests reellement executes

| Test | Resultat et portee |
| --- | --- |
| Garde Linux compile en `.o`, archive `.a`, lie dans un executable C | Reussi, vrai code du projet; pas un modele de liaison |
| Open/poll/close avec le runtime systeme present | Reussi; etat 0/inconnu dans le conteneur, pas une session de bureau qualifiee |
| Etats logind simules | Reussi: actif/verrouille/inactif/identite modifiee/erreurs/reprise et 1000 cycles de vie |
| Bibliotheque systeme presente mais symbole manquant | Reussi: message nommant `sd_pid_get_session`, sans crash |
| AddressSanitizer et UndefinedBehaviorSanitizer | Aucun diagnostic sur les tests C du garde ci-dessus |
| Tests Python du builder et de l'auditeur | 11 tests reussis; regles de flags, generation LPI, verification d'archives, imports refuses, branches de code |
| Regressions Python des sources client | Journal GUI, interface F8, route WebSocket et invariants de copie: reussis; controles de source/modeles, pas de session GUI |
| Controle structurel general | 486 assertions lexicales/structurelles et syntaxe shell; PAS une analyse semantique Pascal |

Le test Python des branches traite seulement les directives conditionnelles
utilisees par les wrappers. Il ne remplace pas Free Pascal. Les tests de logind
simulent un service systeme; ils ne prouvent pas le verrouillage reel d'un bureau.

## Non compile / non execute ici

- Serveur/client complets: `fpc` et `lazbuild` absents.
- Encodage/decompression avec l'archive statique TurboJPEG: archive `.a` absente.
- Test Pascal `test_standalone_link.lpr`: ecrit et branche au build, non execute.
- Test natif `test_static_turbojpeg.c`: ecrit et branche au build, non execute ici.
- Backends statiques Wayland, DXGI et ScreenCaptureKit: developpements/OS cibles
  indisponibles. Pas de claim de compilation Windows/macOS.
- Integration optionnelle FFmpeg: pas de compilation des bibliotheques natives.
- Connexion KVM, TLS, GUI, permission et performance: pas de nouvelle qualification.

Une tentative du script complet retourne volontairement le code 2 avec
`Outil absent: fpc`, avant de generer une sortie faussement valide. L'acces aux
depots de paquets depuis le conteneur n'a pas permis de recuperer le compilateur.
Aucun journal de test non execute n'est presente comme un succes.

## Journaux

Dans `docs/validation-standalone/`:

- `native-static-guard.log`: compilation statique C, etats/reprises/erreurs sous sanitizers.
- `python-tests.log`: suite du builder et de l'auditeur.
- `project-structure.log`: controles structurels, absence de compilateur annoncee.
- `regressions-python.log`, `preserved-engine-sources.txt`: controles complementaires et preuve de conservation des sources du moteur.
- `complete-build-attempt.log`: arret propre du build en l'absence de FPC.
- `audit-tool-fixture.txt`: test de l'outil d'inspection sur `/usr/bin/true`,
  clairement une fixture, PAS un audit d'un executable MeshKVM.

Les journaux v7/v8/v9 precedents inclus dans docs sont historiques.

## Verification a faire apres compilation sur la cible

1. Construire avec `sh build/build_standalone.sh` depuis la racine du projet.
   Le script exige de vrais symboles TurboJPEG, execute une sonde C et une sonde
   Pascal, puis construit les projets et inspecte leurs imports directs.
2. Copier seulement l'executable de `dist/<cpu>-<os>/` dans un repertoire vide,
   sans les `.so/.dll/.dylib` ni les sources du projet. Lancer depuis un autre
   repertoire et verifier la capture et le controle dans la session autorisee.
3. Verifier strict/backend explicitement; une garde integree ne corrige pas
   l'absence de session logind sur la VM. Ne pas transformer les etats inconnus
   en permission implicite dans le profil strict.
4. Refaire les tests reseau/TLS existants, la deconnexion et les tests de charge.
   Un import statique ne change pas les limites de ressources ou les droits.
5. Pour les options Wayland/FFmpeg, verifier leurs bibliotheques systeme sur la
   cible. Elles deviennent des dependances de chargement de cette variante.

Conclusion: le code de liaison est livre, le garde natif a une verification
reelle; la promesse d'un executable applicatif autonome reste a confirmer par
la compilation et l'essai sur les machines cibles.
