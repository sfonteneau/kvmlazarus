unit kvm_server;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  mormot.core.base, mormot.net.http, mormot.net.server, mormot.net.ws.core,
  mormot.net.ws.server, kvm_wire, kvm_frame, kvm_flow,
  kvm_damage, kvm_turbojpeg, kvm_cli, kvm_adaptive, kvm_video, kvm_transport, kvm_extwire, kvm_security, kvm_metrics, kvm_clipboard_wire, kvm_clipboard_server_worker;

type
  TKvmServer = class;

  TCaptureThread = class(TThread)
  private
    FOwner: TKvmServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TKvmServer);
  end;

  TKvmClientState = record
    ID: THttpServerConnectionID;
    CanControl, Ready, DesktopNoticePending, Authenticated, H264: Boolean;
    InputRate, ByteRate, TextRate, ClipboardRate, ClipboardBytes: TKvmRate;
    LastClipboardSerial: Cardinal;
    BadFrames: Integer;
    LastTextSerial: Cardinal;
    LastTextPacket, LastTextReceipt: RawByteString;
    Adaptive: TKvmAdaptiveState;
    VideoRejects: Integer;
    LastSeen: QWord;
    MouseX, MouseY: Word;
    Keys: array[0..255] of Boolean;
    Buttons: array[1..3] of Boolean;
    Flow: TKvmFlowState;
  end;

  TKvmServer = class
  private
    FSocket: TKvmWebSocketServer;
    FWorker: TCaptureThread;
    FClipboardWorker: TKvmClipboardServerWorker;
    FWakeCapture: TEvent;
    FMaxW, FMaxH: Integer;
    FAdaptive: Boolean;
    FCanH264: Boolean;
    FEncoderName, FGPUDevice: string;
    FBitrateKbps: Integer;
    FUpgradeRate: TKvmRate;
    FDesktopReason: Byte;
    FDesktopEpoch: Cardinal;
    FMetrics: TKvmMetrics;
    FLock: TRTLCriticalSection;
    FClients: array of TKvmClientState;
    FController: THttpServerConnectionID;
    FToken, FViewToken: RawByteString;
    FFps, FQuality: Integer;
    FAllowControl, FDesktopAvailable: Boolean;
    FPendingKeyRelease: array[0..255] of Boolean;
    FPendingButtonRelease: array[1..3] of Boolean;
    FReleaseX, FReleaseY: Word;
    function ClipboardAllowed(ID: QWord; Epoch: Cardinal): Boolean;
    function ClipboardReply(ID: QWord; const Reply: TKvmClipReply): Boolean;
    procedure HandleClipboardFrame(Sender: TWebSocketProcess; const Packet: RawByteString);
    function AllowUpgrade(Protocol: TWebSocketProtocol): Integer;
    procedure ProtocolClosed(Protocol: TWebSocketProtocol);
    function AcceptPacket(ID: THttpServerConnectionID; Bytes: Integer): Boolean;
    procedure BadPacket(Sender: TWebSocketProcess);
    procedure RetryInputReleasesLocked;
    function PendingInputReleasesLocked: Boolean;
    procedure SetDesktopAvailable(Value: Boolean);
    procedure PublishDesktopState;
    function FindClientLocked(ID: THttpServerConnectionID): Integer;
    procedure ReleaseInputsLocked(var State: TKvmClientState);
    procedure RemoveClientLocked(Index: Integer);
    procedure RemoveClient(ID: THttpServerConnectionID);
    procedure ExpireIdleClients;
    procedure CaptureDemand(var Wanted: array of Boolean; NowTick: QWord;
      out CaptureW, CaptureH, CaptureRate: Integer);
    procedure DispatchBatches(Profile: Integer; const Cache: array of RawByteString;
      const Versions: array of Cardinal; const Groups: array of Integer;
      Width, Height: Word;
      CursorValid: Boolean; CursorX, CursorY: Word);
    procedure NackBatch(ID: THttpServerConnectionID; Serial: Cardinal);
    procedure ActivateClient(ID: THttpServerConnectionID);
    procedure AckBatch(ID: THttpServerConnectionID; Serial: Cardinal);
    procedure InvalidateSnapshots(Profile: Integer);
    procedure RequestSnapshot(ID: THttpServerConnectionID);
    function AddClient(ID: THttpServerConnectionID; CanControl,H264: Boolean): Boolean;
    function TouchClient(ID: THttpServerConnectionID): Boolean;
    function AcquireControl(ID: THttpServerConnectionID): Boolean;
    procedure RelinquishControl(ID: THttpServerConnectionID; KeepOwner: Boolean);
    procedure HandleMouse(ID: THttpServerConnectionID; Action, Button: Byte; X, Y: Word);
    function HandleText(ID: THttpServerConnectionID; Serial: Cardinal;
      const Packet: RawByteString; const Points: TKvmCodePoints): RawByteString;
    procedure HandleKey(ID: THttpServerConnectionID; Pressed: Boolean; VKey: Word);
    procedure HandleWheel(ID: THttpServerConnectionID; Notches: SmallInt);
    procedure HandleFrame(Sender: TWebSocketProcess; const Frame: TWebSocketFrame);
    procedure SendText(Sender: TWebSocketProcess; const Msg: RawByteString);
  public
    constructor Create(const Options: TKvmServerOptions);
    destructor Destroy; override;
  end;

implementation

uses Math, kvm_desktop, kvm_codec, kvm_session_guard, kvm_schedule, kvm_clipboard_native;

const
  // A dead network client may never deliver a WebSocket close notification.
  // The viewer sends a P heartbeat every 3 seconds after authentication.
  KVM_CLIENT_TIMEOUT_MS = 15000;
  KVM_MAX_CLIENTS = 16;
  KVM_MAX_CONNECTIONS = 32;
  KVM_AUTH_TIMEOUT_MS = 5000;
  KVM_VIDEO_COUNT = KVM_PROFILE_COUNT*2;

