unit kvm_frame;

{$mode objfpc}{$H+}

interface

uses SysUtils;

type
  // Pixels stored as tightly-packed RGB24, top-left origin.
  TRgbFrame = record
    Width, Height: Integer;
    RGB: RawByteString;
  end;

function AllocateFrame(var Frame: TRgbFrame; W, H: Integer): Boolean;
function ScaledSize(SourceW, SourceH, MaxW, MaxH: Integer;
  out W, H: Integer): Boolean;

function ResizeFrame(const Source: TRgbFrame; MaxW, MaxH: Integer;
  var Dest: TRgbFrame): Boolean;

implementation

uses Math, kvm_wire;

function AllocateFrame(var Frame: TRgbFrame; W, H: Integer): Boolean;
begin
  Result := (W >= 1) and (H >= 1) and (W <= 8192) and (H <= 8192) and
    (Int64(W) * H <= KVM_MAX_FRAME_PIXELS);
  if not Result then Exit;
  if (Frame.Width <> W) or (Frame.Height <> H) or
     (Length(Frame.RGB) <> W * H * 3) then
    SetLength(Frame.RGB, W * H * 3);
  UniqueString(Frame.RGB); // a reused frame must never mutate an alias
  Frame.Width := W;
  Frame.Height := H;
end;

function ScaledSize(SourceW, SourceH, MaxW, MaxH: Integer;
  out W, H: Integer): Boolean;
var
  Factor: Double;
begin
  W := 0;
  H := 0;
  Result := (SourceW > 0) and (SourceH > 0) and (MaxW > 0) and (MaxH > 0);
  if not Result then Exit;
  Factor := Min(1.0, Min(MaxW / SourceW, MaxH / SourceH));
  W := Max(1, Round(SourceW * Factor));
  H := Max(1, Round(SourceH * Factor));
  Result := (W > 0) and (H > 0);
end;

function ResizeFrame(const Source: TRgbFrame; MaxW, MaxH: Integer;
  var Dest: TRgbFrame): Boolean;
var W, H, X, Y, SX, SY, A, B: Integer;
begin
  Result := False;
  if Length(Source.RGB) <> Int64(Source.Width) * Source.Height * 3 then Exit;
  if not ScaledSize(Source.Width, Source.Height, MaxW, MaxH, W, H) then Exit;
  if not AllocateFrame(Dest, W, H) then Exit;
  // Do not alias Source: the capture thread reuses its buffer on the next cycle.
  if (W = Source.Width) and (H = Source.Height) then
    Move(Source.RGB[1], Dest.RGB[1], Length(Source.RGB))
  else for Y := 0 to H - 1 do
  begin
    SY := (Int64(Y) * Source.Height) div H;
    for X := 0 to W - 1 do
    begin
      SX := (Int64(X) * Source.Width) div W;
      A := (SY * Source.Width + SX) * 3 + 1; B := (Y * W + X) * 3 + 1;
      Dest.RGB[B] := Source.RGB[A]; Dest.RGB[B+1] := Source.RGB[A+1];
      Dest.RGB[B+2] := Source.RGB[A+2];
    end;
  end;
  Result := True;
end;

end.
