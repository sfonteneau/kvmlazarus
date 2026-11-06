@echo off
setlocal
set "ROOT=%~dp0"
echo Suppression des anciens outils de correction locale de mORMot2...
if exist "%ROOT%tools\fix_mormot_msi_import.py" del /Q "%ROOT%tools\fix_mormot_msi_import.py"
if exist "%ROOT%tests\test_mormot_msi_import.py" del /Q "%ROOT%tests\test_mormot_msi_import.py"
if exist "%ROOT%docs\CORRECTIF_IMPORT_MORMOT_MSI.md" del /Q "%ROOT%docs\CORRECTIF_IMPORT_MORMOT_MSI.md"
if exist "%ROOT%docs\CORRECTIF_MORMOT_CLI_CHECK.md" del /Q "%ROOT%docs\CORRECTIF_MORMOT_CLI_CHECK.md"
echo Termine. Aucun fichier dans votre installation mORMot2 n'a ete modifie.
endlocal