constructor TCaptureThread.Create(AOwner: TKvmServer);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TCaptureThread.Execute;
var
  Frame: TRgbFrame;
  Video: array[0..KVM_VIDEO_COUNT-1] of TKvmVideo;
  Wanted, Due, CacheValid: array[0..KVM_VIDEO_COUNT-1] of Boolean;
  NextTick: array[0..KVM_VIDEO_COUNT-1] of QWord;
  P,W,H,Q,FPS,CaptureW,CaptureH,CaptureRate: Integer;
  Started,Measured,NowTick: QWord;
  WaitMs: Cardinal;
  GeometryChanged,CursorValid,AnyDue,CaptureOpen,Captured: Boolean;
  CX,CY: Word;
begin
  for P:=0 to High(Video) do
  begin Video[P]:=nil; CacheValid[P]:=False; NextTick[P]:=0; end;
  CaptureOpen:=False; CX:=0; CY:=0; CursorValid:=False;
  try
    for P:=0 to High(Video) do
      if (P>=KVM_PROFILE_COUNT) and FOwner.FCanH264 then
      begin
        ProfileSettings(P mod KVM_PROFILE_COUNT,FOwner.FMaxW,FOwner.FMaxH,
          FOwner.FQuality,FOwner.FFps,W,H,Q,FPS);
        Video[P]:=TKvmVideo.Create(FOwner.FEncoderName,FOwner.FGPUDevice,FPS,
          Max(128,FOwner.FBitrateKbps div (1 shl (P mod KVM_PROFILE_COUNT))));
      end
      else Video[P]:=TKvmVideo.Create;
    while not Terminated do
    begin
      Started:=GetTickCount64;
      try
        PollSessionGuard; FOwner.FMetrics.Flush; FOwner.ExpireIdleClients;
        FOwner.CaptureDemand(Wanted,Started,CaptureW,CaptureH,CaptureRate);
        if CaptureW>0 then ConfigureCaptureFPS(CaptureRate);
        if (CaptureW=0) and CaptureOpen then
        begin CloseDesktopCapture; CaptureOpen:=False; end;
        FOwner.PublishDesktopState;
        if not DesktopCaptureAvailable then
        begin
          FOwner.SetDesktopAvailable(False);
          for P:=0 to High(CacheValid) do begin CacheValid[P]:=False; NextTick[P]:=0; end;
          {$IFDEF WINDOWS}
          if CaptureOpen then begin CloseDesktopCapture; CaptureOpen:=False; end;
          {$ENDIF}
          FOwner.FWakeCapture.WaitFor(50); Continue;
        end;
        AnyDue:=False;
        for P:=0 to High(Due) do
        begin
          Due[P]:=Wanted[P] and (not CacheValid[P] or CaptureIsDue(Started,NextTick[P]));
          AnyDue:=AnyDue or Due[P];
        end;
        if AnyDue and (CaptureW>0) then
        begin
          CaptureOpen:=True; Measured:=GetTickCount64;
          Captured:=CaptureDesktopRgb(CaptureW,CaptureH,Frame);
          FOwner.FMetrics.Capture(GetTickCount64-Measured,Captured);
          PollSessionGuard; Captured:=Captured and SessionGuardAllowsInput;
          if Captured then
          begin
            FOwner.SetDesktopAvailable(True);
            CX:=0; CY:=0; CursorValid:=False;
            if not DesktopCursorEmbedded then CursorValid:=GetCursorNormalized(CX,CY);
            for P:=0 to High(Due) do if Due[P] and not Terminated then
            begin
              ProfileSettings(P mod KVM_PROFILE_COUNT,FOwner.FMaxW,FOwner.FMaxH,
                FOwner.FQuality,FOwner.FFps,W,H,Q,FPS);
              Measured:=GetTickCount64;
              CacheValid[P]:=Video[P].Update(Frame,W,H,Q,GeometryChanged);
              FOwner.FMetrics.Encode(GetTickCount64-Measured);
              NextTick[P]:=NextCaptureTick(Started,GetTickCount64,FPS);
              if GeometryChanged then FOwner.InvalidateSnapshots(P);
            end;
          end
          else
          begin
            FOwner.SetDesktopAvailable(False);
            for P:=0 to High(CacheValid) do begin CacheValid[P]:=False; NextTick[P]:=0; end;
            FOwner.FWakeCapture.WaitFor(50); Continue;
          end;
        end;
        // Drain cached rectangles after EACH ACK without waiting for the
        // next capture deadline, and without re-capturing/re-encoding them.
        // Stop-and-wait and bounded TryQueue are still enforced per client.
        PollSessionGuard;
        if not SessionGuardAllowsInput then
        begin
          FOwner.SetDesktopAvailable(False);
          for P:=0 to High(CacheValid) do CacheValid[P]:=False;
        end
        else for P:=0 to High(Video) do if CacheValid[P] and not Terminated then
          FOwner.DispatchBatches(P,Video[P].Cache,Video[P].Versions,Video[P].Groups,
            Video[P].Width,Video[P].Height,CursorValid,CX,CY);
      except
        on E: Exception do
        begin
          FOwner.SetDesktopAvailable(False);
          for P:=0 to High(CacheValid) do CacheValid[P]:=False;
          WriteLn('[capture] ',E.ClassName,': ',E.Message);
          // Bound retries, but wake promptly on shutdown.
          for P:=1 to 20 do begin if Terminated then Break; FOwner.FWakeCapture.WaitFor(50); end;
        end;
      end;
      // Re-read after dispatch: usually the client now waits for an ACK.
      // Auto-reset event avoids a lost wake-up between this query and wait.
      NowTick:=GetTickCount64;
      FOwner.CaptureDemand(Wanted,NowTick,CaptureW,CaptureH,CaptureRate);
      WaitMs:=50;
      for P:=0 to High(Wanted) do if Wanted[P] then
        WaitMs:=Min(WaitMs,CaptureWaitMs(NowTick,NextTick[P],50));
      if WaitMs=0 then
      begin
        // No implicit Windows timer-quantum FPS ceiling in --fps 0 mode.
        // Sleep(0) only yields to another runnable thread, without adding
        // a minimum 1-15ms wait to every capture cycle.
        if FOwner.FFps=0 then Sleep(0)
        else FOwner.FWakeCapture.WaitFor(1);
      end
      else FOwner.FWakeCapture.WaitFor(WaitMs);
    end;
  finally
    CloseDesktopCapture;
    for P:=0 to High(Video) do Video[P].Free;
  end;
end;

