unit kvm_view_form;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, ExtCtrls, StdCtrls,
  Dialogs, Types, LCLType, Math, GraphType,
  mormot.core.base, mormot.net.sock, mormot.net.client,
  mormot.net.ws.core, mormot.net.ws.client,
  kvm_wire, kvm_cli, kvm_jpeg_guard, kvm_extwire, kvm_codec, kvm_frame,
  kvm_rgb_bitmap, kvm_input_queue, kvm_security, kvm_tls_policy,
  kvm_video_worker, kvm_surface, kvm_client_log,
  kvm_clipboard_wire, kvm_clipboard_native, kvm_clipboard_client_worker;

type
  TKvmViewForm = class(TForm)
  private
    FTop: TPanel; // Panneau de commandes flottant, sans espace reserve
    FMenuButton: TButton; // Poignee discrete, visible uniquement en session
    FHost, FPort, FToken: TEdit;
    FConnect, FDisconnect, FRefresh, FText: TButton;
    FControl, FRemoteKeys: TCheckBox;
    FClipToRemote, FClipFromRemote: TCheckBox;
    FClipboardChanging: Boolean;
    FClipboardWorker: TKvmClipboardClientWorker;
    FAllowInsecure, FEnableH264, FTransportFault: Boolean;
    FInputs: TKvmInputQueue;
    FDesktopEpoch: Cardinal;
    FTls: TCheckBox;
    FTlsCaFile: string;
    FStatus: TLabel;
    FView: TPaintBox;
    FTimer: TTimer;
    FBitmap: TBitmap;
    FDecoder: TKvmVideoWorker;
    FFront: TKvmPresentation;
    FUseRawImage, FWorkerFault, FPolling: Boolean;
    FRawImportMs, FPaintMs, FStatsTick: QWord;
    FPaintCount, FPresentCount: Cardinal;
    FSocket: THttpClientWebSockets;
    FLock: TRTLCriticalSection;
    FPendingTexts: array of string;
    FCursorVisible: Boolean;
    FCursorX, FCursorY: Word;
    FControlGranted: Boolean;
    FLastHeartbeat: QWord;
    FLastShift: TShiftState;
    FSuppressedKeys, FForwardedKeys: array[0..255] of Boolean;
    FMouseButtons: Byte;
    FWheelRemainder: Integer;
    FDesktopPaused: Boolean;
    FAuthorized, FRemoteControl, FKeyboardFocus, FClosing: Boolean;
    FLastMouseTick: QWord;
    FPendingMouseMove: Boolean;
    FPendingMouseX, FPendingMouseY: Word;
    FAutoConnect: Boolean;
    FAutoControl, FAutoControlPending: Boolean;

    procedure ClipboardClick(Sender: TObject);
    procedure SyncClipboardOptions;
    procedure StopClipboardWorker;
    procedure ConnectClick(Sender: TObject);
    procedure MenuClick(Sender: TObject);
    procedure WindowResized(Sender: TObject);
    procedure LayoutOverlay;
    procedure SetCommandsVisible(AVisible: Boolean);
    procedure DisconnectClick(Sender: TObject);
    procedure ControlClick(Sender: TObject);
    procedure TryAutoRequestControl;
    procedure WindowDeactivated(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure TextClick(Sender: TObject);
    procedure ResetLocalInputs;
    procedure ApplyDesktopState(Available: Boolean; Reason: Byte; Epoch: Cardinal);
    procedure KeyboardModeClick(Sender: TObject);
    procedure TransmitPacket(const Payload: RawByteString);
    procedure DrainInputs;
    procedure StopVideoWorker;
    procedure DecodeReply(const Payload: RawByteString);
    procedure PresentSnapshot(const Snapshot: TKvmPresentation);
    procedure IncomingFrame(Sender: TWebSocketProcess;
      const Frame: TWebSocketFrame);
    procedure PollTimer(Sender: TObject);
    procedure PaintView(Sender: TObject);
    procedure ViewMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Integer);
    procedure ViewMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ViewMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ViewMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure RemoteUTF8KeyPress(Sender: TObject; var UTF8Key: TUTF8Char);
    procedure RemoteKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure RemoteKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);

    procedure SendPacket(const Payload: RawByteString);
    function ControlAllowed: Boolean;
    function GetVideoRect: TRect;
    function ToNormalized(X, Y: Integer; out NX, NY: Word): Boolean;
    function MouseButtonCode(Button: TMouseButton): Byte;
    procedure SetStatus(const TextA: string);
    procedure CloseSocket;
  public
    procedure ApplyOptions(const Options: TKvmClientOptions);
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

{$IFDEF WINDOWS}
uses kvm_present_win;
{$ENDIF}

const
  // 12 ms cap: mouse moves are coalesced by the UI instead of discarded.
  KVM_MOUSE_INTERVAL_MS = 12;

constructor TKvmViewForm.Create(AOwner: TComponent);
var
  L: TLabel;
