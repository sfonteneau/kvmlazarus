unit kvm_present_win;
{$mode objfpc}{$H+}
interface
uses Windows, kvm_surface;
// Main/UI thread only. Pixels stay immutable throughout the paint call.
function PaintWindowsSurface(DC: HDC; const S: TKvmSurface;
  X,Y,W,H: Integer): Boolean;
implementation
// Explicit Win32 ABI avoids pointer/var overload differences between RTLs.
function KvmStretchDIBits(DC: HDC; X,Y,W,H,SX,SY,SW,SH: LongInt;
  Pixels, Info: Pointer; Usage,Rop: DWORD): LongInt; stdcall;
  external 'gdi32.dll' name 'StretchDIBits';
function PaintWindowsSurface(DC: HDC; const S: TKvmSurface;
  X,Y,W,H: Integer): Boolean;
var BI: TBitmapInfo; Lines, OldMode: Integer; OldOrigin: TPoint;
begin
  Result:=False;
  if (DC=0) or not SurfaceValid(S) or (W<1) or (H<1) then Exit;
  FillChar(BI,SizeOf(BI),0);
  BI.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
  BI.bmiHeader.biWidth:=S.Width; BI.bmiHeader.biHeight:=-S.Height;
  BI.bmiHeader.biPlanes:=1; BI.bmiHeader.biBitCount:=32;
  BI.bmiHeader.biCompression:=BI_RGB;
  OldMode:=0; FillChar(OldOrigin,SizeOf(OldOrigin),0);
  if (W<>S.Width) or (H<>S.Height) then
  begin
    OldMode:=SetStretchBltMode(DC,HALFTONE);
    SetBrushOrgEx(DC,0,0,@OldOrigin);
  end;
  Lines:=KvmStretchDIBits(DC,X,Y,W,H,0,0,S.Width,S.Height,
    Pointer(S.Pixels),@BI,DIB_RGB_COLORS,SRCCOPY);
  GdiFlush; // do not leave a queued GDI access to a released snapshot
  if OldMode<>0 then
  begin SetStretchBltMode(DC,OldMode); SetBrushOrgEx(DC,OldOrigin.X,OldOrigin.Y,nil); end;
  Result:=(Lines<>0) and (Lines<>-1);
end;
end.