constructor TKvmServer.Create(const Options: TKvmServerOptions);
var
  Protocol: TWebSocketProtocolChat;
  Probe: TTurboJpegEncoder;
  Bind: RawUtf8;
  Reason: string;
begin
  inherited Create;
  InitCriticalSection(FLock);
  FWakeCapture:=TEvent.Create(nil,False,False,'');
  FMetrics:=TKvmMetrics.Create(Options.MetricsCSV);
  FEncoderName:=Options.Encoder; FGPUDevice:=Options.GPUDevice; FBitrateKbps:=Options.BitrateKbps;
  FCanH264:=FEncoderName<>'turbojpeg';
  if FCanH264 and not CodecAvailable(Reason) then
  begin
    if FEncoderName<>'auto' then raise Exception.Create(Reason);
    FCanH264:=False; WriteLn('[codec] ',Reason,' ; TurboJPEG uniquement');
  end;
  FDesktopReason:=KVM_SESSION_UNKNOWN; FDesktopEpoch:=1;
  InitRate(FUpgradeRate,32,4,GetTickCount64);
  FToken := RawByteString(Options.Token); FViewToken := RawByteString(Options.ViewToken);
  FFps := Options.FPS; FQuality := Options.Quality;
  FMaxW := Options.MaxWidth; FMaxH := Options.MaxHeight; FAdaptive := Options.Adaptive;
  FAllowControl := Options.AllowControl; FController := 0;
  FDesktopAvailable := False;
  WebSocketsMaxFrameMB := 4; // limit parsed incoming frames before dispatch
  Probe := TTurboJpegEncoder.Create; Probe.Free; // fail at startup if missing
  ConfigureCaptureFPS(FFps);
  Bind := RawUtf8(Options.Listen + ':' + IntToStr(Options.Port));
  if Options.TLSCert <> '' then
    FSocket := TKvmWebSocketServer.Create(Bind, nil, nil, 'MeshKVM', 2, 30000, [hsoEnableTls])
  else FSocket := TKvmWebSocketServer.Create(Bind, nil, nil, 'MeshKVM');
  FSocket.OnWebSocketUpgraded:=@AllowUpgrade;
  FSocket.OnWebSocketClose:=@ProtocolClosed;
  if FSocket.ThreadPool<>nil then FSocket.ThreadPool.MaxBodyThreadCount:=40;
  FSocket.Settings^.LoopDelay := 5;
  FSocket.Settings^.SendDelay := 1;
  Protocol := TWebSocketProtocolChat.Create(KVM_SUBPROTOCOL,
    KVM_WS_ROUTE, @HandleFrame);
  FSocket.WebSocketProtocols.Add(Protocol);
  if Options.TLSCert <> '' then
    FSocket.WaitStarted(30, Options.TLSCert, Options.TLSKey,
      RawUtf8(GetEnvironmentVariable('MESH_KVM_TLS_PASSWORD')))
  else
    FSocket.WaitStarted;
  FClipboardWorker:=TKvmClipboardServerWorker.Create(@CreateClipboardBackend,
    @ClipboardAllowed,@ClipboardReply,Pos('Wayland',DesktopBackendName)=0);
  FClipboardWorker.Start;
  FWorker := TCaptureThread.Create(Self);
  FWorker.Start;
end;

destructor TKvmServer.Destroy;
var
  I: Integer;
  ClipboardWorker: TKvmClipboardServerWorker;
begin
  EnterCriticalSection(FLock);
  try ClipboardWorker:=FClipboardWorker; FClipboardWorker:=nil;
  finally LeaveCriticalSection(FLock); end;
  ClipboardWorker.Free; // join before the transport and session locks die
  if FWorker <> nil then
  begin
    FWorker.Terminate;
    FWakeCapture.SetEvent;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
  FreeAndNil(FSocket);

  EnterCriticalSection(FLock);
  try
    for I := 0 to High(FClients) do
      if FClients[I].ID = FController then
        ReleaseInputsLocked(FClients[I]);
    SetLength(FClients, 0);
    FController := 0;
  finally
    LeaveCriticalSection(FLock);
  end;
  DoneCriticalSection(FLock);
  FWakeCapture.Free;
  FMetrics.Free;
  inherited Destroy;
end;

function TKvmServer.FindClientLocked(ID: THttpServerConnectionID): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FClients) do
    if FClients[I].ID = ID then Exit(I);
end;

procedure TKvmServer.ReleaseInputsLocked(var State: TKvmClientState);
var
  K, B: Integer;
begin
  for K := 0 to 255 do
    if State.Keys[K] then
    begin
      State.Keys[K] := False;
      try
        if not DesktopSessionAvailable then raise Exception.Create('Session suspendue');
        InjectKey(False, K); FPendingKeyRelease[K] := False;
      except on E: Exception do
        begin FPendingKeyRelease[K] := True; WriteLn('[input] Liberation touche differee: ', E.Message); end;
      end;
    end;
  for B := 1 to 3 do
    if State.Buttons[B] then
    begin
      State.Buttons[B] := False;
      try
        if not DesktopSessionAvailable then raise Exception.Create('Session suspendue');
        InjectMouse(2, B, State.MouseX, State.MouseY); FPendingButtonRelease[B] := False;
      except on E: Exception do
        begin
          FPendingButtonRelease[B] := True; FReleaseX := State.MouseX; FReleaseY := State.MouseY;
          WriteLn('[input] Liberation bouton differee: ', E.Message);
        end;
      end;
    end;
end;

function TKvmServer.PendingInputReleasesLocked: Boolean;
var K: Integer;
begin
  Result := True;
  for K := 0 to 255 do if FPendingKeyRelease[K] then Exit;
  for K := 1 to 3 do if FPendingButtonRelease[K] then Exit;
  Result := False;
end;

procedure TKvmServer.RetryInputReleasesLocked;
var K: Integer;
begin
  if not DesktopSessionAvailable then Exit;
  for K := 0 to 255 do if FPendingKeyRelease[K] then
    try InjectKey(False,K); FPendingKeyRelease[K] := False; except { retry on next frame } end;
  for K := 1 to 3 do if FPendingButtonRelease[K] then
    try InjectMouse(2,K,FReleaseX,FReleaseY); FPendingButtonRelease[K] := False; except end;
end;

procedure TKvmServer.RemoveClientLocked(Index: Integer);
var
  I: Integer;
