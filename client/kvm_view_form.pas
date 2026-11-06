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
  kvm_turbojpeg_decode, kvm_client_log;

type
  TKvmViewForm = class(TForm)
  private
    FTop: TPanel; // Panneau de commandes flottant, sans espace reserve
    FMenuButton: TButton; // Poignee discrete, visible uniquement en session
    FHost, FPort, FToken: TEdit;
    FConnect, FDisconnect, FRefresh, FText: TButton;
    FControl, FRemoteKeys: TCheckBox;
    FAllowInsecure, FEnableH264, FTransportFault: Boolean;
    FH264Decoder: TKvmH264Decoder;
    FInputs: TKvmInputQueue;
    FDesktopEpoch: Cardinal;
    FTls: TCheckBox;
    FTlsCaFile: string;
    FStatus: TLabel;
    FView: TPaintBox;
    FTimer: TTimer;
    FBitmap: TBitmap;
    FJpegImage: TJPEGImage;
    FJpegStream: TMemoryStream;
    FTurboDecoder: TKvmTurboJpegDecoder;
    FTileBitmap: TBitmap;
    FTileBmpBytes: RawByteString;
    FTileBgrBytes: RawByteString;
    FUseRawImage: Boolean;
    FNativeDecodeMs, FRawImportMs, FBlitMs, FPaintMs: QWord;
    FRawTiles, FPaintCount: Cardinal;
    FStatsTick, FDecodeMs: QWord;
    FDecodedTiles, FAckedBatches: Cardinal;
    FTurboTiles, FFallbackTiles: Cardinal;
    FSocket: THttpClientWebSockets;
    FLock: TRTLCriticalSection;
    FPendingPackets: array of RawByteString;
    FPendingBytes: Int64;
    FNeedRefresh: Boolean;
    FLastRefreshTick: QWord;
    FPendingTexts: array of string;
    FPendingCursor, FPendingCursorVisible: Boolean;
    FPendingCursorX, FPendingCursorY: Word;
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
    FAutoConnect, FDropUntilScreen, FBatchInvalid: Boolean;

    procedure ConnectClick(Sender: TObject);
    procedure MenuClick(Sender: TObject);
    procedure WindowResized(Sender: TObject);
    procedure LayoutOverlay;
    procedure SetCommandsVisible(AVisible: Boolean);
    procedure DisconnectClick(Sender: TObject);
    procedure ControlClick(Sender: TObject);
    procedure WindowDeactivated(Sender: TObject);
    procedure RefreshClick(Sender: TObject);
    procedure TextClick(Sender: TObject);
    procedure ResetLocalInputs;
    procedure ApplyDesktopState(Available: Boolean; Reason: Byte; Epoch: Cardinal);
    procedure KeyboardModeClick(Sender: TObject);
    procedure TransmitPacket(const Payload: RawByteString);
    procedure DrainInputs;
    procedure PreserveMarkersLocked;
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
    function ApplyScreen(const Packet: RawByteString): Boolean;
    function ApplyTile(const Packet: RawByteString): Boolean;
    function ApplyVideo(const Packet: RawByteString): Boolean;
    procedure InvalidateBatchAndResync;
    procedure CloseSocket;
  public
    procedure ApplyOptions(const Options: TKvmClientOptions);
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

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
  // Reuse the JPEG decoder and stream across rectangles on the GUI thread.
  FJpegImage := TJPEGImage.Create;
  FJpegStream := TMemoryStream.Create;
  FTileBitmap := TBitmap.Create;
  FTurboDecoder := TKvmTurboJpegDecoder.Create;
  // Emergency escape hatch for older widgetsets: use the tested BMP path.
  FUseRawImage := GetEnvironmentVariable('MESHKVM_RAW_IMAGE') <> '0';
  FNativeDecodeMs := 0; FRawImportMs := 0; FBlitMs := 0;
  FRawTiles := 0; FPaintMs := 0; FPaintCount := 0;
  if FTurboDecoder.Available then
    KvmClientLog('[client-video] TurboJPEG natif disponible pour le decodage')
  else
    KvmClientLog('[client-video] TurboJPEG absent : repli sur TJPEGImage LCL');
  FStatsTick := GetTickCount64;
  FDecodeMs := 0; FDecodedTiles := 0; FAckedBatches := 0;
  FTurboTiles := 0; FFallbackTiles := 0;
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
  FPendingCursor := False;
  FKeyboardFocus := False;
  FNeedRefresh := False;
  FLastRefreshTick := 0;
  FAutoConnect := False;
  FDropUntilScreen := False;
  FBatchInvalid := False;
  FDesktopPaused := True;
  WebSocketsMaxFrameMB := 4;

  FTop := TPanel.Create(Self);
  FTop.Parent := Self;
  // Le panneau NE doit pas changer la geometrie du bureau distant.
  // alTop reduirait l'image de 124 px meme quand la session est active.
  FTop.Align := alNone;
  FTop.SetBounds(0, 0, 1020, 124);
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
  FTls.Checked := Options.TLS;
  FTlsCaFile := Options.TLSCA;
  FAllowInsecure:=Options.AllowInsecure; FEnableH264:=Options.H264;
  FRemoteKeys.Checked:=Options.Keyboard='remote';
