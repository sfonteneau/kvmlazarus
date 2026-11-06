unit kvm_video;
{$mode objfpc}{$H+}
interface
uses SysUtils, kvm_frame, kvm_damage, kvm_turbojpeg, kvm_codec;
type
  TKvmPackets = array of RawByteString;
  TKvmVersions = array of Cardinal;
  TKvmVideo = class
  private
    FEncoder: TTurboJpegEncoder;
    FH264: TKvmH264Encoder;
    FHardwareName, FDevice: string;
    FUseH264: Boolean;
    FFPS, FBitrate: Integer;
    FFrame, FPrevious: TRgbFrame;
    FDirty: TKvmDirtyMap;
    FRegions: TKvmRegions;
    FPackets: TKvmPackets;
    FQuality: Integer;
    FGeometryDirty: Boolean;
    function UpdateH264(const Source: TRgbFrame; MaxW,MaxH: Integer;
      out GeometryChanged: Boolean): Boolean;
  public
    Cache: TKvmPackets;
    Versions: TKvmVersions;
    Groups: TKvmGroupMap;
    Width, Height: Integer;
    constructor Create(const EncoderName: string = 'turbojpeg';
      const Device: string = ''; FPS: Integer = 3; Kbps: Integer = 8000);
    destructor Destroy; override;
    function Update(const Source: TRgbFrame; MaxW, MaxH, Quality: Integer;
      out GeometryChanged: Boolean): Boolean;
  end;
implementation
uses Math, kvm_wire, kvm_extwire;
constructor TKvmVideo.Create(const EncoderName,Device: string; FPS,Kbps: Integer);
begin
  inherited Create; FEncoder:=TTurboJpegEncoder.Create;
  FHardwareName:=EncoderName; FDevice:=Device; FFPS:=FPS; FBitrate:=Kbps;
  FUseH264:=EncoderName<>'turbojpeg';
end;
destructor TKvmVideo.Destroy;
begin FH264.Free; FEncoder.Free; inherited Destroy; end;
function TKvmVideo.Update(const Source: TRgbFrame; MaxW, MaxH, Quality: Integer;
  out GeometryChanged: Boolean): Boolean;
var
  W, H, Cols, Rows, R, C, X, Y, TW, TH, I, J, T: Integer;
  Changed: Boolean;
  Jpeg: RawByteString;
  Current: TRgbFrame;
begin
  Result := False; GeometryChanged := False;
  if FUseH264 then
  begin
    try Exit(UpdateH264(Source,MaxW,MaxH,GeometryChanged));
    except on E: Exception do
      begin
        if FHardwareName<>'auto' then raise;
        WriteLn('[codec] Repli TurboJPEG : ',E.Message);
        FUseH264:=False; FreeAndNil(FH264);
        FQuality:=-1; FGeometryDirty:=True; Width:=0; Height:=0;
        SetLength(Cache,0); SetLength(Versions,0); SetLength(Groups,0);
        FPrevious.Width:=0; FPrevious.Height:=0; FPrevious.RGB:='';
      end;
    end;
  end;
  // Native-size path: reference the capture buffer only until this call
  // returns. Do not keep an alias in FFrame across the next capture.
  if not ScaledSize(Source.Width, Source.Height, MaxW, MaxH, W, H) then Exit;
  if (W = Source.Width) and (H = Source.Height) then
    Current := Source
  else
  begin
    if not ResizeFrame(Source, MaxW, MaxH, FFrame) then Exit;
    Current := FFrame;
  end;
  W := Current.Width; H := Current.Height;
  Cols := (W + KVM_TILE_SIZE - 1) div KVM_TILE_SIZE;
  Rows := (H + KVM_TILE_SIZE - 1) div KVM_TILE_SIZE;
  GeometryChanged := (W <> Width) or (H <> Height);
  if GeometryChanged or (Quality <> FQuality) then
  begin
    Width := W; Height := H; FQuality := Quality;
    SetLength(Cache, Cols * Rows); SetLength(Versions, Cols * Rows);
    SetLength(Groups, Cols * Rows); SetLength(FDirty, Cols * Rows);
    for I := 0 to High(Cache) do
    begin Cache[I] := ''; Versions[I] := 0; Groups[I] := I; end;
    FPrevious.Width := 0; FPrevious.Height := 0; FPrevious.RGB := '';
    FGeometryDirty := True;
  end;
  Changed := False;
  for R := 0 to Rows - 1 do
    for C := 0 to Cols - 1 do
    begin
      X := C * KVM_TILE_SIZE; Y := R * KVM_TILE_SIZE;
      TW := Min(KVM_TILE_SIZE, W - X); TH := Min(KVM_TILE_SIZE, H - Y);
      I := R * Cols + C;
      FDirty[I] := (Cache[I] = '') or
        RegionTileChanged(Current, FPrevious, X, Y, TW, TH);
      Changed := Changed or FDirty[I];
    end;
  if Changed then
  begin
    ExpandDirtyCacheGroups(FDirty, Groups);
    if not MakeDirtyRegions(FDirty, Cols, Rows, W, H, FRegions) then Exit;
    SetLength(FPackets, Length(FRegions));
    for I := 0 to High(FRegions) do
    begin
      if not FEncoder.EncodeRect(Current, FRegions[I].X, FRegions[I].Y,
        FRegions[I].W, FRegions[I].H, Quality, Jpeg) then Exit;
      FPackets[I] := MakeTile(FRegions[I].X, FRegions[I].Y,
        FRegions[I].W, FRegions[I].H, Jpeg);
    end;
    // Atomic commit of all new rectangles, never half a new snapshot.
    for I := 0 to High(FRegions) do
      for R := FRegions[I].Row to FRegions[I].Row + FRegions[I].Rows - 1 do
        for C := FRegions[I].Col to FRegions[I].Col + FRegions[I].Cols - 1 do
        begin
          T := R * Cols + C; Cache[T] := FPackets[I];
          Groups[T] := FRegions[I].Leader;
          if Versions[T] = High(Cardinal) then Versions[T] := 1 else Inc(Versions[T]);
        end;
    // After the first snapshot, only modified rectangular regions need
    // copying into the previous-frame reference. Unchanged pixels remain
    // identical. ExpandDirtyCacheGroups has already expanded old JPEG groups.
    CopyFrameRegions(Current, FPrevious, FRegions);
  end;
  for J := 0 to High(Cache) do if Cache[J] = '' then Exit;
  Result := Length(Cache) > 0;
  if Result then begin GeometryChanged := FGeometryDirty; FGeometryDirty := False; end;
