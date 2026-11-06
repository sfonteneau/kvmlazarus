# Application du correctif P1/P2/P3

Base : votre kvmlazarus-main.zip. Ce ZIP contient uniquement les fichiers
modifies/ajoutes. Extraire son CONTENU dans C:\tranquilit\kvmlazarus, en
conservant client/, server/, shared/, native/, tests/ et docs/.

Recompiler les deux programmes avec la commande autonome habituelle. Ne pas
copier un ancien projet Standalone genere sur les .lpi livres : le script
regenere les projets et recompile les unites. Ne pas reutiliser de vieux .ppu.

Aucun changement aux scripts build_standalone_windows.cmd / build_standalone.py,
aucune modification des sources externes mORMot2. Protocole meshkvm7 inchange.

Voir docs/P1_P2_P3.md pour les choix techniques, commandes et compteurs.
Voir docs/VALIDATION_P123.md pour les tests executes et les limites.
Le code Pascal/Windows complet n'a PAS ete compile dans l'environnement de livraison.

Les .lps d'IDE, la .so Linux precompilee et client-imports.txt de la copie de
travail ne sont pas redistribues dans l'archive COMPLETE. Le petit correctif ne
supprime pas ces fichiers chez vous ; ils ne sont pas utilises en Standalone.

Fichiers modifies/ajoutes :
- README.md
- client/MeshKVMClient.lpi
- client/kvm_present_win.pas
- client/kvm_turbojpeg_decode.pas
- client/kvm_video_worker.pas
- client/kvm_view_form.pas
- docs/P1_P2_P3.md
- docs/PERFORMANCE_V9.md
- docs/PROTOCOLE.md
- docs/VALIDATION_P123.md
- docs/validation-p123/build-tools.log
- docs/validation-p123/close-diagnostic-static.log
- docs/validation-p123/environment.txt
- docs/validation-p123/jpeg444.log
- docs/validation-p123/metrics-tools.log
- docs/validation-p123/native-pixels.log
- docs/validation-p123/network-tools.log
- docs/validation-p123/pascal-not-run.log
- docs/validation-p123/pipeline-static.log
- docs/validation-p123/structure.log
- docs/validation-p123/windows-archive-tools.log
- docs/validation-p123/windows-build-tools.log
- native/common/kvm_pixels.h
- server/MeshKVMServer.lpi
- server/kvm_capture_win.pas
- server/kvm_server.pas
- server/kvm_turbojpeg.pas
- server/kvm_video.pas
- shared/kvm_codec.pas
- shared/kvm_damage.pas
- shared/kvm_frame.pas
- shared/kvm_rgb_bitmap.pas
- shared/kvm_schedule.pas
- shared/kvm_surface.pas
- tests/bench_p123_capture_win.lpr
- tests/check_project.py
- tests/run_p123_tests.py
- tests/test_close_reason_diagnostic.py
- tests/test_flow.lpr
- tests/test_fps_structure.py
- tests/test_p123_core.lpr
- tests/test_p123_win_present.lpr
- tests/test_p123_worker.lpr
- tests/test_pipeline_static.py
- tests/test_pixels.c