end;

destructor TKvmViewForm.Destroy;
begin
  FClosing := True;
  if FTimer<>nil then FTimer.Enabled:=False;
  if FView<>nil then CloseSocket else FreeAndNil(FSocket);
  FTurboDecoder.Free; FTileBitmap.Free;
  FJpegStream.Free; FJpegImage.Free;
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

procedure TKvmViewForm.CloseSocket;
begin
  // Best-effort release. The server also has disconnect/heartbeat cleanup.
  if FAuthorized and FControlGranted and (FSocket <> nil) then
    SendPacket('L');
  // Freeing the mORMot client waits for its WebSocket processing thread.
  FreeAndNil(FSocket); FTransportFault:=False;
  FreeAndNil(FH264Decoder); FInputs.Reset; FDesktopEpoch:=0;
  FStatsTick := GetTickCount64;
  FDecodeMs := 0; FDecodedTiles := 0; FAckedBatches := 0;
  FTurboTiles := 0; FFallbackTiles := 0;
  FAuthorized := False;
  FRemoteControl := False;
  FControlGranted := False;
  if GetCaptureControl = FView then SetCaptureControl(nil);
  FCursorVisible := False;
  FKeyboardFocus := False;
  FControl.Checked := False;
  FControl.Enabled := False;
  FRefresh.Enabled := False;
  FText.Enabled := False;
  FDesktopPaused := True;
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
    SetLength(FPendingPackets, 0);
    FPendingBytes := 0;
    SetLength(FPendingTexts, 0);
    FPendingCursor := False;
    FNeedRefresh := False;
    FDropUntilScreen := False;
    FBatchInvalid := False;
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
  Capability:='jpeg';
  if FEnableH264 then
    try FH264Decoder:=TKvmH264Decoder.Create; Capability:='h264';
    except on E: Exception do begin FreeAndNil(FH264Decoder); SetStatus('Decodeur H264 absent : JPEG uniquement'); end; end;
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
  Proto := TWebSocketProtocolChat.Create(KVM_SUBPROTOCOL, KVM_WS_PATH,
    @IncomingFrame);
  try
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
begin
  if (FDesktopPaused=(not Available)) and (FDesktopEpoch=Epoch) then Exit;
  FDesktopEpoch:=Epoch;
  FDesktopPaused := not Available;
  if not Available then
  begin
    ResetLocalInputs; FControlGranted := False; FControl.Checked := False;
    FControl.Enabled := False; FText.Enabled := False;
    FCursorVisible := False; FBitmap.SetSize(0,0);
    FBatchInvalid := True;
    FInputs.CancelQueued;
    SetStatus(DesktopStateText(Reason)+'. Controle retire.');
  end
  else
  begin
    FControl.Enabled := FAuthorized and FRemoteControl;
    SetStatus('Bureau disponible. Redemander le controle si necessaire.');
  end;
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
var
  N: Integer;
  CX, CY: Word;
  Visible1: Boolean;
  TextMsg: string;
