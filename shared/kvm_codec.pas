unit kvm_codec;
{$mode objfpc}{$H+}
{$I kvm_build.inc}
interface
uses SysUtils, Dynlibs, ctypes, kvm_frame;
function CodecAvailable(out Reason: string): Boolean;
type
  TKvmH264Encoder = class
  private FHandle: Pointer;
  public
    constructor Create(const Name, Device: string; W,H,FPS,Kbps: Integer);
    destructor Destroy; override;
    function Encode(const Frame: TRgbFrame; out Data: RawByteString; out Reason: string): Boolean;
  end;
  TKvmH264Decoder = class
  private FHandle: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    function Decode(const Data: RawByteString; W,H: Integer; var Frame: TRgbFrame; out Reason: string): Boolean;
  end;
implementation
uses {$IFDEF KVM_STATIC_CODEC}kvm_codec_static,{$ENDIF} kvm_extwire;
type
  PKvmSize = ^csize_t;
  TAbi = function: cuint32; cdecl;
  TEncoderOpen = function(Name,Device: PAnsiChar; W,H,FPS,Kbps: cint; Error: PAnsiChar; Cap: csize_t): Pointer; cdecl;
  TEncode = function(Handle,RGB: Pointer; RGBSize: csize_t; Dest: Pointer; Cap: csize_t;
    Written: PKvmSize; Error: PAnsiChar; ErrorCap: csize_t): cint; cdecl;
  TDecoderOpen = function(Error: PAnsiChar; Cap: csize_t): Pointer; cdecl;
  TDecode = function(Handle,Data: Pointer; Size: csize_t; W,H: cint; Dest: Pointer;
    Cap: csize_t; Error: PAnsiChar; ErrorCap: csize_t): cint; cdecl;
  TClose = procedure(Handle: Pointer); cdecl;
var
  Lib: TLibHandle = NilHandle;
  Lock: TRTLCriticalSection;
  LinkedReady: Boolean = False;
  EncoderOpen: TEncoderOpen; EncodeProc: TEncode; EncoderClose: TClose;
  DecoderOpen: TDecoderOpen; DecodeProc: TDecode; DecoderClose: TClose;
function CodecAvailable(out Reason: string): Boolean;
var Name: string; Abi: TAbi;
begin
  EnterCriticalSection(Lock);
  try
    Reason:='';
    {$IFDEF KVM_STANDALONE}
      {$IFDEF KVM_STATIC_CODEC}
      if LinkedReady then Exit(True);
      Abi:=@KvmCodecAbi;
      EncoderOpen:=@KvmEncoderOpen; Pointer(EncodeProc):=@KvmEncode;
      EncoderClose:=@KvmEncoderClose; DecoderOpen:=@KvmDecoderOpen;
      DecodeProc:=@KvmDecode; DecoderClose:=@KvmDecoderClose;
      Result:=Abi()=$00090001; LinkedReady:=Result;
      if not Result then Reason:='ABI codec integre incompatible';
      Exit;
      {$ELSE}
      Reason:='H264 non integre a ce build autonome (recompiler avec --with-codec). JPEG disponible.';
      Exit(False);
      {$ENDIF}
    {$ELSE}
    if Lib<>NilHandle then Exit(True);
    {$IFDEF WINDOWS}Name:='meshkvm_codec.dll';{$ENDIF}
    {$IFDEF LINUX}Name:='libmeshkvm_codec.so';{$ENDIF}
    {$IFDEF DARWIN}Name:='libmeshkvm_codec.dylib';{$ENDIF}
    // Deliberately not the current directory or PATH.
    Name:=IncludeTrailingPathDelimiter(ExtractFilePath(ExpandFileName(ParamStr(0))))+Name;
    Lib:=LoadLibrary(Name);
    if Lib=NilHandle then begin Reason:='Pont codec absent/inchargeable : '+Name; Exit(False); end;
    Pointer(Abi):=GetProcedureAddress(Lib,'meshkvm_codec_abi');
    Pointer(EncoderOpen):=GetProcedureAddress(Lib,'meshkvm_encoder_open');
    Pointer(EncodeProc):=GetProcedureAddress(Lib,'meshkvm_encode');
    Pointer(EncoderClose):=GetProcedureAddress(Lib,'meshkvm_encoder_close');
    Pointer(DecoderOpen):=GetProcedureAddress(Lib,'meshkvm_decoder_open');
    Pointer(DecodeProc):=GetProcedureAddress(Lib,'meshkvm_decode');
    Pointer(DecoderClose):=GetProcedureAddress(Lib,'meshkvm_decoder_close');
    Result:=Assigned(Abi) and Assigned(EncoderOpen) and Assigned(EncodeProc) and
      Assigned(EncoderClose) and Assigned(DecoderOpen) and Assigned(DecodeProc) and Assigned(DecoderClose);
    if Result then Result:=Abi()=$00090001;
    if not Result then begin UnloadLibrary(Lib); Lib:=NilHandle; Reason:='ABI codec incompatible'; end;
    {$ENDIF}
  finally LeaveCriticalSection(Lock); end;