begin
  inherited CreateNew(AOwner, 1);
  InitCriticalSection(FLock);
  Caption := 'MeshKVM v9 | F8 : commandes';
  Width := 1080;
  Height := 730;
  Position := poScreenCenter;
  Color := clBlack;
  KeyPreview := True;
  OnUTF8KeyPress := @RemoteUTF8KeyPress;
  OnKeyDown := @RemoteKeyDown;
  OnKeyUp := @RemoteKeyUp;
  OnDeactivate := @WindowDeactivated;
  OnResize := @WindowResized;

  FBitmap := TBitmap.Create;
  FUseRawImage := GetEnvironmentVariable('MESHKVM_RAW_IMAGE') <> '0';
  FStatsTick := GetTickCount64;
  FInputs := TKvmInputQueue.Create; FEnableH264:=True;
  FSocket := nil;
  FClosing := False;
  FAuthorized := False;
  FRemoteControl := False;
  FControlGranted := False;
  FLastHeartbeat := 0;
  FLastShift := [];
  FillChar(FSuppressedKeys, SizeOf(FSuppressedKeys), 0);
  FCursorVisible := False;
  FKeyboardFocus := False;
  FAutoConnect := False;
  FAutoControl := False; FAutoControlPending := False;
  FDesktopPaused := True;
  WebSocketsMaxFrameMB := 4;

  FTop := TPanel.Create(Self);
  FTop.Parent := Self;
  // Le panneau NE doit pas changer la geometrie du bureau distant.
  // alTop reduirait la surface du bureau au lieu de superposer les commandes.
  FTop.Align := alNone;
  FTop.SetBounds(0, 0, 1020, 186);
  FTop.BevelOuter := bvNone;
  FTop.Color := clBtnFace;

  L := TLabel.Create(Self);
  L.Parent := FTop;
  L.SetBounds(12, 6, 95, 17);
  L.Caption := 'Hote / IP';

  FHost := TEdit.Create(Self);
  FHost.Parent := FTop;
  FHost.SetBounds(12, 25, 170, 26);
  FHost.Text := '127.0.0.1';

  L := TLabel.Create(Self);
  L.Parent := FTop;
  L.SetBounds(194, 6, 70, 17);
  L.Caption := 'Port';

  FPort := TEdit.Create(Self);
  FPort.Parent := FTop;
  FPort.SetBounds(194, 25, 65, 26);
  FPort.Text := '7900';

  L := TLabel.Create(Self);
  L.Parent := FTop;
  L.SetBounds(271, 6, 140, 17);
  L.Caption := 'Jeton de connexion';

  FToken := TEdit.Create(Self);
  FToken.Parent := FTop;
  FToken.SetBounds(271, 25, 220, 26);
  FToken.PasswordChar := '*';

  FTls := TCheckBox.Create(Self);
  FTls.Parent := FTop;
  FTls.SetBounds(735, 6, 125, 18);
  FTls.Caption := 'WSS / TLS';
  FTls.Checked := False;

  FConnect := TButton.Create(Self);
  FConnect.Parent := FTop;
  FConnect.SetBounds(503, 23, 102, 29);
  FConnect.Caption := 'Connecter';
  FConnect.OnClick := @ConnectClick;

  FDisconnect := TButton.Create(Self);
  FDisconnect.Parent := FTop;
  FDisconnect.SetBounds(613, 23, 110, 29);
  FDisconnect.Caption := 'Deconnecter';
  FDisconnect.Enabled := False;
  FDisconnect.OnClick := @DisconnectClick;

  FControl := TCheckBox.Create(Self);
  FControl.Parent := FTop;
  FControl.SetBounds(735, 28, 240, 24);
  FControl.Caption := 'Autoriser mon controle';
  FControl.Enabled := False;
  FControl.Checked := False;
  FControl.OnClick := @ControlClick;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FTop;
  FStatus.SetBounds(12, 66, 730, 19);
  FStatus.Caption := 'Non connecte | affichage adapte a la fenetre';

  FRefresh := TButton.Create(Self);
  FRefresh.Parent := FTop;
  FRefresh.SetBounds(894, 61, 120, 28);
  FRefresh.Caption := 'Rafraichir';
  FRefresh.Enabled := False;
  FRefresh.OnClick := @RefreshClick;

  FText := TButton.Create(Self);
  FText.Parent := FTop; FText.SetBounds(756,61,130,28);
  FText.Caption := 'Texte / IME'; FText.Enabled := False;
  FText.OnClick := @TextClick;

  FRemoteKeys:=TCheckBox.Create(Self);
  FRemoteKeys.Parent:=FTop; FRemoteKeys.SetBounds(12,96,640,22);
  FRemoteKeys.Caption:='Touches / IME du bureau distant (sinon texte compose localement)';
  FRemoteKeys.OnClick:=@KeyboardModeClick;

  FClipToRemote:=TCheckBox.Create(Self);
  FClipToRemote.Parent:=FTop; FClipToRemote.SetBounds(12,126,470,24);
  FClipToRemote.Caption:='Mon presse-papiers -> distant';
  FClipToRemote.Checked:=False; FClipToRemote.Enabled:=False;
  FClipToRemote.Hint:='Synchroniser le texte courant puis les nouvelles copies (64 Kio max). Controle requis.';
  FClipToRemote.ShowHint:=True; FClipToRemote.OnClick:=@ClipboardClick;
  FClipFromRemote:=TCheckBox.Create(Self);
  FClipFromRemote.Parent:=FTop; FClipFromRemote.SetBounds(510,126,490,24);
  FClipFromRemote.Caption:='Distant -> mon presse-papiers';
  FClipFromRemote.Checked:=False; FClipFromRemote.Enabled:=False;
  FClipFromRemote.Hint:='Autoriser le bureau distant a remplacer mon presse-papiers texte. Controle requis.';
  FClipFromRemote.ShowHint:=True; FClipFromRemote.OnClick:=@ClipboardClick;
  L:=TLabel.Create(Self); L.Parent:=FTop; L.SetBounds(12,156,980,20);
  L.Caption:='Presse-papiers : texte Unicode uniquement. Deux sens independants, desactives a chaque connexion.';


  FView := TPaintBox.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.OnPaint := @PaintView;
  FView.OnMouseMove := @ViewMouseMove;
  FView.OnMouseDown := @ViewMouseDown;
  FView.OnMouseUp := @ViewMouseUp;
  FView.OnMouseWheel := @ViewMouseWheel;

  // Bouton tres discret, toujours accessible sans intercepter le clic droit distant.
  // F8 est egalement intercepte localement avant tout envoi de touche.
  FMenuButton := TButton.Create(Self);
  FMenuButton.Parent := Self;
  FMenuButton.SetBounds(0, 8, 30, 28);
  FMenuButton.Caption := '...';
  FMenuButton.Hint := 'Afficher/masquer les commandes (F8)';
  FMenuButton.ShowHint := True;
  FMenuButton.Visible := False;
  FMenuButton.OnClick := @MenuClick;
  LayoutOverlay;
  FTop.BringToFront;
  FMenuButton.BringToFront;
  ResetLocalInputs;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 10; // react sooner to complete batches and input ACKs
  FTimer.OnTimer := @PollTimer;
  FTimer.Enabled := True;
end;

procedure TKvmViewForm.ApplyOptions(const Options: TKvmClientOptions);
begin
  FHost.Text := Options.Host;
  FPort.Text := IntToStr(Options.Port);
  FToken.Text := Options.Token;
  FAutoConnect := Options.AutoConnect;
  FAutoControl := Options.AutoControl;
  FAutoControlPending := False; // A fresh session arms this after ConnectClick.
  if Options.Maximized then WindowState := wsMaximized
  else WindowState := wsNormal;
  FTls.Checked := Options.TLS;
  FTlsCaFile := Options.TLSCA;
  FAllowInsecure:=Options.AllowInsecure; FEnableH264:=Options.H264;
  FRemoteKeys.Checked:=Options.Keyboard='remote';
end;

destructor TKvmViewForm.Destroy;
begin
  FClosing := True;
  if FTimer<>nil then FTimer.Enabled:=False;
  if FView<>nil then CloseSocket
  else begin StopClipboardWorker; StopVideoWorker; FreeAndNil(FSocket); end;
  FBitmap.Free; FInputs.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

procedure TKvmViewForm.SetStatus(const TextA: string);
begin
  // Le panneau est cache pendant la session : le statut reste lisible dans le titre.
  if FStatus.Caption <> TextA then
    KvmClientLog('[client-status] ' + TextA);
  Caption := 'MeshKVM | ' + Copy(TextA, 1, 90) + ' | F8 : commandes';
  FStatus.Caption := TextA;
  FStatus.Hint := TextA + LineEnding + 'Journal : ' + KvmClientLogPath;
  FStatus.ShowHint := True;