begin
  if FClosing then Exit;
  case Frame.opcode of
    focBinary:
      begin
        if ReadCursor(Frame.payload, CX, CY, Visible1) then
        begin
          EnterCriticalSection(FLock);
          try
            FPendingCursorVisible := Visible1;
            FPendingCursorX := CX;
            FPendingCursorY := CY;
            FPendingCursor := True;
          finally
            LeaveCriticalSection(FLock);
          end;
          Exit;
        end;
        if (Length(Frame.payload) <> 0) and
           (Frame.payload[1] in ['S', 'T', 'V', 'B', 'D', 'I']) then
        begin
          EnterCriticalSection(FLock);
          try
            // A new S is the beginning of a fresh, ordered snapshot.
            if Frame.payload[1] = 'S' then
            begin
              // Preserve binary D/B order; a screen reset must not erase
              // the preceding session-state message or an ACK delimiter.
              FDropUntilScreen := False;
              // Do not erase a previous lost-batch notice before the UI sees its B.
            end;
            if (Length(Frame.payload)>KVM_MAX_VIDEO_BYTES+KVM_VIDEO_HEADER) or
               ((Frame.payload[1] in ['S','B']) and (Length(Frame.payload)<>5)) or
               ((Frame.payload[1]='D') and (Length(Frame.payload)<>7)) or
               ((Frame.payload[1]='I') and (Length(Frame.payload)<>8)) or
               ((Frame.payload[1]='T') and (Length(Frame.payload)<13)) or
               ((Frame.payload[1]='V') and (Length(Frame.payload)<15)) then
            begin
              SetLength(FPendingTexts,1);
              FPendingTexts[0]:=Format('LOCAL PROTOCOL: trame %s de %d octets (taille invalide)',
                [string(Frame.payload[1]),Length(Frame.payload)]);
              SetLength(FPendingPackets,0); FPendingBytes:=0;
            end
            else if (not FDropUntilScreen) or (Frame.payload[1] in ['B','D','I']) then
            begin
              N := Length(FPendingPackets);
              if (N < 128) and
                 (FPendingBytes + Length(Frame.payload) <= 16 * 1024 * 1024) then
              begin
                SetLength(FPendingPackets, N + 1);
                FPendingPackets[N] := Frame.payload;
                Inc(FPendingBytes, Length(Frame.payload));
              end
              else
              begin
                // With one bounded batch in flight, this limit cannot be
                // reached by a conforming server. Close rather than losing
                // desktop-state or text receipts and acknowledging stale pixels.
                SetLength(FPendingTexts,1);
                FPendingTexts[0]:=Format('LOCAL PROTOCOL: file reception pleine (%d trames, %d octets, nouveau %d octets)',
                  [N,FPendingBytes,Length(Frame.payload)]);
                SetLength(FPendingPackets,0); FPendingBytes:=0;
              end;
            end;
          finally
            LeaveCriticalSection(FLock);
          end;
        end;
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

procedure TKvmViewForm.PollTimer(Sender: TObject);
var
  Packets: array of RawByteString;
  TextMsgs: array of string;
  TextMsg: string;
  N, I, Total: Integer;
  NeedRefresh, Ready, CursorChanged, RejectBatch, CursorVisible: Boolean;
  Serial, Epoch: Cardinal;
  Reason, InputStatus: Byte; Applied: Word; Available: Boolean;
  CX, CY: Word;
  StartDecode, NowTick: QWord;
