unit kvm_inject_win;

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

function GetCursorNormalized(out NX, NY: Word): Boolean;
procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
procedure InjectText(CodePoint: Cardinal);
procedure InjectKey(Pressed: Boolean; VKey: Word);
procedure InjectWheel(Notches: SmallInt);

implementation

uses Math, kvm_monitors, kvm_geometry;

function KvmSendInput(Count: UINT; Inputs: Pointer; InputSize: Integer): UINT;
  stdcall; external 'user32.dll' name 'SendInput';

function GetCursorNormalized(out NX, NY: Word): Boolean;
var P: TPoint; M: TKvmMonitor;
begin
  NX := 0; NY := 0; Result := GetCursorPos(P);
  if not Result then Exit;
  M := CaptureMonitor; Result := NormalizePoint(M.Bounds, P.X, P.Y, NX, NY);
end;

procedure InjectMouse(Action, Button: Byte; NX, NY: Word);
var
  X, Y: Integer; M: TKvmMonitor;
  Flags: DWORD; TI: TInput;
begin
  M := CaptureMonitor;
  if DenormalizePoint(M.Bounds, NX, NY, X, Y) then
  begin
    if not SetCursorPos(X,Y) and (Action <> 2) then
      raise Exception.Create('Windows refuse le mouvement du pointeur.');
  end
  else if Action <> 2 then Exit;
  if Action = 0 then Exit;
  Flags := 0;
  case Button of
    1: if Action = 1 then Flags := MOUSEEVENTF_LEFTDOWN
       else Flags := MOUSEEVENTF_LEFTUP;
    2: if Action = 1 then Flags := MOUSEEVENTF_RIGHTDOWN
       else Flags := MOUSEEVENTF_RIGHTUP;
    3: if Action = 1 then Flags := MOUSEEVENTF_MIDDLEDOWN
       else Flags := MOUSEEVENTF_MIDDLEUP;
  end;
  if Flags <> 0 then
  begin
    FillChar(TI,SizeOf(TI),0); TI._Type := INPUT_MOUSE; TI.mi.dwFlags := Flags;
    if KvmSendInput(1,@TI,SizeOf(TI)) <> 1 then
      raise Exception.Create('Windows refuse le bouton de souris.');
  end;
end;

procedure InjectText(CodePoint: Cardinal);
var
  TI: TInput;
  KI: TKeybdInput;
  Codes: array[0..1] of Word;
  Count, I: Integer;
const
  KVM_UNICODE_FLAG = $0004;
begin
  if (CodePoint < 32) or (CodePoint > $10ffff) then Exit;
  if CodePoint <= $ffff then
  begin
    Codes[0] := Word(CodePoint);
    Count := 1;
  end
  else
  begin
    Dec(CodePoint, $10000);
    Codes[0] := $d800 or Word(CodePoint shr 10);
    Codes[1] := $dc00 or Word(CodePoint and $3ff);
    Count := 2;
  end;
  for I := 0 to Count - 1 do
  begin
    FillChar(TI, SizeOf(TI), 0);
    FillChar(KI, SizeOf(KI), 0);
    TI._Type := INPUT_KEYBOARD;
    KI.wScan := Codes[I];
    KI.dwFlags := KVM_UNICODE_FLAG;
    TI.ki := KI;
    if KvmSendInput(1, @TI, SizeOf(TI)) <> 1 then
      raise Exception.Create('Windows refuse la saisie Unicode (session ou privileges).');
    KI.dwFlags := KVM_UNICODE_FLAG or KEYEVENTF_KEYUP;
    TI.ki := KI;
    if KvmSendInput(1, @TI, SizeOf(TI)) <> 1 then
      raise Exception.Create('Windows refuse la saisie Unicode (session ou privileges).');
  end;
end;

procedure InjectKey(Pressed: Boolean; VKey: Word);
var TI: TInput;
begin
  if VKey > 255 then Exit;
  FillChar(TI, SizeOf(TI), 0); TI._Type := INPUT_KEYBOARD;
  TI.ki.wVk := VKey; TI.ki.wScan := Word(MapVirtualKey(VKey, 0));
  if VKey in [$21..$28, $2d, $2e, $5b, $5c, $5d, $6f, $90, $a3, $a5] then
    TI.ki.dwFlags := KEYEVENTF_EXTENDEDKEY;
  if not Pressed then TI.ki.dwFlags := TI.ki.dwFlags or KEYEVENTF_KEYUP;
  if KvmSendInput(1, @TI, SizeOf(TI)) <> 1 then
    raise Exception.Create('SendInput refuse (session ou privileges Windows).');
end;

procedure InjectWheel(Notches: SmallInt);
var TI: TInput;
begin
  if Notches = 0 then Exit;
  FillChar(TI,SizeOf(TI),0); TI._Type := INPUT_MOUSE;
  TI.mi.dwFlags := MOUSEEVENTF_WHEEL;
  TI.mi.mouseData := DWORD(LongInt(Notches) * WHEEL_DELTA);
  if KvmSendInput(1,@TI,SizeOf(TI)) <> 1 then
    raise Exception.Create('Windows refuse la molette.');
end;

end.