begin
  if FClients[Index].ID = FController then
  begin
    ReleaseInputsLocked(FClients[Index]);
    FController := 0;
  end;
  for I := Index to High(FClients) - 1 do
    FClients[I] := FClients[I + 1];
  SetLength(FClients, Length(FClients) - 1);
end;

procedure TKvmServer.RemoveClient(ID: THttpServerConnectionID);
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    I := FindClientLocked(ID);
    if I >= 0 then RemoveClientLocked(I);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TKvmServer.ExpireIdleClients;
var
  I, N: Integer;
  NowTick: QWord;
  ExpiredIDs: THttpServerConnectionIDDynArray;
begin
  NowTick := GetTickCount64;
  SetLength(ExpiredIDs, 0);
  EnterCriticalSection(FLock);
  try
    N := 0;
    for I := High(FClients) downto 0 do
      if ((not FClients[I].Authenticated) and (NowTick-FClients[I].LastSeen>KVM_AUTH_TIMEOUT_MS)) or
         (NowTick-FClients[I].LastSeen>KVM_CLIENT_TIMEOUT_MS) or
         FlowTimedOut(FClients[I].Flow, NowTick) then
      begin
        WriteLn('[client] Session expiree ou sans ACK : ', FClients[I].ID);
        SetLength(ExpiredIDs, N + 1);
        ExpiredIDs[N] := FClients[I].ID;
        Inc(N);
        RemoveClientLocked(I); // also releases any held keys/buttons
      end;
  finally
    LeaveCriticalSection(FLock);
  end;
  for I := 0 to High(ExpiredIDs) do
    FSocket.AbortConnection(ExpiredIDs[I]);
end;

procedure TKvmServer.CaptureDemand(var Wanted: array of Boolean; NowTick: QWord;
      out CaptureW, CaptureH, CaptureRate: Integer);
var I, P, W, H, Q, FPS: Integer;
begin
  CaptureW := 0; CaptureH := 0; CaptureRate := 0;
  for P := 0 to High(Wanted) do Wanted[P] := False;
  EnterCriticalSection(FLock);
  try
    for I := 0 to High(FClients) do if FClients[I].Ready then
    begin
      P := FClients[I].Adaptive.Profile;
      ProfileSettings(P, FMaxW, FMaxH, FQuality, FFps, W, H, Q, FPS);
      CaptureW := Max(CaptureW, W); CaptureH := Max(CaptureH, H);
      CaptureRate := Max(CaptureRate, FPS);
      if not FClients[I].Flow.WaitingAck then
        Wanted[P+Ord(FClients[I].H264)*KVM_PROFILE_COUNT] := True;
    end;
  finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmServer.DispatchBatches(Profile: Integer; const Cache: array of RawByteString;
  const Versions: array of Cardinal; const Groups: array of Integer;
  Width, Height: Word;
  CursorValid: Boolean; CursorX, CursorY: Word);
var
  I, J, Index, W, H, Q, FPS: Integer;
  NowTick: QWord;
  Batch: TKvmFlowBatch;
  ClientID: THttpServerConnectionID;
  ClientIDs: THttpServerConnectionIDDynArray;
  HasBatch: Boolean;
  Frames: TWebSocketFrameDynArray;
  procedure Add(const Payload: RawByteString);
  var N: Integer;
  begin
    N := Length(Frames); SetLength(Frames, N + 1);
    Frames[N].opcode := focBinary; Frames[N].content := [];
    Frames[N].tix := 0; Frames[N].payload := Payload;
  end;
begin
  // Snapshot the IDs so a concurrent disconnect cannot shift our array
  // indices and accidentally skip the next viewer in this capture cycle.
  EnterCriticalSection(FLock);
  try
    SetLength(ClientIDs, Length(FClients));
    for I := 0 to High(FClients) do ClientIDs[I] := FClients[I].ID;
  finally
    LeaveCriticalSection(FLock);
  end;
  // The capture worker is the sole caller, so Cache remains immutable while
  // the transport queues each immutable, reference-counted RawByteString.
  for I := 0 to High(ClientIDs) do
  begin
    ClientID := ClientIDs[I];
    EnterCriticalSection(FLock);
    try
      Index := FindClientLocked(ClientID);
      NowTick := GetTickCount64;
      HasBatch := Index >= 0;
      if HasBatch then HasBatch := FDesktopAvailable and FClients[Index].Ready and
        (FClients[Index].Adaptive.Profile+Ord(FClients[Index].H264)*KVM_PROFILE_COUNT = Profile);
      if HasBatch then
      begin
        ProfileSettings(Profile mod KVM_PROFILE_COUNT, FMaxW, FMaxH, FQuality, FFps, W, H, Q, FPS);
        HasBatch := PrepareFlowBatch(FClients[Index].Flow, Cache, Versions, Groups,
          CursorValid, CursorX, CursorY, NowTick, Batch,
          AdaptiveBudget(FClients[Index].Adaptive));
        if HasBatch then FClients[Index].Adaptive.FlightBytes := Batch.PayloadBytes;
      end;
    finally
      LeaveCriticalSection(FLock);
    end;
    if not HasBatch then Continue;
    SetLength(Frames, 0);
    // D is in the same ordered binary stream as S/T/B. The UI must not
    // process desktop-state notifications out of order with JPEGs.
    Add(MakeDesktopState(True,KVM_SESSION_ACTIVE,FDesktopEpoch));
    if Batch.SendScreen then Add(MakeScreen(Width, Height));
    for J := 0 to High(Batch.Indices) do Add(Cache[Batch.Indices[J]]);
    if Batch.SendCursor then Add(MakeCursor(Batch.CursorX, Batch.CursorY, Batch.CursorVisible));
    Add(MakeBatchEnd(Batch.Serial));
    HasBatch:=FSocket.TryQueue(ClientID,Frames);
    FMetrics.Queue(Batch.PayloadBytes+7,HasBatch);
    if not HasBatch then
    begin
      // All-or-nothing: no screen reset or JPEG prefix was queued. This
      // is NOT a viewer NACK and must not count towards its reject limit.
      EnterCriticalSection(FLock);
      try
        Index := FindClientLocked(ClientID);
        if Index >= 0 then RejectFlowBatch(FClients[Index].Flow, Batch.Serial);
      finally LeaveCriticalSection(FLock); end;
    end;
  end;