begin
  if FTransportFault then
  begin
    CloseSocket; SetStatus('Envoi reseau interrompu : connexion fermee, aucune saisie rejouee.'); Exit;
  end;
  if FAutoConnect then
  begin
    FAutoConnect := False;
    ConnectClick(nil);
  end;
  EnterCriticalSection(FLock);
  try
    TextMsgs := Copy(FPendingTexts, 0, Length(FPendingTexts));
    SetLength(FPendingTexts, 0);
    Total := Length(FPendingPackets);
    Ready := FAuthorized;
    for I := 0 to High(TextMsgs) do
      if (TextMsgs[I] = 'OK CTRL') or (TextMsgs[I] = 'OK VIEW') then
        Ready := True;
    if Ready then N := Min(Total, 24) else N := 0;
    SetLength(Packets, N);
    for I := 0 to N - 1 do
    begin
      Packets[I] := FPendingPackets[I];
      Dec(FPendingBytes, Length(FPendingPackets[I]));
    end;
    for I := N to Total - 1 do
      FPendingPackets[I - N] := FPendingPackets[I];
    SetLength(FPendingPackets, Total - N);
    NeedRefresh := FNeedRefresh;
    FNeedRefresh := False;
    CursorChanged := FPendingCursor;
    CursorVisible := FPendingCursorVisible;
    CX := FPendingCursorX;
    CY := FPendingCursorY;
    FPendingCursor := False;
  finally
    LeaveCriticalSection(FLock);
  end;

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

  if FAuthorized then
  begin
    // Flush the latest move even if no more GUI mouse events arrive.
    // A coalesced move is never allowed to outlive a release or focus loss.
    if FPendingMouseMove and ControlAllowed and
       (GetTickCount64-FLastMouseTick >= KVM_MOUSE_INTERVAL_MS) then
    begin
      FPendingMouseMove := False;
      FLastMouseTick := GetTickCount64;
      SendPacket(MakeMouse(0,0,FPendingMouseX,FPendingMouseY));
    end;
    if FInputs.TimedOut(GetTickCount64) then
    begin
      CloseSocket; SetStatus('Accuse de saisie absent : resultat inconnu, aucun renvoi automatique.'); Exit;
    end;
    if NeedRefresh then FBatchInvalid:=True;
    if (GetTickCount64 - FLastHeartbeat >= 3000) then
    begin
      FLastHeartbeat := GetTickCount64;
      SendPacket('P');
    end;
    if NeedRefresh then
    begin
      if GetTickCount64 - FLastRefreshTick >= 2000 then
      begin
        FLastRefreshTick := GetTickCount64;
        SendPacket('R');
      end
      else
      begin
        EnterCriticalSection(FLock);
        try
          FNeedRefresh := True;
        finally
          LeaveCriticalSection(FLock);
        end;
      end;
    end;
    for I := 0 to High(Packets) do
    begin
      if Packets[I] = '' then Continue;
      case Packets[I][1] of
        'D':
          if ReadDesktopState(Packets[I],Available,Reason,Epoch) then
            ApplyDesktopState(Available,Reason,Epoch)
          else begin CloseSocket; SetStatus('Etat de session invalide'); Exit; end;
        'I':
          begin
            if not FInputs.Receipt(Packets[I],InputStatus,Applied) then
            begin CloseSocket; SetStatus('Accuse de saisie invalide'); Exit; end;
            if InputStatus=KVM_INPUT_STALE then
            begin CloseSocket; SetStatus('Sequence de saisie desynchronisee : aucun renvoi'); Exit; end;
            if InputStatus<>KVM_INPUT_OK then
            begin
              FInputs.CancelQueued; TransmitPacket('Z'); ResetLocalInputs;
              SetStatus(Format('Saisie refusee/partielle (statut %d, %d points soumis). Pas de renvoi.',[InputStatus,Applied]));
            end;
            DrainInputs;
          end;
        'V':
          if not FDesktopPaused and not FBatchInvalid then
            if not ApplyVideo(Packets[I]) then
            begin FBatchInvalid:=True; InvalidateBatchAndResync; end;
        'S':
          begin
            // Failed batches can only be recovered by a new screen reset.
            FBatchInvalid := FDesktopPaused or not ApplyScreen(Packets[I]);
            if FBatchInvalid then InvalidateBatchAndResync;
          end;
        'T':
          if not FDesktopPaused and not FBatchInvalid then
          begin
            StartDecode := GetTickCount64;
            if not ApplyTile(Packets[I]) then
            begin
              FBatchInvalid := True;
              InvalidateBatchAndResync;
            end
            else Inc(FDecodedTiles);
            Inc(FDecodeMs, GetTickCount64 - StartDecode);
          end;
        'B':
          begin
            RejectBatch := FBatchInvalid or FDesktopPaused;
            EnterCriticalSection(FLock);
            try
              RejectBatch := RejectBatch or FDropUntilScreen;
            finally
              LeaveCriticalSection(FLock);
            end;
            if ReadBatchEnd(Packets[I], Serial) then
              if RejectBatch then SendPacket(MakeBatchNack(Serial))
              else
              begin
                Inc(FAckedBatches);
                SendPacket(MakeBatchAck(Serial));
              end;
          end;
      end;
    end;
    if CursorChanged then
    begin
      FCursorX := CX;
      FCursorY := CY;
      FCursorVisible := CursorVisible and not FDesktopPaused;
    end;
    if (Length(Packets) <> 0) or CursorChanged then FView.Invalidate;
    NowTick := GetTickCount64;
    if NowTick - FStatsTick >= 5000 then
    begin
      // ACK/s is not FPS: a full snapshot may require multiple batches.
      KvmClientLog('[client-video] ACK/s=' +
        FormatFloat('0.0', FAckedBatches * 1000.0 / (NowTick-FStatsTick)) +
        ' JPEG/s=' + FormatFloat('0.0', FDecodedTiles * 1000.0 / (NowTick-FStatsTick)) +
        ' traitement total ms=' + IntToStr(Int64(FDecodeMs)) +
        ' decomp. native ms=' + IntToStr(Int64(FNativeDecodeMs)) +
        ' import LCL ms=' + IntToStr(Int64(FRawImportMs)) +
        ' dessin ms=' + IntToStr(Int64(FBlitMs)) +
        ' PaintBox ms=' + IntToStr(Int64(FPaintMs)) +
        ' PaintBox/s=' + FormatFloat('0.0', FPaintCount * 1000.0 / (NowTick-FStatsTick)) +
        ' JPEG direct=' + IntToStr(FRawTiles) +
        ' TurboJPEG=' + IntToStr(FTurboTiles) + ' LCL=' + IntToStr(FFallbackTiles));
      FStatsTick := NowTick;
      FDecodeMs := 0; FDecodedTiles := 0; FAckedBatches := 0;
      FTurboTiles := 0; FFallbackTiles := 0;
      FNativeDecodeMs := 0; FRawImportMs := 0; FBlitMs := 0;
      FRawTiles := 0; FPaintMs := 0; FPaintCount := 0;
    end;
  end;