end;

procedure TKvmViewForm.LayoutOverlay;
begin
  if (FTop = nil) or (FMenuButton = nil) then Exit;
  FTop.Left := Max(0, (ClientWidth - FTop.Width) div 2);
  FTop.Top := 0;
  FMenuButton.Left := Max(0, ClientWidth - FMenuButton.Width - 8);
  FMenuButton.Top := 8;
end;

procedure TKvmViewForm.WindowResized(Sender: TObject);
begin
  LayoutOverlay;
end;

procedure TKvmViewForm.SetCommandsVisible(AVisible: Boolean);
begin
  if AVisible and not FTop.Visible then
  begin
    // Passage aux commandes locales : liberer les touches/boutons distants.
    if FAuthorized and FControlGranted then SendPacket('Z');
    ResetLocalInputs;
  end;
  FTop.Visible := AVisible;
  FMenuButton.Visible := FAuthorized;
  if AVisible then FMenuButton.Caption := 'X'
  else FMenuButton.Caption := '...';
  LayoutOverlay;
  if AVisible then FTop.BringToFront;
  if FMenuButton.Visible then FMenuButton.BringToFront;
  if not AVisible then
  begin
    // Ne pas laisser le focus sur le champ du token qui devient invisible.
    ActiveControl := nil;
    FKeyboardFocus := False; // Un clic dans l'image restaure la saisie distante.
    FView.Invalidate;
  end;
end;

procedure TKvmViewForm.MenuClick(Sender: TObject);
begin
  SetCommandsVisible(not FTop.Visible);
end;

procedure TKvmViewForm.StopClipboardWorker;
var Worker: TKvmClipboardClientWorker;
begin
  EnterCriticalSection(FLock);
  try Worker:=FClipboardWorker; FClipboardWorker:=nil;
  finally LeaveCriticalSection(FLock); end;
  if Worker<>nil then begin Worker.Stop; Worker.Free; end;
end;

procedure TKvmViewForm.SyncClipboardOptions;
var Allowed: Boolean; Mask: Byte;
begin
  if (FClipToRemote=nil) or (FClipFromRemote=nil) then Exit;
  Allowed:=ControlAllowed and (FClipboardWorker<>nil);
  FClipboardChanging:=True;
  try
    FClipToRemote.Enabled:=Allowed; FClipFromRemote.Enabled:=Allowed;
    if not Allowed then
    begin FClipToRemote.Checked:=False; FClipFromRemote.Checked:=False; end;
  finally FClipboardChanging:=False; end;
  Mask:=0;
  if Allowed and FClipToRemote.Checked then Mask:=Mask or KVM_CLIP_WRITE;
  if Allowed and FClipFromRemote.Checked then Mask:=Mask or KVM_CLIP_READ;
  if FClipboardWorker<>nil then FClipboardWorker.Configure(Mask,FDesktopEpoch);
end;

procedure TKvmViewForm.ClipboardClick(Sender: TObject);
begin
  if FClipboardChanging then Exit;
  SyncClipboardOptions;
  if not ControlAllowed then Exit;
  SetStatus('Presse-papiers : local -> distant='+BoolToStr(FClipToRemote.Checked,True)+
    ' ; distant -> local='+BoolToStr(FClipFromRemote.Checked,True));
end;

procedure TKvmViewForm.StopVideoWorker;
var Worker: TKvmVideoWorker;
begin
  // Detach before joining: IncomingFrame cannot enqueue into a freed worker.
  EnterCriticalSection(FLock);
  try Worker:=FDecoder; FDecoder:=nil;
  finally LeaveCriticalSection(FLock); end;
  if Worker<>nil then begin Worker.Stop; Worker.Free; end;
end;

procedure TKvmViewForm.DecodeReply(const Payload: RawByteString);
var Frame: TWebSocketFrame;
begin
  // Called by video/clipboard workers. CloseSocket joins BOTH before freeing
  // FSocket; mORMot2 SendFrame serializes writes with its own output lock.
  if (FSocket=nil) or (FSocket.WebSockets=nil) then Exit;
  Frame.opcode:=focBinary; Frame.content:=[]; Frame.tix:=0;
  Frame.payload:=Copy(Payload,1,Length(Payload));
  try
    if FSocket.WebSockets.SendFrame(Frame) then Exit;
  except end;
  EnterCriticalSection(FLock);
  try FWorkerFault:=True; finally LeaveCriticalSection(FLock); end;
end;

procedure TKvmViewForm.CloseSocket;
begin
  StopClipboardWorker; // no native clipboard or send callbacks after this join
  // Best-effort release. The server also has disconnect/heartbeat cleanup.
  if FAuthorized and FControlGranted and (FSocket <> nil) then
    SendPacket('L');
  StopVideoWorker; // stops ACK sends before freeing the WebSocket
  // Freeing the mORMot client waits for its WebSocket processing thread.
  FreeAndNil(FSocket); FTransportFault:=False;
  if FInputs<>nil then FInputs.Reset; FDesktopEpoch:=0;
  ClearSurface(FFront.Surface);
  FStatsTick := GetTickCount64;
  FRawImportMs:=0; FPaintMs:=0; FPaintCount:=0; FPresentCount:=0;
  FAuthorized := False;
  FRemoteControl := False;
  FControlGranted := False;
  FAutoControlPending := False;
  if GetCaptureControl = FView then SetCaptureControl(nil);
  FCursorVisible := False;
  FKeyboardFocus := False;
  FControl.Checked := False;
  FControl.Enabled := False;
  FRefresh.Enabled := False;
  FText.Enabled := False;
  FDesktopPaused := True;
  SyncClipboardOptions;
  ResetLocalInputs;
  FBitmap.SetSize(0, 0);
  FConnect.Enabled := True;
  FDisconnect.Enabled := False;
  FHost.Enabled := True;
  FPort.Enabled := True;
  FToken.Enabled := True;
  FTls.Enabled := True;
  EnterCriticalSection(FLock);
  try
    SetLength(FPendingTexts, 0);
    FWorkerFault:=False;
  finally
    LeaveCriticalSection(FLock);
  end;
  if not FClosing then SetCommandsVisible(True);
end;

procedure TKvmViewForm.ConnectClick(Sender: TObject);
var
  Proto: TWebSocketProtocolChat;
  Frame: TWebSocketFrame;
  PortNum: Integer;
  TLSContext: TNetTlsContext;
  ConnectOptions: THttpRequestExtendedOptions;
  TargetURI: TUri;
  ConnectError: RawUtf8;
  Capability: RawByteString;