end;

procedure TKvmServer.ActivateClient(ID: THttpServerConnectionID);
var I: Integer;
begin
  EnterCriticalSection(FLock);
  try I := FindClientLocked(ID); if I >= 0 then FClients[I].Ready := True;
  finally LeaveCriticalSection(FLock); end;
  FWakeCapture.SetEvent;
end;

procedure TKvmServer.NackBatch(ID: THttpServerConnectionID; Serial: Cardinal);
var I, Rejects: Integer; Close, Counted: Boolean;
begin
  Close:=False; Counted:=False; Rejects:=0;
  EnterCriticalSection(FLock);
  try
    I:=FindClientLocked(ID);
    if (I>=0) and RejectFlowBatch(FClients[I].Flow,Serial) then
    begin
      Inc(FClients[I].VideoRejects);
      Rejects:=FClients[I].VideoRejects;
      Counted:=True;
      if Rejects>=3 then begin RemoveClientLocked(I); Close:=True; end;
    end;
  finally LeaveCriticalSection(FLock); end;
  if Counted then
    WriteLn('[video] NACK client ',ID,' lot ',Serial,
      ' rejets consecutifs=',Rejects,' fermeture=',Close);
  if Close then FSocket.AbortConnection(ID);
  FWakeCapture.SetEvent;
end;

procedure TKvmServer.AckBatch(ID: THttpServerConnectionID; Serial: Cardinal);
var I: Integer; NowTick, Elapsed: QWord;
begin
  EnterCriticalSection(FLock);
  try
    I := FindClientLocked(ID);
    if I < 0 then Exit;
    NowTick := GetTickCount64;
    Elapsed := NowTick - FClients[I].Flow.LastSentTick;
    if AcknowledgeFlowBatch(FClients[I].Flow, Serial) then
    begin
      FClients[I].LastSeen := NowTick; FClients[I].VideoRejects := 0;
      FMetrics.Ack(Elapsed);
      if ObserveAck(FClients[I].Adaptive, NowTick, Elapsed,
        FClients[I].Adaptive.FlightBytes, FAdaptive) then
      begin
        InvalidateFlowGeometry(FClients[I].Flow);
        WriteLn('[video] Client ', ID, ' profil ', FClients[I].Adaptive.Profile);
      end;
    end;
  finally LeaveCriticalSection(FLock); end;
  FWakeCapture.SetEvent;
end;

procedure TKvmServer.InvalidateSnapshots(Profile: Integer);
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    for I := 0 to High(FClients) do
      if FClients[I].Adaptive.Profile+Ord(FClients[I].H264)*KVM_PROFILE_COUNT = Profile then InvalidateFlowGeometry(FClients[I].Flow);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TKvmServer.RequestSnapshot(ID: THttpServerConnectionID);
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    I := FindClientLocked(ID);
    if I >= 0 then
      RequestFlowReset(FClients[I].Flow, GetTickCount64);
  finally
    LeaveCriticalSection(FLock);
  end;
  FWakeCapture.SetEvent;
end;

function TKvmServer.AddClient(ID: THttpServerConnectionID; CanControl,H264: Boolean): Boolean;
var I,N,J: Integer;
begin
  Result:=False; EnterCriticalSection(FLock);
  try
    I:=FindClientLocked(ID);
    if (I<0) or FClients[I].Authenticated or (GetTickCount64-FClients[I].LastSeen>KVM_AUTH_TIMEOUT_MS) then Exit;
    N:=0; for J:=0 to High(FClients) do if FClients[J].Authenticated then Inc(N);
    if N>=KVM_MAX_CLIENTS then Exit;
    FClients[I].CanControl:=CanControl; FClients[I].Authenticated:=True;
    FClients[I].H264:=H264 and FCanH264;
    FClients[I].LastSeen:=GetTickCount64; Result:=True;
  finally LeaveCriticalSection(FLock); end;
end;

function TKvmServer.TouchClient(ID: THttpServerConnectionID): Boolean;
var I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    I:=FindClientLocked(ID); Result:=I>=0;
    if Result then Result:=FClients[I].Ready and FClients[I].Authenticated;
    if Result then FClients[I].LastSeen:=GetTickCount64;
  finally LeaveCriticalSection(FLock); end;
end;

function TKvmServer.AcceptPacket(ID: THttpServerConnectionID; Bytes: Integer): Boolean;
var I: Integer; NowTick: QWord;
begin
  Result:=False; NowTick:=GetTickCount64;
  EnterCriticalSection(FLock);
  try
    I:=FindClientLocked(ID); if I<0 then Exit;
    if not FClients[I].Ready or not FClients[I].Authenticated then Exit;
    Result:=SpendRate(FClients[I].InputRate,1,NowTick) and
      SpendRate(FClients[I].ByteRate,Bytes,NowTick);
  finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmServer.BadPacket(Sender: TWebSocketProcess);
var I, BadFrames: Integer; Close: Boolean;
begin
  Close:=True; BadFrames:=0; FMetrics.SecurityReject;
  EnterCriticalSection(FLock);
  try
    I:=FindClientLocked(Sender.Protocol.ConnectionID);
    if I>=0 then
    begin
      Inc(FClients[I].BadFrames);
      BadFrames:=FClients[I].BadFrames;
      Close:=BadFrames>=3;
    end;
  finally LeaveCriticalSection(FLock); end;
  WriteLn('[ws] Trame invalide, client ',Sender.Protocol.ConnectionID,
    ' erreurs=',BadFrames,' fermeture=',Close);
  if Close then FSocket.AbortConnection(Sender.Protocol.ConnectionID);
end;