end;

procedure TKvmViewForm.PreserveMarkersLocked;
var I,N: Integer;
begin
  N:=0; FPendingBytes:=0;
  for I:=0 to High(FPendingPackets) do
    if ((Length(FPendingPackets[I])=5) and (FPendingPackets[I][1]='B')) or
       ((Length(FPendingPackets[I])=7) and (FPendingPackets[I][1]='D')) or
       ((Length(FPendingPackets[I])=8) and (FPendingPackets[I][1]='I')) then
    begin
      FPendingPackets[N]:=FPendingPackets[I]; Inc(FPendingBytes,Length(FPendingPackets[N])); Inc(N);
    end;
  SetLength(FPendingPackets,N);
end;

procedure TKvmViewForm.InvalidateBatchAndResync;
begin
  EnterCriticalSection(FLock);
  try
    FDropUntilScreen:=True; FNeedRefresh:=True;
    PreserveMarkersLocked;
  finally LeaveCriticalSection(FLock); end;
end;

function TKvmViewForm.ApplyVideo(const Packet: RawByteString): Boolean;
var W,H: Word; AU,BMP: RawByteString; RGB: TRgbFrame;
    Error: string; Stream: TMemoryStream;
begin
  Result:=False;
  if (FH264Decoder=nil) or not ReadVideo(Packet,W,H,AU) then Exit;
  if (FBitmap.Width<>W) or (FBitmap.Height<>H) then Exit;
  if not FH264Decoder.Decode(AU,W,H,RGB,Error) then
  begin SetStatus('H264 refuse : '+Error); Exit; end;
  BMP:=RgbBitmapBytes(RGB); if BMP='' then Exit;
  Stream:=TMemoryStream.Create;
  try
    try
      Stream.WriteBuffer(BMP[1],Length(BMP)); Stream.Position:=0;
      FBitmap.LoadFromStream(Stream); Result:=(FBitmap.Width=W) and (FBitmap.Height=H);
    except on E: Exception do SetStatus('Image H264 non affichee : '+E.Message); end;
  finally Stream.Free; end;
