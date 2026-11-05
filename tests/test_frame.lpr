program test_frame;
{$mode objfpc}{$H+}
uses SysUtils, kvm_frame, kvm_damage;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('ERROR: ', Msg);
    Halt(1);
  end;
end;

var
  F, Prev: TRgbFrame;
  I, W, H: Integer;
  InitialPtr: Pointer;
begin
  F.Width := 0; F.Height := 0; F.RGB := '';
  Prev.Width := 0; Prev.Height := 0; Prev.RGB := '';
  Check(ScaledSize(3840, 2160, 1600, 1000, W, H), 'scale');
  Check((W = 1600) and (H = 900), 'aspect ratio');
  Check(AllocateFrame(F, 32, 32), 'allocate');
  InitialPtr := @F.RGB[1];
  Check(AllocateFrame(F, 32, 32), 'same geometry allocate');
  Check(InitialPtr = @F.RGB[1], 'capture buffer reused');
  for I := 1 to Length(F.RGB) do F.RGB[I] := #0;
  Check(RegionTileChanged(F, Prev, 0, 0, 32, 32), 'initial dirty');
  CopyFrameReuse(F, Prev);
  Check(not RegionTileChanged(F, Prev, 0, 0, 32, 32), 'unchanged');
  F.RGB[7] := #255;
  Check(RegionTileChanged(F, Prev, 0, 0, 32, 32), 'exact dirty pixel');
  CopyFrameReuse(F, Prev);
  Check(not RegionTileChanged(F, Prev, 0, 0, 32, 32), 'after commit');
  WriteLn('OK: RGB reuse, exact dirty comparison, resolution');
end.