begin
  if FSocket <> nil then Exit;
  PortNum := StrToIntDef(FPort.Text, 0);
  if (PortNum < 1) or (PortNum > 65535) or
     (Trim(FHost.Text) = '') or not ValidKvmToken(FToken.Text) then
  begin
    MessageDlg('Saisir un hote, un port valide et un jeton ASCII sans espace (16..256 caracteres).',
      mtWarning, [mbOK], 0);
    Exit;
  end;

  if not FTls.Checked and not FAllowInsecure and not KvmLoopbackHost(FHost.Text) then
  begin
    SetStatus('TLS requis hors loopback. --allow-insecure uniquement pour un tunnel/VPN de confiance.');
    Exit;
  end;
  FAutoControlPending := FAutoControl;
  SetStatus('Connexion en cours...');
  FConnect.Enabled := False;
  // Reutiliser les options TLS pour le chemin mORMot2 donnant le code
  // HTTP d'echec (l'ancien overload effacait ce diagnostic).
  if FTls.Checked then
  begin
    if (FTlsCaFile<>'') and not FileExists(FTlsCaFile) then
    begin
      SetStatus('Fichier CA TLS introuvable : ' + FTlsCaFile);
      FConnect.Enabled := True;
      Exit;
    end;
    PrepareClientTls(FTlsCaFile,TLSContext);
  end;

  // Configuration identique au chemin historique, mais avec un diagnostic
  // d'echec de negotiation (HTTP 400, 404, 429, erreur TLS, etc.).
  ConnectOptions.InitDefault;
  ConnectOptions.Proxy := 'none';
  ConnectOptions.CreateTimeoutMS := 10000;
  if FTls.Checked then
    ConnectOptions.TLS := TLSContext;
  if not TargetURI.FromScheme(WS_SCHEME[FTls.Checked],
      RawUtf8(FHost.Text), RawUtf8(FPort.Text), KVM_WS_PATH) then
  begin
    SetStatus('Adresse WebSocket invalide.');
    FConnect.Enabled := True;
    Exit;
  end;
  try
    FDecoder:=TKvmVideoWorker.Create(FEnableH264,@DecodeReply);
    Capability:='jpeg';
    if FDecoder.H264Available then Capability:='h264';
    if FDecoder.NativeAvailable then
      KvmClientLog('[client-video] TurboJPEG sur worker; ACK apres composition CPU')
    else KvmClientLog('[client-video] Repli FCL JPEG sur worker (aucun decodage GUI)');
    Proto := TWebSocketProtocolChat.Create(KVM_SUBPROTOCOL, KVM_WS_PATH,
      @IncomingFrame);
    // La methode mORMot2 gere la destruction de Proto, y compris en echec.
    ConnectError := '';
    FSocket := THttpClientWebSockets.WebSocketsConnect(
      TargetURI, ConnectOptions, Proto, nil, '', '', @ConnectError);
    if FSocket = nil then
    begin
      if ConnectError = '' then ConnectError := 'aucune reponse du serveur';
      raise Exception.Create('Echec WebSocket ' + string(ConnectError));
    end;

    Frame.opcode := focText;
    Frame.content := [];
    Frame.tix := 0;
    FSocket.WebSockets.Settings^.LoopDelay := 5;
    FSocket.WebSockets.Settings^.SendDelay := 1;
    FSocket.WebSockets.Settings^.ClientAutoUpgrade := False; // require a fresh AUTH
    Frame.payload := 'AUTH ' + RawByteString(AnsiString(FToken.Text))+' '+Capability;
    if not FSocket.WebSockets.SendFrame(Frame) then
      raise Exception.Create('Impossible d''envoyer le jeton.');

    FClipboardWorker:=TKvmClipboardClientWorker.Create(@CreateClipboardBackend,@DecodeReply);
    FDisconnect.Enabled := True;
    FHost.Enabled := False;
    FPort.Enabled := False;
    FToken.Enabled := False;
    FTls.Enabled := False;
    SetStatus('Socket ouvert ; authentification en cours...');
  except
    on E: Exception do
    begin
      CloseSocket;
      SetStatus('Echec de connexion : ' + E.Message);
    end;
  end;
end;

procedure TKvmViewForm.DisconnectClick(Sender: TObject);
begin
  CloseSocket;
  SetStatus('Deconnecte');
  FView.Invalidate;
end;

procedure TKvmViewForm.ControlClick(Sender: TObject);
begin
  SyncClipboardOptions;
  FText.Enabled := False;
  if GetCaptureControl = FView then SetCaptureControl(nil);
  ResetLocalInputs;
  if not FAuthorized or not FRemoteControl or FDesktopPaused then
  begin
    FControl.Checked := False;
    Exit;
  end;
  if FControl.Checked then
  begin
    FControlGranted := False;
    SendPacket('G'); // Request exclusive control from the SERVER.
    SetStatus('Demande du controle exclusif au serveur...');
  end
  else
  begin
    FControlGranted := False;
    SendPacket('L'); // Server releases all held inputs on relinquish.
    SetStatus('Visualisation uniquement : controle libere.');
  end;
end;

procedure TKvmViewForm.TryAutoRequestControl;
var
  SavedClick: TNotifyEvent;
begin
  // Never take control on merely opening the socket, with a view-only token,
  // or while logind/the server says the desktop is locked or unavailable.
  // The server is the sole authority: 'G' is a request, not a grant.
  if not FAutoControlPending or not FAuthorized or not FRemoteControl or
     FDesktopPaused or not FControl.Enabled or
     (FSocket=nil) or (FSocket.WebSockets=nil) then Exit;
  FAutoControlPending := False; // one request per connection, no busy retry loop
  // Updating Checked from Pascal may fire OnClick on some widgetsets.
  // Suppress the event and invoke the existing request path exactly once.
  SavedClick := FControl.OnClick;
  FControl.OnClick := nil;
  try
    FControl.Checked := True;
  finally
    FControl.OnClick := SavedClick;
  end;
  ControlClick(nil);
end;

procedure TKvmViewForm.WindowDeactivated(Sender: TObject);
begin
  if GetCaptureControl = FView then SetCaptureControl(nil);
  // The user moved to another application. Unstick remote keys/buttons.
  if FAuthorized and FControlGranted then SendPacket('Z');
  FKeyboardFocus := False;
  ResetLocalInputs;
end;

procedure TKvmViewForm.RefreshClick(Sender: TObject);
begin
  if FAuthorized then SendPacket('R');
end;

procedure TKvmViewForm.ResetLocalInputs;
begin
  FillChar(FSuppressedKeys, SizeOf(FSuppressedKeys), 0);
  FillChar(FForwardedKeys, SizeOf(FForwardedKeys), 0);
  FMouseButtons := 0; FWheelRemainder := 0; FLastShift := [];
  FPendingMouseMove := False; FLastMouseTick := 0;
  if GetCaptureControl = FView then SetCaptureControl(nil); FKeyboardFocus := False;