end;
constructor TKvmH264Encoder.Create(const Name,Device: string; W,H,FPS,Kbps: Integer);
var Reason: string; Error: array[0..511] of AnsiChar;
begin
  inherited Create;
  if not CodecAvailable(Reason) then raise Exception.Create(Reason);
  FillChar(Error,SizeOf(Error),0);
  FHandle:=EncoderOpen(PAnsiChar(AnsiString(Name)),PAnsiChar(AnsiString(Device)),W,H,FPS,Kbps,@Error[0],SizeOf(Error));
  if FHandle=nil then raise Exception.Create('Encodeur '+Name+': '+string(PAnsiChar(@Error[0])));
end;
destructor TKvmH264Encoder.Destroy;
begin if FHandle<>nil then EncoderClose(FHandle); inherited Destroy; end;
function TKvmH264Encoder.Encode(const Frame: TRgbFrame; out Data: RawByteString; out Reason: string): Boolean;
var N: csize_t; Error: array[0..511] of AnsiChar;
begin
  Data:=''; Reason:=''; Result:=False;
  if (Frame.Width<2) or (Frame.Height<2) or (Length(Frame.RGB)<>Int64(Frame.Width)*Frame.Height*3) then Exit;
  SetLength(Data,KVM_MAX_VIDEO_BYTES); N:=0; FillChar(Error,SizeOf(Error),0);
  Result:=EncodeProc(FHandle,Pointer(Frame.RGB),Length(Frame.RGB),Pointer(Data),Length(Data),@N,@Error[0],SizeOf(Error))=0;
  Result:=Result and (N>0) and (N<=csize_t(Length(Data)));
  if Result then SetLength(Data,N)
  else begin Data:=''; Reason:=string(PAnsiChar(@Error[0])); end;
end;
constructor TKvmH264Decoder.Create;
var Reason: string; Error: array[0..511] of AnsiChar;
begin
  inherited Create;
  if not CodecAvailable(Reason) then raise Exception.Create(Reason);
  FillChar(Error,SizeOf(Error),0); FHandle:=DecoderOpen(@Error[0],SizeOf(Error));
  if FHandle=nil then raise Exception.Create(string(PAnsiChar(@Error[0])));
end;
destructor TKvmH264Decoder.Destroy;
begin if FHandle<>nil then DecoderClose(FHandle); inherited Destroy; end;
function TKvmH264Decoder.Decode(const Data: RawByteString; W,H: Integer; var Frame: TRgbFrame; out Reason: string): Boolean;
var Error: array[0..511] of AnsiChar;
begin
  Reason:=''; Result:=False;
  if (Length(Data)<5) or (Length(Data)>KVM_MAX_VIDEO_BYTES) or not AllocateFrame(Frame,W,H) then Exit;
  FillChar(Error,SizeOf(Error),0);
  Result:=DecodeProc(FHandle,Pointer(Data),Length(Data),W,H,Pointer(Frame.RGB),Length(Frame.RGB),@Error[0],SizeOf(Error))=0;
  if not Result then begin Reason:=string(PAnsiChar(@Error[0])); Frame.RGB:=''; Frame.Width:=0; Frame.Height:=0; end;
end;
initialization InitCriticalSection(Lock);
finalization
  if Lib<>NilHandle then UnloadLibrary(Lib);
  DoneCriticalSection(Lock);
end.
