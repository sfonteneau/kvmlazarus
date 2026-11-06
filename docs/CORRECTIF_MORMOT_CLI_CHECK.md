# Compatibilite constructeur MeshKVM / correcteur mORMot2

Le patch de `lazbuild --add-package-link` mettait a jour `build/build_standalone.py` sans livrer `tools/fix_mormot_msi_import.py`. Le constructeur appelle maintenant `--check` pour s'assurer qu'il utilise une source mORMot2 corrigee, mais les anciennes versions de ce correcteur n'acceptent que son argument de chemin.

Le present paquet livre les deux fichiers. Il ajoute aussi une verification prealable de l'interface du correcteur : si une version obsolete est encore installee, le constructeur donne une erreur explicite indiquant les deux fichiers a remplacer.

Le mode `--check` **ne modifie pas mORMot2**. Pour corriger le fichier externe avec sauvegarde, lancer le correcteur sans `--check`, ou bien utiliser `--fix-mormot-msi` dans la commande de compilation. `--mormot-dir` designe la racine mORMot2 contenant `packages/lazarus/mormot2.lpk` et `src/lib/mormot.lib.sspi.pas`.

Les tests de regression ciblent le code Python. Ils ne remplacent pas la compilation reelle sur Windows.
