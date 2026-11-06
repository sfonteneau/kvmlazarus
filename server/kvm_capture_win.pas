unit kvm_capture_win;
{$mode objfpc}{$H+}{$pointermath on}
interface
uses Windows, kvm_frame;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
procedure CloseCapture;
implementation
uses kvm_monitors, kvm_wire, SysUtils, Math;
const CAPTUREBLT_FLAG = $40000000;
var
  ScreenDC, MemDC: HDC;
  DIB: HBITMAP;
  OldObj: HGDIOBJ;
  Bits: Pointer;
  BufferW, BufferH, BufferStride: Integer;
// Called only by the capture worker, including destruction. A GetDC handle
// must be released on the thread which acquired it.
procedure CloseCapture;
begin
  if (OldObj <> 0) and (MemDC <> 0) then SelectObject(MemDC, OldObj);
  if DIB <> 0 then DeleteObject(DIB);
  if MemDC <> 0 then DeleteDC(MemDC);
  if ScreenDC <> 0 then ReleaseDC(0, ScreenDC);
  ScreenDC := 0; MemDC := 0; DIB := 0; OldObj := 0; Bits := nil;
  BufferW := 0; BufferH := 0; BufferStride := 0;
end;
function EnsureBuffer(W, H: Integer): Boolean;
var BI: TBitmapInfo;
begin
  if (DIB <> 0) and (W = BufferW) and (H = BufferH) then Exit(True);
  CloseCapture; Result := False;
  ScreenDC := GetDC(0); if ScreenDC = 0 then Exit;
  MemDC := CreateCompatibleDC(ScreenDC); if MemDC = 0 then Exit;
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(TBitmapInfoHeader);
  BI.bmiHeader.biWidth := W; BI.bmiHeader.biHeight := -H;
  BI.bmiHeader.biPlanes := 1; BI.bmiHeader.biBitCount := 24;
  BI.bmiHeader.biCompression := BI_RGB;
  DIB := CreateDIBSection(ScreenDC, BI, DIB_RGB_COLORS, Bits, 0, 0);
  if (DIB = 0) or (Bits = nil) then Exit;
  OldObj := SelectObject(MemDC, DIB);
  if (OldObj=0) or (PtrUInt(OldObj)=High(PtrUInt)) then
  begin OldObj:=0; Exit; end;
  SetStretchBltMode(MemDC, HALFTONE); SetBrushOrgEx(MemDC, 0, 0, nil);
  BufferW := W; BufferH := H;
  BufferStride := (W * 3 + 3) and not 3; Result := True;
end;
procedure DrawCursor(DC: HDC; const M: TKvmMonitor; W,H: Integer);
type
  TKvmBitmap = record
    Kind, Width, Height, WidthBytes: LongInt;
    Planes, BitsPixel: Word;
    Data: Pointer;
  end;
var C: TCursorInfo; Info: TIconInfo; BM: TKvmBitmap;
  CW,CH,L,T: Integer;
begin
  FillChar(C,SizeOf(C),0); C.cbSize := SizeOf(C);
  if not GetCursorInfo(C) or ((C.flags and 1) = 0) or (C.hCursor = 0) then Exit;
  FillChar(Info,SizeOf(Info),0);
  if not GetIconInfo(C.hCursor,Info) then Exit;
  try
    FillChar(BM,SizeOf(BM),0);
    if Info.hbmColor <> 0 then GetObject(Info.hbmColor,SizeOf(BM),@BM)
    else begin GetObject(Info.hbmMask,SizeOf(BM),@BM); BM.Height := BM.Height div 2; end;
    if (BM.Width < 1) or (BM.Height < 1) or (BM.Width > 512) or (BM.Height > 512) then Exit;
    CW := Max(1,MulDiv(BM.Width,W,M.Bounds.W));
    CH := Max(1,MulDiv(BM.Height,H,M.Bounds.H));
    L := MulDiv(C.ptScreenPos.X-M.Bounds.X-Integer(Info.xHotspot),W,M.Bounds.W);
    T := MulDiv(C.ptScreenPos.Y-M.Bounds.Y-Integer(Info.yHotspot),H,M.Bounds.H);
    DrawIconEx(DC,L,T,C.hCursor,CW,CH,0,0,DI_NORMAL);
  finally
    if Info.hbmColor <> 0 then DeleteObject(Info.hbmColor);
    if Info.hbmMask <> 0 then DeleteObject(Info.hbmMask);
  end;
end;
function CaptureDesktopRgb(MaxW, MaxH: Integer; var Frame: TRgbFrame): Boolean;
var M: TKvmMonitor; W, H: Integer;
begin
  Result := False;
  if not RefreshMonitor then Exit;
  M := CaptureMonitor;
  if not ScaledSize(M.Bounds.W, M.Bounds.H, MaxW, MaxH, W, H) then
    raise Exception.CreateFmt(
      'Bureau %dx%d hors limites de capture (%d px par cote / %d pixels au total). '
      + 'Recompiler x64 ou reduire volontairement --max-width/--max-height.',
      [M.Bounds.W, M.Bounds.H, KVM_MAX_FRAME_SIDE, KVM_MAX_FRAME_PIXELS]);
  if not EnsureBuffer(W, H) then begin CloseCapture; Exit; end;
  if (W = M.Bounds.W) and (H = M.Bounds.H) then
    Result := BitBlt(MemDC, 0, 0, W, H, ScreenDC, M.Bounds.X, M.Bounds.Y,
      SRCCOPY or CAPTUREBLT_FLAG)
  else
    Result := StretchBlt(MemDC, 0, 0, W, H, ScreenDC, M.Bounds.X, M.Bounds.Y,
      M.Bounds.W, M.Bounds.H, SRCCOPY or CAPTUREBLT_FLAG);
  if not Result then begin CloseCapture; Exit; end;
  DrawCursor(MemDC,M,W,H);
  if not GdiFlush then begin CloseCapture; Exit(False); end;
  // Native BGR24 stays BGR through damage detection and TurboJPEG. No
  // per-pixel channel swap; only row padding is removed by bounded copies.
  Result:=CopyBgrDib24(Bits,SizeUInt(BufferStride)*SizeUInt(H),
    BufferStride,W,H,Frame);
end;
end.