end;

procedure TKvmViewForm.ApplyDesktopState(Available: Boolean; Reason: Byte; Epoch: Cardinal);
var EpochChanged: Boolean;
begin
  if (FDesktopPaused=(not Available)) and (FDesktopEpoch=Epoch) then Exit;
  EpochChanged:=FDesktopEpoch<>Epoch;
  FDesktopEpoch:=Epoch;
  FDesktopPaused := not Available;
  if not Available or EpochChanged then
  begin
    ResetLocalInputs; FControlGranted := False; FControl.Checked := False;
    FControl.Enabled := False; FText.Enabled := False;
    FCursorVisible := False; FBitmap.SetSize(0,0);
    ClearSurface(FFront.Surface);
    FInputs.CancelQueued;
    SetStatus(DesktopStateText(Reason)+'. Controle retire.');
  end;
  if Available then
  begin
    FControl.Enabled := FAuthorized and FRemoteControl;
    SetStatus('Bureau disponible. Redemander le controle si necessaire.');
  end;
  SyncClipboardOptions;
  FView.Invalidate;
end;

procedure TKvmViewForm.TextClick(Sender: TObject);
var Value: string; Packet: RawByteString;
begin
  if not ControlAllowed then Exit;
  // Local input method performs composition in a normal LCL edit field.
  // A commit is not an IME event stream or a clipboard synchronization.
  SendPacket('Z'); ResetLocalInputs;
  Value := '';
  if not InputQuery('Saisie de texte', 'Texte valide par votre methode de saisie (256 caracteres maximum)', Value) then Exit;
  Packet := MakeTextUtf8(RawByteString(AnsiString(Value)));
  if Packet = '' then
    SetStatus('Texte refuse : limite 256 points Unicode / 1024 octets, sans controles.')
  else if ControlAllowed then SendPacket(Packet);
end;

procedure TKvmViewForm.IncomingFrame(Sender: TWebSocketProcess;
  const Frame: TWebSocketFrame);
var N: Integer; TextMsg: string;
begin
  if FClosing then Exit;
  case Frame.opcode of
    focBinary:
      begin
        EnterCriticalSection(FLock);
        try
          if (Length(Frame.payload)>0) and (Frame.payload[1]='c') then
          begin
            if (FClipboardWorker=nil) or not FClipboardWorker.EnqueueReply(Frame.payload) then
              FWorkerFault:=True;
          end
          else if FDecoder<>nil then FDecoder.Enqueue(Frame.payload);
        finally LeaveCriticalSection(FLock); end;
      end;
    focText, focConnectionClose:
      begin
        if Frame.opcode = focConnectionClose then
        begin
          // A WebSocket close frame may carry a 16-bit status code in network order.
          // Do not attribute the closure to the server without further evidence.
          if Length(Frame.payload) >= 2 then
            TextMsg := 'CLOSED ' + IntToStr(Ord(Frame.payload[1])*256 + Ord(Frame.payload[2]))
          else
            TextMsg := 'CLOSED (sans code)';
        end
        else if Length(Frame.payload) <= 512 then TextMsg := string(AnsiString(Frame.payload))
        else TextMsg := 'LOCAL PROTOCOL: reponse texte trop longue (' + IntToStr(Length(Frame.payload)) + ' octets)';
        EnterCriticalSection(FLock);
        try
          N := Length(FPendingTexts);
          if N < 32 then
          begin
            SetLength(FPendingTexts, N + 1);
            FPendingTexts[N] := TextMsg;
          end
          else if Copy(TextMsg,1,6) = 'CLOSED' then
          begin
            SetLength(FPendingTexts, 1);
            FPendingTexts[0] := 'CLOSED';
          end;
        finally
          LeaveCriticalSection(FLock);
        end;
      end;
  end;
end;

procedure TKvmViewForm.PresentSnapshot(const Snapshot: TKvmPresentation);
var Raw: TRawImage; Tick: QWord;
begin
  if not Snapshot.Available or (Snapshot.Epoch<>FDesktopEpoch) or
     FDesktopPaused or not SurfaceValid(Snapshot.Surface) then Exit;
  if (FFront.Surface.Width<>Snapshot.Surface.Width) or
     (FFront.Surface.Height<>Snapshot.Surface.Height) then
    SetStatus(Format('Bureau distant : %d x %d | worker video / F8 commandes',
      [Snapshot.Surface.Width,Snapshot.Surface.Height]));
  FFront:=Snapshot;
  FCursorX:=Snapshot.CursorX; FCursorY:=Snapshot.CursorY;
  FCursorVisible:=Snapshot.CursorVisible;
  Tick:=GetTickCount64;
  // Windows paints the CPU BGRX DIB directly, no per-tile LCL bitmap/import.
  // Other widgetsets import ONE coherent image per presentation, not each tile.
  {$IFDEF WINDOWS}
  if not FUseRawImage then
  {$ENDIF}
  begin
    Raw.Init;
    Raw.Description.Init_BPP32_B8G8R8_BIO_TTB(FFront.Surface.Width,FFront.Surface.Height);
    Raw.Data:=PByte(Pointer(FFront.Surface.Pixels));
    Raw.DataSize:=Length(FFront.Surface.Pixels);
    FBitmap.LoadFromRawImage(Raw,False);
  end;
  Inc(FRawImportMs,GetTickCount64-Tick); Inc(FPresentCount);
  FView.Invalidate;
end;

procedure TKvmViewForm.PollTimer(Sender: TObject);
var
  TextMsgs: array of string;
  TextMsg, FatalError, ClipboardNotice: string;
  DisableClipboard: Byte;
  Events: TKvmPacketList;
  Snapshot: TKvmPresentation;
  Stats: TKvmDecodeStats;
  I: Integer;
  HasSnapshot, Available: Boolean;
  Epoch: Cardinal; Reason, InputStatus: Byte; Applied: Word;
  NowTick: QWord;