function TKvmServer.AllowUpgrade(Protocol: TWebSocketProtocol): Integer;
var I: Integer; NowTick: QWord;
begin
  Result:=429; NowTick:=GetTickCount64;
  EnterCriticalSection(FLock);
  try
    if (Protocol.UpgradeUri<>KVM_WS_ROUTE) or
       (Length(FClients)>=KVM_MAX_CONNECTIONS) or
       not SpendRate(FUpgradeRate,1,NowTick) then begin FMetrics.SecurityReject; Exit; end;
    if FindClientLocked(Protocol.ConnectionID)>=0 then Exit;
    I:=Length(FClients); SetLength(FClients,I+1);
    FClients[I].ID:=Protocol.ConnectionID; FClients[I].LastSeen:=NowTick;
    FClients[I].DesktopNoticePending:=True;
    InitFlow(FClients[I].Flow); InitAdaptive(FClients[I].Adaptive);
    InitRate(FClients[I].InputRate,1000,500,NowTick);
    InitRate(FClients[I].ByteRate,65536,32768,NowTick);
    InitRate(FClients[I].TextRate,512,128,NowTick);
    InitRate(FClients[I].ClipboardRate,8,6,NowTick);
    InitRate(FClients[I].ClipboardBytes,2*(KVM_CLIP_MAX_BYTES+32),
      4*(KVM_CLIP_MAX_BYTES+32),NowTick);
    Result:=200;
  finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmServer.ProtocolClosed(Protocol: TWebSocketProtocol);
begin
  // Called for both normal and abnormal closure; no misleading attribution.
  WriteLn('[ws] Connexion terminee : ',Protocol.ConnectionID);
  RemoveClient(Protocol.ConnectionID);
end;

function TKvmServer.AcquireControl(ID: THttpServerConnectionID): Boolean;
var
  I: Integer;
begin
  Result := False;
  EnterCriticalSection(FLock);
  try
    I := FindClientLocked(ID);
    if (I < 0) or not FClients[I].CanControl or not FDesktopAvailable or not DesktopSessionAvailable or PendingInputReleasesLocked then Exit;
    if (FController = 0) or (FController = ID) then
    begin
      FController := ID;
      WriteLn('[controle] Accorde a : ', ID);
      Result := True;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TKvmServer.RelinquishControl(ID: THttpServerConnectionID;
  KeepOwner: Boolean);
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    if FController <> ID then Exit;
    I := FindClientLocked(ID);
    if I >= 0 then ReleaseInputsLocked(FClients[I]);
    if not KeepOwner then
    begin
      FController := 0;
      WriteLn('[controle] Libere par : ', ID);
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TKvmServer.HandleMouse(ID: THttpServerConnectionID;
  Action, Button: Byte; X, Y: Word);
var
  I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    if (FController <> ID) or not FDesktopAvailable or not DesktopSessionAvailable then Exit;
    I := FindClientLocked(ID);
    if I < 0 then Exit;
    FClients[I].MouseX := X;
    FClients[I].MouseY := Y;
    if Action <> 0 then
    begin
      if (Button < 1) or (Button > 3) then Exit;
      // Discard duplicate downs/ups, e.g. after an unclean reconnect.
      if FClients[I].Buttons[Button] = (Action = 1) then Exit;
      FClients[I].Buttons[Button] := Action = 1;
    end;
    try InjectMouse(Action, Button, X, Y);
    except
      if Action = 2 then
      begin FPendingButtonRelease[Button] := True; FReleaseX := X; FReleaseY := Y; end;
      raise;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TKvmServer.HandleKey(ID: THttpServerConnectionID;
  Pressed: Boolean; VKey: Word);
var
  I: Integer;
begin
  if VKey > 255 then Exit;
  EnterCriticalSection(FLock);
  try
    if (FController <> ID) or not FDesktopAvailable or not DesktopSessionAvailable then Exit;
    I := FindClientLocked(ID);
    if I < 0 then Exit;
    // Key repeats are forwarded, but one eventual release is enough.
    if (not Pressed) and (not FClients[I].Keys[VKey]) then Exit;
    FClients[I].Keys[VKey] := Pressed;
    try InjectKey(Pressed, VKey);
    except
      if not Pressed then FPendingKeyRelease[VKey] := True;
      raise;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TKvmServer.HandleText(ID: THttpServerConnectionID; Serial: Cardinal;
  const Packet: RawByteString; const Points: TKvmCodePoints): RawByteString;
const Modifiers: array[0..10] of Byte = ($10,$11,$12,$5b,$5c,$a0,$a1,$a2,$a3,$a4,$a5);
var I,K,P: Integer; Started: QWord; Applied: Word; Status: Byte;
  Released: array[0..10] of Boolean; RestoreFailed: Boolean;
begin
  Result:=MakeInputReceipt(Serial,KVM_INPUT_DENIED,0);
  EnterCriticalSection(FLock);
  try
    I:=FindClientLocked(ID); if I<0 then Exit;
    if Serial=FClients[I].LastTextSerial then
    begin
      if Packet=FClients[I].LastTextPacket then Result:=FClients[I].LastTextReceipt
      else Result:=MakeInputReceipt(Serial,KVM_INPUT_STALE,0);
      Exit;
    end;
    if Serial<>NextSerial(FClients[I].LastTextSerial) then
      Exit(MakeInputReceipt(Serial,KVM_INPUT_STALE,0));
    Applied:=0; Status:=KVM_INPUT_DENIED;
    FillChar(Released,SizeOf(Released),0);
    // Reserve the serial before injection. Repeating a failed/partial commit
    // must not repeat the prefix already submitted to the OS.
    FClients[I].LastTextSerial:=Serial; FClients[I].LastTextPacket:=Packet;
    FClients[I].LastTextReceipt:=Result;
    if (FController=ID) and FDesktopAvailable and DesktopSessionAvailable and
       SpendRate(FClients[I].TextRate,Length(Points),GetTickCount64) then
    begin
      Started:=GetTickCount64; Status:=KVM_INPUT_OK; RestoreFailed:=False;
      try
        try
          for K:=0 to High(Modifiers) do
            if FClients[I].Keys[Modifiers[K]] then
            begin InjectKey(False,Modifiers[K]); Released[K]:=True; end;
          for P:=0 to High(Points) do
          begin
            if (GetTickCount64-Started>500) or not DesktopSessionAvailable then
              raise Exception.Create('Saisie suspendue ou budget temps depasse');
            InjectText(Points[P]); Inc(Applied);
          end;
        finally
          for K:=0 to High(Modifiers) do if Released[K] then
          begin
            if DesktopSessionAvailable then
            begin
              try InjectKey(True,Modifiers[K]);
              except
                RestoreFailed:=True; FClients[I].Keys[Modifiers[K]]:=False;
                FPendingKeyRelease[Modifiers[K]]:=True;
              end;
            end
            else begin RestoreFailed:=True; FClients[I].Keys[Modifiers[K]]:=False; end;
          end;
        end;
        if RestoreFailed then raise Exception.Create('Restauration modificateurs incomplete');
      except on E: Exception do
        begin
          // An OS call can fail after partial injection; counts refer only
          // to fully submitted Unicode scalars, not verified application text.
          if Applied>0 then Status:=KVM_INPUT_PARTIAL else Status:=KVM_INPUT_FAILED;
          WriteLn('[input] Commit interrompu (contenu non journalise)');
        end;
      end;
    end;
    Result:=MakeInputReceipt(Serial,Status,Applied);
    FClients[I].LastTextReceipt:=Result;
  finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmServer.HandleWheel(ID: THttpServerConnectionID;
  Notches: SmallInt);
