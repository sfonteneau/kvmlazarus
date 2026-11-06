# Correction de compilation FPC / Lazarus sous Windows

Base : MeshKVM v9 - client BGR direct et reactivite (archive fournie).

## Erreurs corrigees

* `server/kvm_inject_win.pas` : la structure `Windows.TInput` de FPC expose le champ `_Type` (pas `Itype`). Correction des quatre acces pour souris, clavier, texte et molette.
* `server/kvm_monitors.pas` : declaration WinAPI explicite de `EnumDisplayMonitors` depuis `user32.dll`, avec callback `stdcall` identique a `EnumOne`.

## Usage

Remplacer les deux fichiers de `server/`, puis reconstruire **MeshKVMServer** (Build, pas seulement Run).
Le client, les codecs, le protocole et les options CLI n'ont pas change.

## Validation reelle

Controle textuel des quatre acces `TInput._Type` et de l'import `EnumDisplayMonitors`.
Comparaison avec les declarations publiques de FPC 3.2.2 (`rtl/win/wininc/struct.inc`) et la documentation Windows.
Integrite de l'archive ZIP verifiee.

**Pas de compilation Windows reussie dans cet environnement : Free Pascal, Lazarus et un poste Windows n'y sont pas disponibles.**