end;

function TKvmVideo.UpdateH264(const Source: TRgbFrame; MaxW,MaxH: Integer;
  out GeometryChanged: Boolean): Boolean;
const
  {$IFDEF WINDOWS}Candidates: array[0..2] of string = ('h264_nvenc','h264_qsv','h264_amf');{$ENDIF}
  {$IFDEF LINUX}Candidates: array[0..2] of string = ('h264_vaapi','h264_nvenc','h264_qsv');{$ENDIF}
  {$IFDEF DARWIN}Candidates: array[0..0] of string = ('h264_videotoolbox');{$ENDIF}
var
  W,H,X,Y,SX,SY,A,B,I: Integer; Changed: Boolean;
  Data,Packet: RawByteString; Reason,LastError: string;
begin
  Result:=False; GeometryChanged:=False;
  if (Source.Width<2) or (Source.Height<2) or
     (Length(Source.RGB)<>Int64(Source.Width)*Source.Height*3) then
    raise Exception.Create('Dimensions source H.264 invalides');
  if not ScaledSize(Source.Width,Source.Height,MaxW,MaxH,W,H) then Exit;
  W:=W and not 1; H:=H and not 1;
  if not AllocateFrame(FFrame,W,H) then raise Exception.Create('Dimensions H.264 impossibles');
  // The even size is derived once. Pixel coordinates remain normalized.
  if (W=Source.Width) and (H=Source.Height) then
    Move(Source.RGB[1],FFrame.RGB[1],Length(Source.RGB))
  else for Y:=0 to H-1 do
  begin
    SY:=(Int64(Y)*Source.Height) div H;
    for X:=0 to W-1 do
    begin
      SX:=(Int64(X)*Source.Width) div W;
      A:=(SY*Source.Width+SX)*3+1; B:=(Y*W+X)*3+1;
      FFrame.RGB[B]:=Source.RGB[A]; FFrame.RGB[B+1]:=Source.RGB[A+1];
      FFrame.RGB[B+2]:=Source.RGB[A+2];
    end;
  end;
  FFrame.Order := Source.Order;
  GeometryChanged:=(Width<>W) or (Height<>H);
  if GeometryChanged then
  begin
    FreeAndNil(FH264); Width:=W; Height:=H;
    FPrevious.RGB:=''; FPrevious.Width:=0; FPrevious.Height:=0;
    SetLength(Cache,1); Cache[0]:=''; SetLength(Versions,1); Versions[0]:=0;
    SetLength(Groups,1); Groups[0]:=0; FGeometryDirty:=True;
  end;
  if FH264=nil then
  begin
    if FHardwareName<>'auto' then
      FH264:=TKvmH264Encoder.Create(FHardwareName,FDevice,W,H,FFPS,FBitrate)
    else
    begin
      LastError:='Aucun encodeur materiel disponible';
      for I:=0 to High(Candidates) do
      begin
        try
          FH264:=TKvmH264Encoder.Create(Candidates[I],FDevice,W,H,FFPS,FBitrate);
          // Probe actual output, not only whether avcodec_open2 succeeded.
          if not FH264.Encode(FFrame,Data,Reason) then raise Exception.Create(Reason);
          WriteLn('[codec] Profil H.264 materiel : ',Candidates[I]); Break;
        except on E: Exception do begin LastError:=E.Message; FreeAndNil(FH264); end; end;
      end;
      if FH264=nil then raise Exception.Create(LastError);
    end;
  end;
  Changed:=(FPrevious.Order<>FFrame.Order) or
    (Length(FPrevious.RGB)<>Length(FFrame.RGB)) or (Cache[0]='');
  if not Changed then Changed:=not CompareMem(Pointer(FPrevious.RGB),Pointer(FFrame.RGB),Length(FFrame.RGB));
  if Changed then
  begin
    if not FH264.Encode(FFrame,Data,Reason) then raise Exception.Create(Reason);
    Packet:=MakeVideo(W,H,Data); if Packet='' then raise Exception.Create('Paquet H.264 hors limite');
    Cache[0]:=Packet; Versions[0]:=NextSerial(Versions[0]);
    CopyFrameReuse(FFrame,FPrevious);
  end;
  Result:=Cache[0]<>'';
  if Result then begin GeometryChanged:=FGeometryDirty; FGeometryDirty:=False; end;
end;
end.