begin
  EnterCriticalSection(FLock);
  try
    if FDesktopAvailable and DesktopSessionAvailable and (FController = ID) and (FindClientLocked(ID) >= 0) then
      InjectWheel(Notches);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TKvmServer.SendText(Sender: TWebSocketProcess; const Msg: RawByteString);
begin
  if not FSocket.TryQueueText(Sender.Protocol.ConnectionID,Msg) then
    FSocket.AbortConnection(Sender.Protocol.ConnectionID);
end;

procedure TKvmServer.SetDesktopAvailable(Value: Boolean);
var I: Integer; Reason: Byte; GuardEpoch: Cardinal;
begin
  SessionGuardState(Reason,GuardEpoch);
  Value:=Value and (Reason=KVM_SESSION_ACTIVE);
  if not Value and (Reason=KVM_SESSION_ACTIVE) then Reason:=KVM_SESSION_CAPTURE_LOST;
  EnterCriticalSection(FLock);
  try
    if Value then RetryInputReleasesLocked;
    if (FDesktopAvailable <> Value) or (FDesktopReason<>Reason) then
    begin
      FDesktopAvailable:=Value; FDesktopReason:=Reason; FDesktopEpoch:=NextSerial(FDesktopEpoch);
      if not Value then
      begin
        I := FindClientLocked(FController);
        if I >= 0 then ReleaseInputsLocked(FClients[I]);
        FController := 0; // control must be explicitly requested again
      end;
      for I := 0 to High(FClients) do
      begin
        FClients[I].DesktopNoticePending := True;
        InvalidateFlowGeometry(FClients[I].Flow);
      end;
    end;
  finally LeaveCriticalSection(FLock); end;
  PublishDesktopState;
end;

procedure TKvmServer.PublishDesktopState;
var I, Index: Integer; Frames: TWebSocketFrameDynArray;
  IDs: THttpServerConnectionIDDynArray; Available: Boolean; Reason: Byte; Epoch: Cardinal;
begin
  SetLength(Frames,1); Frames[0].opcode := focBinary;
  Frames[0].content := []; Frames[0].tix := 0;
  EnterCriticalSection(FLock);
  try
    Available := FDesktopAvailable; Reason:=FDesktopReason; Epoch:=FDesktopEpoch; SetLength(IDs,0);
    for I := 0 to High(FClients) do
      if FClients[I].Ready and FClients[I].DesktopNoticePending then
      begin SetLength(IDs,Length(IDs)+1); IDs[High(IDs)] := FClients[I].ID; end;
  finally LeaveCriticalSection(FLock); end;
  Frames[0].payload := MakeDesktopState(Available,Reason,Epoch);
  for I := 0 to High(IDs) do
    if FSocket.TryQueue(IDs[I],Frames) then
    begin
      EnterCriticalSection(FLock);
      try
        Index := FindClientLocked(IDs[I]);
        if (Index >= 0) and (FDesktopAvailable = Available) and (FDesktopEpoch=Epoch) then
          FClients[Index].DesktopNoticePending := False;
      finally LeaveCriticalSection(FLock); end;
    end;
end;

function TKvmServer.ClipboardAllowed(ID: QWord; Epoch: Cardinal): Boolean;
var I: Integer;
begin
  EnterCriticalSection(FLock);
  try
    I:=FindClientLocked(THttpServerConnectionID(ID));
    Result:=False;
    if I<0 then Exit;
    Result:=FClients[I].Ready and FClients[I].Authenticated and FClients[I].CanControl
      and (FController=THttpServerConnectionID(ID)) and FDesktopAvailable
      and (FDesktopEpoch=Epoch) and DesktopSessionAvailable;
  finally LeaveCriticalSection(FLock); end;
end;

function TKvmServer.ClipboardReply(ID: QWord; const Reply: TKvmClipReply): Boolean;
var R: TKvmClipReply; Frames: TWebSocketFrameDynArray;
begin
  R:=Reply;
  // Recheck immediately before handing any clipboard contents to transport.
  if not ClipboardAllowed(ID,R.Epoch) then
  begin R.Text:=''; R.HasText:=False; R.WriteResult:=crDenied; R.ReadResult:=crDenied; end;
  SetLength(Frames,1); Frames[0].opcode:=focBinary;
  Frames[0].content:=[]; Frames[0].tix:=0; Frames[0].payload:=MakeClipReply(R);
  Result:=(FSocket<>nil) and FSocket.TryQueue(THttpServerConnectionID(ID),Frames);
  if not Result and (FSocket<>nil) then FSocket.AbortConnection(THttpServerConnectionID(ID));
end;

procedure TKvmServer.HandleClipboardFrame(Sender: TWebSocketProcess; const Packet: RawByteString);
var Req: TKvmClipRequest; R: TKvmClipReply; I: Integer;
  ID: THttpServerConnectionID; Valid: Boolean; NowTick: QWord;