begin
  if FPolling or FClosing then Exit;
  FPolling:=True;
  try
    if FTransportFault then
    begin
      CloseSocket; SetStatus('Envoi reseau interrompu : aucune saisie rejouee.'); Exit;
    end;
    if FAutoConnect then begin FAutoConnect:=False; ConnectClick(nil); end;
    HasSnapshot:=False; FatalError:='';
    EnterCriticalSection(FLock);
    try
      TextMsgs:=FPendingTexts; FPendingTexts:=nil;
      if FWorkerFault then FatalError:='Echange reseau interrompu ou reponse presse-papiers invalide';
    finally LeaveCriticalSection(FLock); end;
    if FatalError<>'' then
    begin CloseSocket; SetStatus(FatalError); Exit; end;
  for I := 0 to High(TextMsgs) do
  begin
    TextMsg := TextMsgs[I];
    if TextMsg = 'OK CTRL' then
    begin
      FAuthorized := True;
      FRemoteControl := True;
      FControl.Enabled := not FDesktopPaused;
      FRefresh.Enabled := True;
      SetStatus('Connecte | controle possible, F8 pour les commandes.');
      SetCommandsVisible(False);
    end
    else if TextMsg = 'OK VIEW' then
    begin
      FAuthorized := True;
      FRemoteControl := False;
      FControl.Enabled := False;
      FRefresh.Enabled := True;
      SetStatus('Connecte | visualisation seule, F8 pour les commandes.');
      SetCommandsVisible(False);
    end
    else if TextMsg = 'CTRL GRANTED' then
    begin
      FControlGranted := not FDesktopPaused;
      FText.Enabled := FControlGranted;
      SetStatus('Controle EXCLUSIF accorde : cliquer dans le bureau.');
    end
    else if TextMsg = 'CTRL BUSY' then
    begin
      FControlGranted := False;
      FText.Enabled := False;
      FControl.Checked := False;
      ResetLocalInputs;
      SetStatus('Controle occupe par un autre client.');
    end
    else if TextMsg = 'CTRL RELEASED' then
    begin
      FControlGranted := False;
      FText.Enabled := False;
      ResetLocalInputs;
    end
    else if TextMsg = 'ERR INPUT' then
      SetStatus('Saisie non prise en charge ou refusee par le systeme distant. Le texte peut etre partiel.')
    else if (TextMsg = 'ERR AUTH') or (TextMsg = 'ERR LIMIT') or
            (Copy(TextMsg,1,6) = 'CLOSED') or (TextMsg = 'ERR TIMEOUT') or
            (TextMsg = 'ERR PROTOCOL') or (Copy(TextMsg,1,15) = 'LOCAL PROTOCOL:') then
    begin
      // Keep the diagnostic after CloseSocket(), which resets all GUI state.
      KvmClientLog('[client-ws] ' + TextMsg);
      CloseSocket;
      if TextMsg = 'ERR AUTH' then
        SetStatus('Authentification refusee')
      else if TextMsg = 'ERR LIMIT' then
        SetStatus('Nombre maximal de clients atteint')
      else if TextMsg = 'ERR TIMEOUT' then
        SetStatus('Session terminee : timeout signale par le serveur')
      else if TextMsg = 'ERR PROTOCOL' then
        SetStatus('Erreur de protocole signalee par le serveur')
      else if Copy(TextMsg,1,15) = 'LOCAL PROTOCOL:' then
        SetStatus('Erreur LOCALE de reception : ' + Copy(TextMsg,17,200))
      else
        SetStatus('WebSocket fermee : ' + TextMsg + ' (origine a determiner)');
      Exit;
    end;
  end;

    if not FAuthorized then Exit;
    if FDecoder<>nil then
      FDecoder.DrainUI(Events,Snapshot,HasSnapshot,FatalError);
    if FatalError<>'' then
    begin
      KvmClientLog('[client-video] erreur worker: '+FatalError);
      CloseSocket; SetStatus('Erreur video : '+FatalError); Exit;
    end;
    // Desktop transitions and input receipts are never coalesced/dropped.
    for I:=0 to High(Events) do
      case Events[I][1] of
        'D':
          if ReadDesktopState(Events[I],Available,Reason,Epoch) then
            ApplyDesktopState(Available,Reason,Epoch)
          else begin CloseSocket; SetStatus('Etat de session invalide'); Exit; end;
        'I':
          begin
            if not FInputs.Receipt(Events[I],InputStatus,Applied) then
            begin CloseSocket; SetStatus('Accuse de saisie invalide'); Exit; end;
            if InputStatus=KVM_INPUT_STALE then
            begin CloseSocket; SetStatus('Sequence de saisie desynchronisee'); Exit; end;
            if InputStatus<>KVM_INPUT_OK then
            begin
              FInputs.CancelQueued; TransmitPacket('Z'); ResetLocalInputs;
              SetStatus(Format('Saisie refusee/partielle (%d, %d points)',[InputStatus,Applied]));
            end;
            DrainInputs;
          end;
      end;
    TryAutoRequestControl; // AUTH and desktop state have both been processed.
    SyncClipboardOptions;
    if (FClipboardWorker<>nil) and FClipboardWorker.TakeNotice(DisableClipboard,ClipboardNotice) then
    begin
      FClipboardChanging:=True;
      try
        if (DisableClipboard and KVM_CLIP_WRITE)<>0 then FClipToRemote.Checked:=False;
        if (DisableClipboard and KVM_CLIP_READ)<>0 then FClipFromRemote.Checked:=False;
      finally FClipboardChanging:=False; end;
      SyncClipboardOptions;
      if ClipboardNotice<>'' then SetStatus(ClipboardNotice);
    end;

    if HasSnapshot then
      try PresentSnapshot(Snapshot);
      except on E: Exception do
        begin CloseSocket; SetStatus('Affichage impossible : '+E.Message); Exit; end; end;
    if FPendingMouseMove and ControlAllowed and
       (GetTickCount64-FLastMouseTick>=KVM_MOUSE_INTERVAL_MS) then
    begin
      FPendingMouseMove:=False; FLastMouseTick:=GetTickCount64;
      SendPacket(MakeMouse(0,0,FPendingMouseX,FPendingMouseY));
    end;
    if FInputs.TimedOut(GetTickCount64) then
    begin CloseSocket; SetStatus('Accuse de saisie absent : aucun renvoi'); Exit; end;
    if GetTickCount64-FLastHeartbeat>=3000 then
    begin FLastHeartbeat:=GetTickCount64; SendPacket('P'); end;
    NowTick:=GetTickCount64;
    if (NowTick-FStatsTick>=5000) and (FDecoder<>nil) then
    begin
      FDecoder.TakeStats(Stats);
      KvmClientLog('[client-video] ACK/s='+
        FormatFloat('0.0',Stats.AckCount*1000.0/(NowTick-FStatsTick))+
        ' JPEG/s='+FormatFloat('0.0',Stats.JpegCount*1000.0/(NowTick-FStatsTick))+
        ' decode worker ms='+IntToStr(Int64(Stats.DecodeMs))+
        ' copie CPU ms='+IntToStr(Int64(Stats.CopyMs))+
        ' commit+ACK ms='+IntToStr(Int64(Stats.CommitMs))+
        ' import LCL ms='+IntToStr(Int64(FRawImportMs))+
        ' PaintBox ms='+IntToStr(Int64(FPaintMs))+
        ' PaintBox/s='+FormatFloat('0.0',FPaintCount*1000.0/(NowTick-FStatsTick))+
        ' presentations='+IntToStr(FPresentCount)+
        ' presentations fusionnees='+IntToStr(Int64(Stats.Coalesced))+
        ' file max octets='+IntToStr(Int64(Stats.QueueHighBytes))+
        ' TurboJPEG='+IntToStr(Int64(Stats.NativeCount))+
        ' FCL='+IntToStr(Int64(Stats.FallbackCount))+
        ' NACK='+IntToStr(Int64(Stats.NackCount)));
      FStatsTick:=NowTick; FRawImportMs:=0; FPaintMs:=0;
      FPaintCount:=0; FPresentCount:=0;
    end;
  finally FPolling:=False; end;
