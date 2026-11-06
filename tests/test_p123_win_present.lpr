program test_p123_win_present;
{$mode objfpc}{$H+}{$pointermath on}
uses Windows, SysUtils, kvm_surface, kvm_present_win;
procedure Check(Value: Boolean; const MessageText: string);
begin if not Value then raise Exception.Create(MessageText); end;
var DC,Screen: HDC; DIB: HBITMAP; Old: HGDIOBJ; Bits: Pointer;
    BI: TBitmapInfo; S: TKvmSurface; P: PByte; I: Integer;
begin
  DC:=0; DIB:=0; Old:=0; Screen:=GetDC(0);
  try
    Check(Screen<>0,'GetDC'); DC:=CreateCompatibleDC(Screen); Check(DC<>0,'CreateDC');
    FillChar(BI,SizeOf(BI),0); BI.bmiHeader.biSize:=SizeOf(TBitmapInfoHeader);
    BI.bmiHeader.biWidth:=16; BI.bmiHeader.biHeight:=-16;
    BI.bmiHeader.biPlanes:=1; BI.bmiHeader.biBitCount:=32;
    BI.bmiHeader.biCompression:=BI_RGB;
    DIB:=CreateDIBSection(Screen,BI,DIB_RGB_COLORS,Bits,0,0);
    Check((DIB<>0) and (Bits<>nil),'CreateDIBSection'); Old:=SelectObject(DC,DIB);
    Check(AllocateSurface(S,16,16),'Allocate');
    for I:=0 to 255 do
    begin
      S.Pixels[I*4+1]:=#30; S.Pixels[I*4+2]:=#110;
      S.Pixels[I*4+3]:=#210; S.Pixels[I*4+4]:=#255;
    end;
    Check(PaintWindowsSurface(DC,S,0,0,16,16),'Native presentation'); GdiFlush;
    P:=PByte(Bits);
    for I:=0 to 255 do
    begin
      Check((P[0]=30) and (P[1]=110) and (P[2]=210),'Native GDI channel mismatch'); Inc(P,4);
    end;
    Check(PaintWindowsSurface(DC,S,0,0,8,8),'HALFTONE presentation');
    WriteLn('PASS: real offscreen Windows GDI BGRX presentation and scaled path');
  finally
    if (DC<>0) and (Old<>0) then SelectObject(DC,Old);
    if DIB<>0 then DeleteObject(DIB);
    if DC<>0 then DeleteDC(DC);
    if Screen<>0 then ReleaseDC(0,Screen);
  end;
end.