begin
  ID:=Sender.Protocol.ConnectionID;
  if not ReadClipRequest(Packet,Req) then begin BadPacket(Sender); Exit; end;
  NowTick:=GetTickCount64; Valid:=False;
  EnterCriticalSection(FLock);
  try
    I:=FindClientLocked(ID);
    if (I>=0) and FClients[I].Authenticated and FClients[I].Ready then
    begin
      Valid:=(Req.Serial=NextSerial(FClients[I].LastClipboardSerial)) and
        SpendRate(FClients[I].ClipboardRate,1,NowTick) and
        SpendRate(FClients[I].ClipboardBytes,Length(Packet),NowTick);
      if Valid then
      begin FClients[I].LastClipboardSerial:=Req.Serial; FClients[I].LastSeen:=NowTick; end;
    end;
  finally LeaveCriticalSection(FLock); end;
  if not Valid then
  begin FMetrics.SecurityReject; FSocket.AbortConnection(ID); Exit; end;
  R.Epoch:=Req.Epoch; R.Serial:=Req.Serial; R.HasText:=False; R.Text:='';
  R.WriteResult:=crSkip; R.ReadResult:=crSkip;
  if not ClipboardAllowed(QWord(ID),Req.Epoch) then
  begin R.WriteResult:=crDenied; R.ReadResult:=crDenied; ClipboardReply(QWord(ID),R); Exit; end;
  EnterCriticalSection(FLock);
  try Valid:=(FClipboardWorker<>nil) and FClipboardWorker.Enqueue(QWord(ID),Req);
  finally LeaveCriticalSection(FLock); end;
  if Valid then Exit;
  if (Req.Flags and KVM_CLIP_WRITE)<>0 then R.WriteResult:=crBusy;
  if (Req.Flags and KVM_CLIP_READ)<>0 then R.ReadResult:=crBusy;
  ClipboardReply(QWord(ID),R);
end;

procedure TKvmServer.HandleFrame(Sender: TWebSocketProcess; const Frame: TWebSocketFrame);
var
  ID: THttpServerConnectionID; Action,Button: Byte; X,Y,VKey: Word;
  Pressed,ControlRight,WantH264,Valid: Boolean; Wheel: SmallInt;
  Serial: Cardinal; Points: TKvmCodePoints; Token,Caps,Receipt: RawByteString;
  Split: Integer; Reply: TWebSocketFrameDynArray;
begin
  ID:=Sender.Protocol.ConnectionID;
  case Frame.opcode of
    focConnectionClose: begin RemoveClient(ID); Exit; end;
    focText:
    begin
      if (Length(Frame.payload)>272) or (Copy(Frame.payload,1,5)<>'AUTH ') then
      begin
        WriteLn('[auth] Requete invalide du client ',ID,' (longueur=',Length(Frame.payload),')');
        BadPacket(Sender); Exit;
      end;
      Token:=Copy(Frame.payload,6,MaxInt); Split:=Pos(' ',Token);
      if Split=0 then begin BadPacket(Sender); Exit; end;
      Caps:=Copy(Token,Split+1,MaxInt); SetLength(Token,Split-1);
      if (Caps<>'jpeg') and (Caps<>'h264') then begin BadPacket(Sender); Exit; end;
      WantH264:=Caps='h264';
      ControlRight:=FAllowControl and SecureTokenEqual(Token,FToken);
      if ControlRight or ((FViewToken<>'') and SecureTokenEqual(Token,FViewToken)) or
         ((not FAllowControl) and SecureTokenEqual(Token,FToken)) then
      begin
        if AddClient(ID,ControlRight,WantH264) then
        begin
          if ControlRight then SendText(Sender,'OK CTRL') else SendText(Sender,'OK VIEW');
          ActivateClient(ID); WriteLn('[client] Authentifie : ',ID,' controle=',ControlRight);
        end
        else begin FMetrics.SecurityReject; FSocket.AbortConnection(ID); end;
      end
      else
      begin
        FMetrics.SecurityReject;
        WriteLn('[auth] Refuse client ',ID,' (jeton/capacite non acceptes ; secret non affiche)');
        FSocket.AbortConnection(ID);
      end;
    end;
    focBinary:
    begin
      if (Length(Frame.payload)>0) and (Frame.payload[1]='c') then
      begin HandleClipboardFrame(Sender,Frame.payload); Exit; end;
      if (Length(Frame.payload)=0) or (Length(Frame.payload)>KVM_MAX_TEXT_BYTES+5) or
         not AcceptPacket(ID,Length(Frame.payload)) then
      begin
        FMetrics.SecurityReject;
        WriteLn('[ws] Trame refusee (quota, taille ou session) client ',ID,
          ' longueur=',Length(Frame.payload));
        FSocket.AbortConnection(ID); Exit;
      end;
      Valid:=False;
      case Frame.payload[1] of
        'P','R','G','L','Z': Valid:=Length(Frame.payload)=1;
        'A': Valid:=ReadBatchAck(Frame.payload,Serial);
        'N': Valid:=ReadBatchNack(Frame.payload,Serial);
        'M': Valid:=ReadMouse(Frame.payload,Action,Button,X,Y);
        'K': Valid:=ReadKey(Frame.payload,Pressed,VKey);
        'W': Valid:=ReadWheel(Frame.payload,Wheel);
        'U': Valid:=ReadTextRequest(Frame.payload,Serial,Points);
      end;
      if not Valid then begin BadPacket(Sender); Exit; end;
      if not TouchClient(ID) then
      begin
        WriteLn('[ws] Client absent ou non pret : ',ID);
        FSocket.AbortConnection(ID); Exit;
      end;
      try
        case Frame.payload[1] of
          'P': Exit;
          'A': AckBatch(ID,Serial);
          'N': NackBatch(ID,Serial);
          'R': RequestSnapshot(ID);
          'G': if AcquireControl(ID) then SendText(Sender,'CTRL GRANTED') else SendText(Sender,'CTRL BUSY');
          'L': begin RelinquishControl(ID,False); SendText(Sender,'CTRL RELEASED'); end;
          'Z': RelinquishControl(ID,True);
          'M': HandleMouse(ID,Action,Button,X,Y);
          'K': HandleKey(ID,Pressed,VKey);
          'W': HandleWheel(ID,Wheel);
          'U':
          begin
            Receipt:=HandleText(ID,Serial,Frame.payload,Points);
            SetLength(Reply,1); Reply[0].opcode:=focBinary; Reply[0].content:=[];
            Reply[0].tix:=0; Reply[0].payload:=Receipt;
            if not FSocket.TryQueue(ID,Reply) then FSocket.AbortConnection(ID);
          end;
        end;
      except on E: Exception do
        begin WriteLn('[input] Echec de commande (contenu non journalise)'); SendText(Sender,'ERR INPUT'); end;
      end;
    end;
  end;
end;
end.