end;

function TKvmViewForm.GetVideoRect: TRect;
var
  Scale: Double;
  W, H: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if (FFront.Surface.Width = 0) or (FFront.Surface.Height = 0) or
     (FView.Width < 1) or (FView.Height < 1) then Exit;
  Scale := Min(FView.Width / FFront.Surface.Width, FView.Height / FFront.Surface.Height);
  W := Max(1, Round(FFront.Surface.Width * Scale));
  H := Max(1, Round(FFront.Surface.Height * Scale));
  Result.Left := (FView.Width - W) div 2;
  Result.Top := (FView.Height - H) div 2;
  Result.Right := Result.Left + W;
  Result.Bottom := Result.Top + H;
end;

procedure TKvmViewForm.PaintView(Sender: TObject);
var
  R: TRect;
  CX, CY: Integer;
  HalfSize: Integer;
  PaintTick: QWord;
begin
  FView.Canvas.Brush.Color := clBlack;
  FView.Canvas.FillRect(FView.ClientRect);
  if (FFront.Surface.Width < 1) or (FFront.Surface.Height < 1) then
  begin
    FView.Canvas.Font.Color := clWhite;
    FView.Canvas.TextOut(20, 20, 'En attente du bureau distant...');
    Exit;
  end;
  R := GetVideoRect;
  PaintTick := GetTickCount64;
  {$IFDEF WINDOWS}
  if FUseRawImage then
  begin
    if not PaintWindowsSurface(FView.Canvas.Handle,FFront.Surface,R.Left,R.Top,
      R.Right-R.Left,R.Bottom-R.Top) then
      KvmClientLog('[client-video] Echec StretchDIBits Windows');
  end
  else
  {$ENDIF}
  begin
    if ((R.Right-R.Left)=FFront.Surface.Width) and
       ((R.Bottom-R.Top)=FFront.Surface.Height) then
      FView.Canvas.Draw(R.Left,R.Top,FBitmap)
    else FView.Canvas.StretchDraw(R,FBitmap);
  end;
  Inc(FPaintMs, GetTickCount64-PaintTick);
  Inc(FPaintCount);
  if not FCursorVisible then Exit;
  CX := R.Left + Integer((Int64(FCursorX) * (R.Right - R.Left - 1)) div 65535);
  CY := R.Top + Integer((Int64(FCursorY) * (R.Bottom - R.Top - 1)) div 65535);
  HalfSize := 9;
  // Crosshair overlay, not a claim to reproduce the native cursor shape.
  // Draw a dark outline first so that it remains visible over pale pixels.
  FView.Canvas.Pen.Style := psSolid;
  FView.Canvas.Pen.Color := clBlack;
  FView.Canvas.Pen.Width := 3;
  FView.Canvas.MoveTo(Max(R.Left, CX - HalfSize), CY);
  FView.Canvas.LineTo(Min(R.Right - 1, CX + HalfSize + 1), CY);
  FView.Canvas.MoveTo(CX, Max(R.Top, CY - HalfSize));
  FView.Canvas.LineTo(CX, Min(R.Bottom - 1, CY + HalfSize + 1));
  FView.Canvas.Pen.Color := clYellow;
  FView.Canvas.Pen.Width := 1;
  FView.Canvas.MoveTo(Max(R.Left, CX - HalfSize), CY);
  FView.Canvas.LineTo(Min(R.Right - 1, CX + HalfSize + 1), CY);
  FView.Canvas.MoveTo(CX, Max(R.Top, CY - HalfSize));
  FView.Canvas.LineTo(CX, Min(R.Bottom - 1, CY + HalfSize + 1));
end;

function TKvmViewForm.ToNormalized(X, Y: Integer;
  out NX, NY: Word): Boolean;
var
  R: TRect;
  W, H: Integer;
begin
  R := GetVideoRect;
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  if (FMouseButtons <> 0) and (W > 1) and (H > 1) then
  begin X := EnsureRange(X,R.Left,R.Right-1); Y := EnsureRange(Y,R.Top,R.Bottom-1); end;
  Result := (W > 1) and (H > 1) and (X >= R.Left) and
    (Y >= R.Top) and (X < R.Right) and (Y < R.Bottom);
  if not Result then Exit;
  NX := Word((Int64(X - R.Left) * 65535) div (W - 1));
  NY := Word((Int64(Y - R.Top) * 65535) div (H - 1));
end;

function TKvmViewForm.ControlAllowed: Boolean;
begin
  Result := not FDesktopPaused and FAuthorized and FRemoteControl and FControlGranted and FControl.Checked and
    (FSocket <> nil) and (FSocket.WebSockets <> nil);
end;

procedure TKvmViewForm.TransmitPacket(const Payload: RawByteString);
var
  Frame: TWebSocketFrame;
begin
  if (Payload = '') or not FAuthorized or (FSocket = nil) or
     (FSocket.WebSockets = nil) then Exit;
  Frame.opcode := focBinary;
  Frame.content := [];
  Frame.tix := 0;
  Frame.payload := Payload;
  try
    if not FSocket.WebSockets.SendFrame(Frame) then FTransportFault:=True;
  except
    FTransportFault:=True; // UI timer closes without recursively calling CloseSocket here.
  end;
end;

procedure TKvmViewForm.SendPacket(const Payload: RawByteString);
begin
  if (Payload='') or not FAuthorized or FTransportFault then Exit;
  if Payload[1] in ['K','M','W','U'] then
  begin
    if not ControlAllowed then Exit;
    if not FInputs.Push(Payload) then
    begin
      FInputs.CancelQueued; TransmitPacket('Z'); ResetLocalInputs;
      SetStatus('File de saisie pleine : entrees non transmises abandonnees, touches relachees.'); Exit;
    end;
    DrainInputs;
  end
  else begin
    if Payload[1] in ['L','Z'] then FInputs.CancelQueued;
    TransmitPacket(Payload);
  end;
end;

procedure TKvmViewForm.DrainInputs;
var Packet: RawByteString;
begin
  while not FTransportFault and ControlAllowed and FInputs.Take(GetTickCount64,Packet) do TransmitPacket(Packet);
end;