end;

function TKvmViewForm.ApplyScreen(const Packet: RawByteString): Boolean;
var
  W, H: Word;
begin
  Result := ReadScreen(Packet, W, H);
  if not Result then Exit;
  try
    // Avoid a flash to black on a same-size snapshot.
    if (FBitmap.Width <> W) or (FBitmap.Height <> H) then
    begin
      FBitmap.SetSize(W, H);
      FBitmap.Canvas.Brush.Color := clBlack;
      FBitmap.Canvas.FillRect(Rect(0, 0, W, H));
    end;
    SetStatus(Format('Bureau distant : %d x %d | JPEG / H264 selon codec negocie', [W, H]));
  except
    on E: Exception do
    begin
      Result := False;
      SetStatus('Bureau non initialise : ' + E.Message);
    end;
  end;
end;

function TKvmViewForm.ApplyTile(const Packet: RawByteString): Boolean;
var
  X, Y, W, H: Word;
  Jpeg: RawByteString;
  Raw: TRawImage;
  Tick: QWord;
begin
  Result := ReadTile(Packet, X, Y, W, H, Jpeg);
  if not Result then Exit;
  Result := False;
  if (FBitmap.Width = 0) or (FBitmap.Height = 0) or
     (Integer(X) + W > FBitmap.Width) or
     (Integer(Y) + H > FBitmap.Height) then Exit;
  if not JpegMatchesSize(Jpeg, W, H) then Exit;
  try
    // Direct TurboJPEG BGR24 => TRawImage => bitmap. No BMP serialization,
    // TMemoryStream roundtrip or BMP parsing. The LCL copy is explicit:
    // ADataOwner=False; decoded buffer can be reused on the next rectangle.
    // On a widgetset that rejects raw BGR, fall back to the existing path.
    if FUseRawImage and (FTurboDecoder <> nil) and FTurboDecoder.Available then
    begin
      Tick := GetTickCount64;
      if FTurboDecoder.DecodeToBgr(Jpeg, W, H, FTileBgrBytes) then
      begin
        Inc(FNativeDecodeMs, GetTickCount64 - Tick);
        Raw.Init;
        Raw.Description.Init_BPP24_B8G8R8_BIO_TTB(W, H);
        Raw.Data := PByte(@FTileBgrBytes[1]);
        Raw.DataSize := Length(FTileBgrBytes);
        Tick := GetTickCount64;
        try
          FTileBitmap.LoadFromRawImage(Raw, False);
          if (FTileBitmap.Width = W) and (FTileBitmap.Height = H) then
          begin
            Inc(FRawImportMs, GetTickCount64 - Tick);
            Tick := GetTickCount64;
            FBitmap.Canvas.Draw(X, Y, FTileBitmap);
            Inc(FBlitMs, GetTickCount64 - Tick);
            Inc(FRawTiles);
            Inc(FTurboTiles);
            Result := True;
            Exit;
          end;
        except
          on E: Exception do
          begin
            // Some older LCL widgetsets have incomplete RawImage import.
            // Disable this fast path for the rest of the session.
            FUseRawImage := False;
            KvmClientLog('[client-video] import RawImage non pris en charge : ' +
              E.Message + ' ; repli sur BMP');
          end;
        end;
      end;
    end;
    // Tested fallback: TurboJPEG into BMP and LCL LoadFromStream.
    if (FTurboDecoder <> nil) and FTurboDecoder.Available and
       FTurboDecoder.DecodeToBmp(Jpeg, W, H, FTileBmpBytes) then
    begin
      Tick := GetTickCount64;
      FJpegStream.Size := Length(FTileBmpBytes);
      FJpegStream.Position := 0;
      FJpegStream.WriteBuffer(FTileBmpBytes[1], Length(FTileBmpBytes));
      FJpegStream.Position := 0;
      FTileBitmap.LoadFromStream(FJpegStream);
      if (FTileBitmap.Width <> W) or (FTileBitmap.Height <> H) then Exit;
      Inc(FRawImportMs, GetTickCount64 - Tick);
      Tick := GetTickCount64;
      FBitmap.Canvas.Draw(X, Y, FTileBitmap);
      Inc(FBlitMs, GetTickCount64 - Tick);
      Inc(FTurboTiles);
    end
    else
    begin
      Tick := GetTickCount64;
      FJpegStream.Size := Length(Jpeg);
      FJpegStream.Position := 0;
      FJpegStream.WriteBuffer(Jpeg[1], Length(Jpeg));
      FJpegStream.Position := 0;
      FJpegImage.LoadFromStream(FJpegStream);
      if (FJpegImage.Width <> W) or (FJpegImage.Height <> H) then Exit;
      Inc(FRawImportMs, GetTickCount64 - Tick);
      Tick := GetTickCount64;
      FBitmap.Canvas.Draw(X, Y, FJpegImage);
      Inc(FBlitMs, GetTickCount64 - Tick);
      Inc(FFallbackTiles);
    end;
    Result := True;
  except
    on E: Exception do SetStatus('JPEG non decode : ' + E.Message);
  end;
end;

function TKvmViewForm.GetVideoRect: TRect;
var
  Scale: Double;
  W, H: Integer;
begin
  Result := Rect(0, 0, 0, 0);
  if (FBitmap.Width = 0) or (FBitmap.Height = 0) or
     (FView.Width < 1) or (FView.Height < 1) then Exit;
  Scale := Min(FView.Width / FBitmap.Width, FView.Height / FBitmap.Height);
  W := Max(1, Round(FBitmap.Width * Scale));
  H := Max(1, Round(FBitmap.Height * Scale));
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
  if (FBitmap.Width < 1) or (FBitmap.Height < 1) then
  begin
    FView.Canvas.Font.Color := clWhite;
    FView.Canvas.TextOut(20, 20, 'En attente du bureau distant...');
    Exit;
  end;
  R := GetVideoRect;
  PaintTick := GetTickCount64;
  // Avoid an unnecessary scaled blit (and interpolation) at native size.
  if ((R.Right-R.Left)=FBitmap.Width) and
     ((R.Bottom-R.Top)=FBitmap.Height) then
    FView.Canvas.Draw(R.Left,R.Top,FBitmap)
  else
    FView.Canvas.StretchDraw(R, FBitmap);
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
