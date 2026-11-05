unit kvm_wayland;
{$mode objfpc}{$H+}
interface
uses kvm_frame;
function OpenWayland(Control: Boolean; FPS: Integer; out Reason: string): Boolean;
function CaptureWayland(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
function WaylandAlive: Boolean;
procedure PauseWayland;
procedure CloseWayland;
procedure WaylandMouse(Action, Button: Byte; X, Y: Word);
procedure WaylandKey(Pressed: Boolean; VKey: Word);
procedure WaylandText(CodePoint: Cardinal);
procedure WaylandWheel(Notches: SmallInt);
implementation
uses SysUtils, Dynlibs, ctypes, kvm_keysym;
var
  Lib: TLibHandle = NilHandle;
  Handle: Pointer = nil;
  Active: Boolean;
  Buffer: RawByteString;
  NativeOpen: function(Control, FPS: CInt; out H: Pointer; Err: PAnsiChar; Cap: CInt): CInt; cdecl;
  NativeClose: procedure(H: Pointer); cdecl;
  NativeRead: function(H: Pointer; Dst: Pointer; Cap: csize_t; MaxW, MaxH: CInt;
    out W, Y: CInt; Err: PAnsiChar; ErrCap: CInt): CInt; cdecl;
  NativeAlive: function(H: Pointer): CInt; cdecl;
  NativeActive: procedure(H: Pointer; Enabled: CInt); cdecl;
  NativeMouse: function(H: Pointer; Action, Button: CInt; X, Y: Word): CInt; cdecl;
  NativeKey: function(H: Pointer; Sym: CUInt; Down: CInt): CInt; cdecl;
  NativeWheel: function(H: Pointer; Steps: CInt): CInt; cdecl;
function OpenWayland(Control: Boolean; FPS: Integer; out Reason: string): Boolean;
var Err: array[0..511] of AnsiChar;
  Abi: function: CInt; cdecl;
begin
  Reason := ''; Result := False;
  if Handle <> nil then Exit(True);
  if Lib = NilHandle then
    Lib := LoadLibrary(ExtractFilePath(ExpandFileName(ParamStr(0))) + 'libmeshkvm_portal.so');
  if Lib = NilHandle then
  begin Reason := 'Compiler native/linux/build.sh et placer libmeshkvm_portal.so a cote du serveur.'; Exit; end;
  Pointer(Abi) := GetProcedureAddress(Lib, 'kvm_portal_abi');
  if not Assigned(Abi) then begin Reason := 'Pont portail sans numero ABI'; Exit; end;
  if Abi() <> 1 then begin Reason := 'Pont portail ABI incompatible'; Exit; end;
  Pointer(NativeOpen) := GetProcedureAddress(Lib, 'kvm_portal_open');
  Pointer(NativeClose) := GetProcedureAddress(Lib, 'kvm_portal_close');
  Pointer(NativeRead) := GetProcedureAddress(Lib, 'kvm_portal_read');
  Pointer(NativeAlive) := GetProcedureAddress(Lib, 'kvm_portal_alive');
  Pointer(NativeActive) := GetProcedureAddress(Lib, 'kvm_portal_active');
  Pointer(NativeMouse) := GetProcedureAddress(Lib, 'kvm_portal_pointer');
  Pointer(NativeKey) := GetProcedureAddress(Lib, 'kvm_portal_key');
  Pointer(NativeWheel) := GetProcedureAddress(Lib, 'kvm_portal_wheel');
  if not Assigned(NativeOpen) or not Assigned(NativeClose) or not Assigned(NativeRead) or
     not Assigned(NativeAlive) or not Assigned(NativeActive) or not Assigned(NativeMouse) or
     not Assigned(NativeKey) or not Assigned(NativeWheel) then
  begin Reason := 'Pont portail incomplet'; Exit; end;
  FillChar(Err, SizeOf(Err), 0);
  WriteLn('[portail] Autoriser localement le partage de l ecran',
    ' et, si demande, le clavier et la souris. Delai maximal : 120 s par dialogue.');
  Result := NativeOpen(Ord(Control), FPS, Handle, @Err[0], SizeOf(Err)) = 0;
  if not Result then Reason := string(PAnsiChar(@Err[0]));
  Active := Result;
  if Result then PauseWayland;
end;
function WaylandAlive: Boolean;
begin Result := (Handle <> nil) and Assigned(NativeAlive); if Result then Result := NativeAlive(Handle) <> 0; end;
procedure PauseWayland;
begin
  if Active and (Handle <> nil) and Assigned(NativeActive) then NativeActive(Handle, 0);
  Active := False;
end;
procedure CloseWayland;
begin
  if (Handle <> nil) and Assigned(NativeClose) then NativeClose(Handle);
  Handle := nil; Active := False; Buffer := '';
end;
function CaptureWayland(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
var W, H, Status: CInt; Err: array[0..511] of AnsiChar; Bytes: Int64;
begin
  Result := False;
  if not WaylandAlive then Exit;
  Bytes := Int64(MaxW) * MaxH * 3;
  if (MaxW < 1) or (MaxH < 1) or (Bytes > 16777216 * 3) then Exit;
  if Length(Buffer) < Bytes then SetLength(Buffer, Bytes);
  if not Active then begin NativeActive(Handle, 1); Active := True; end;
  FillChar(Err, SizeOf(Err), 0);
  Status := NativeRead(Handle, @Buffer[1], Length(Buffer), MaxW, MaxH, W, H, @Err[0], SizeOf(Err));
  // A temporarily paused or revoked portal is never reopened without local consent.
  if Status < 0 then raise Exception.Create('Portail/PipeWire: ' + string(PAnsiChar(@Err[0])));
  if (Status <> 1) or not AllocateFrame(Frame, W, H) then Exit;
  Move(Buffer[1], Frame.RGB[1], Length(Frame.RGB)); Result := True;
end;
procedure WaylandMouse(Action, Button: Byte; X, Y: Word);
begin
  if WaylandAlive and (NativeMouse(Handle, Action, Button, X, Y) = 0) then
    raise Exception.Create('Portail: commande souris refusee.');
end;
procedure WaylandKey(Pressed: Boolean; VKey: Word);
var Sym: Cardinal;
begin
  Sym := KvmKeysym(VKey);
  if (Sym <> 0) and WaylandAlive then
    if NativeKey(Handle, Sym, Ord(Pressed)) = 0 then
      raise Exception.Create('Portail: commande clavier refusee.');
end;
procedure WaylandText(CodePoint: Cardinal);
var Sym: Cardinal;
begin
  if (CodePoint < 32) or (CodePoint > $10ffff) or
    ((CodePoint >= $d800) and (CodePoint <= $dfff)) or not WaylandAlive then Exit;
  if CodePoint <= $ff then Sym := CodePoint else Sym := $01000000 or CodePoint;
  if NativeKey(Handle, Sym, 1) = 0 then
    raise Exception.Create('Portail: caractere non accepte.');
  if NativeKey(Handle, Sym, 0) = 0 then
    raise Exception.Create('Portail: relachement du caractere refuse.');
end;
procedure WaylandWheel(Notches: SmallInt);
begin
  if WaylandAlive and (NativeWheel(Handle, Notches) = 0) then
    raise Exception.Create('Portail: commande molette refusee.');
end;
finalization
  // TKvmServer is destroyed (network workers joined) before closing the portal.
  CloseWayland;
  if Lib <> NilHandle then UnloadLibrary(Lib);
end.