procedure TKvmViewForm.KeyboardModeClick(Sender: TObject);
begin
  if FAuthorized and FControlGranted then SendPacket('Z');
  ResetLocalInputs;
  if FRemoteKeys.Checked then SetStatus('Touches du bureau distant : son agencement/IME reste actif.')
  else SetStatus('Texte compose localement : UTF-8, raccourcis transmis separement.');
end;

function TKvmViewForm.MouseButtonCode(Button: TMouseButton): Byte;
begin
  case Button of
    mbLeft: Result := 1;
    mbRight: Result := 2;
    mbMiddle: Result := 3;
  else
    Result := 0;
  end;
end;

procedure TKvmViewForm.ViewMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
var
  NX, NY: Word;
  NowTicks: QWord;
begin
  if not ControlAllowed or not ToNormalized(X, Y, NX, NY) then Exit;
  // Keep the most recent position rather than dropping movements entirely.
  FPendingMouseX := NX; FPendingMouseY := NY;
  FPendingMouseMove := True;
  NowTicks := GetTickCount64;
  if (FLastMouseTick <> 0) and
     (NowTicks-FLastMouseTick < KVM_MOUSE_INTERVAL_MS) then Exit;
  FPendingMouseMove := False;
  FLastMouseTick := NowTicks;
  SendPacket(MakeMouse(0, 0, NX, NY));
end;

procedure TKvmViewForm.ViewMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  NX, NY: Word;
begin
  if not ControlAllowed or not ToNormalized(X, Y, NX, NY) then Exit;
  if MouseButtonCode(Button) = 0 then Exit;
  FMouseButtons := FMouseButtons or (1 shl (MouseButtonCode(Button)-1));
  FKeyboardFocus := True;
  SetCaptureControl(FView);
  // The button packet contains the exact position; discard an old move.
  FPendingMouseMove := False;
  // Remove focus from login edits; keyboard events go to the form.
  ActiveControl := nil;
  SendPacket(MakeMouse(1, MouseButtonCode(Button), NX, NY));
end;

procedure TKvmViewForm.ViewMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  NX, NY: Word;
  R: TRect;
begin
  if not ControlAllowed then Exit;
  if not ToNormalized(X, Y, NX, NY) then
  begin
    // Release the remote button even if the cursor left the image.
    R := GetVideoRect;
    if (R.Right <= R.Left + 1) or (R.Bottom <= R.Top + 1) then Exit;
    X := EnsureRange(X, R.Left, R.Right - 1);
    Y := EnsureRange(Y, R.Top, R.Bottom - 1);
    if not ToNormalized(X, Y, NX, NY) then Exit;
  end;
  if MouseButtonCode(Button) = 0 then Exit;
  FPendingMouseMove := False;
  SendPacket(MakeMouse(2, MouseButtonCode(Button), NX, NY));
  FMouseButtons := FMouseButtons and not (1 shl (MouseButtonCode(Button)-1));
  if FMouseButtons <> 0 then SetCaptureControl(FView)
  else if GetCaptureControl = FView then SetCaptureControl(nil);
end;

procedure TKvmViewForm.ViewMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  Notches: Integer;
begin
  if not ControlAllowed then Exit;
  Inc(FWheelRemainder, EnsureRange(WheelDelta,-1440,1440));
  Notches := FWheelRemainder div 120;
  Notches := EnsureRange(Notches, -12, 12);
  Handled := True;
  if Notches = 0 then Exit;
  Dec(FWheelRemainder, Notches*120);
  SendPacket(MakeWheel(Notches));
  Handled := True;
end;

function IsPrintableVirtualKey(K: Word): Boolean;
begin
  // Windows-style VKs supplied by Lazarus. For ordinary text we rely
  // on the UTF-8 keypress event; only shortcuts/navigation use VKs.
  Result := (K = $20) or (K in [$30..$39, $41..$5a, $60..$6f,
    $ba..$c0, $db..$de]);
end;

procedure TKvmViewForm.RemoteUTF8KeyPress(Sender: TObject;
  var UTF8Key: TUTF8Char);
var
  Packet: RawByteString;
begin
  if not ControlAllowed or not FKeyboardFocus then Exit;
  if FRemoteKeys.Checked then begin UTF8Key:=''; Exit; end;
  if (ActiveControl = FHost) or (ActiveControl = FPort) or
     (ActiveControl = FToken) then Exit;
  // Ctrl+C, Alt+F4 and similar shortcuts remain virtual-key events.
  // Ctrl+Alt together may be AltGr on international layouts.
  if ((ssCtrl in FLastShift) xor (ssAlt in FLastShift)) or (ssMeta in FLastShift) then Exit;
  Packet := MakeTextUtf8(RawByteString(AnsiString(UTF8Key)));
  if Packet = '' then Exit;
  SendPacket(Packet);
  UTF8Key := '';
end;

procedure TKvmViewForm.RemoteKeyDown(Sender: TObject;
  var Key: Word; Shift: TShiftState);
var
  Shortcut: Boolean;
begin
  // F8 appartient toujours au CLIENT : jamais transmis au bureau distant.
  if Key = VK_F8 then
  begin
    SetCommandsVisible(not FTop.Visible);
    Key := 0;
    Exit;
  end;
  FLastShift := Shift;
  if not ControlAllowed or not FKeyboardFocus then Exit;
  if (ActiveControl = FHost) or (ActiveControl = FPort) or
     (ActiveControl = FToken) then Exit;
  if (Key=0) or (Key>255) then Exit;
  Shortcut := ((ssCtrl in Shift) xor (ssAlt in Shift)) or (ssMeta in Shift);
  if not FRemoteKeys.Checked and IsPrintableVirtualKey(Key) and not Shortcut then
  begin
    FSuppressedKeys[Key] := True;
    Exit; // Wait for OnUTF8KeyPress: AZERTY, accents and Unicode.
  end;
  FForwardedKeys[Key] := True;
  SendPacket(MakeKey(True, Key));
  Key := 0;
end;

procedure TKvmViewForm.RemoteKeyUp(Sender: TObject;
  var Key: Word; Shift: TShiftState);
begin
  if Key = VK_F8 then
  begin
    Key := 0;
    Exit;
  end;
  FLastShift := Shift;
  if not ControlAllowed or not FKeyboardFocus then Exit;
  if (ActiveControl = FHost) or (ActiveControl = FPort) or
     (ActiveControl = FToken) then Exit;
  if (Key=0) or (Key>255) then Exit;
  // A key first suppressed as text may later repeat as a Ctrl shortcut.
  // Always release a forwarded down, even when the suppression flag is set.
  if FForwardedKeys[Key] then SendPacket(MakeKey(False, Key));
  FForwardedKeys[Key] := False; FSuppressedKeys[Key] := False;
  Key := 0;
end;

end.
