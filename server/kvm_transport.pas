unit kvm_transport;

{$mode objfpc}{$H+}

// Bounded, all-or-nothing application enqueue using mORMot's public frame
// list and protected live-connection list. No patch to mORMot is required.
interface
uses SysUtils, mormot.core.base, mormot.core.os,
  mormot.net.http, mormot.net.server, mormot.net.ws.core, mormot.net.ws.server;
const
  KVM_OUTGOING_MAX_BYTES = 4 * 1024 * 1024;
  KVM_OUTGOING_MAX_FRAMES = 64;
type
  TKvmWebSocketServer = class(TWebSocketServer)
  public
    procedure AbortConnection(ID: THttpServerConnectionID);
    function TryQueue(ID: THttpServerConnectionID;
      const Frames: TWebSocketFrameDynArray): Boolean;
    function TryQueueText(ID: THttpServerConnectionID; const Text: RawByteString): Boolean;
  end;
implementation

type PKvmProcess = ^TWebSocketProcessServer;

procedure TKvmWebSocketServer.AbortConnection(ID: THttpServerConnectionID);
var P: PKvmProcess; I: Integer;
begin
  // Abort does not flush a potentially blocked outgoing queue. The owner
  // thread does final cleanup. The read lock keeps the process alive.
  fWebSocketConnections.Safe.ReadOnlyLock;
  try
    P:=Pointer(fWebSocketConnections.List);
    for I:=1 to fWebSocketConnections.Count do
    begin
      if P^.Protocol.ConnectionID=ID then
      begin
        P^.ConnectionCloseWasSent:=True;
        P^.Socket.Abort;
        Exit;
      end;
      Inc(P);
    end;
  finally fWebSocketConnections.Safe.ReadOnlyUnLock; end;
end;

function TKvmWebSocketServer.TryQueue(ID: THttpServerConnectionID;
  const Frames: TWebSocketFrameDynArray): Boolean;
var P: PKvmProcess; I, J, N: Integer; Bytes: Int64; Q: TWebSocketFrameList;
begin
  Result := False;
  if Terminated or (Length(Frames) = 0) or
     (Length(Frames) > KVM_OUTGOING_MAX_FRAMES) then Exit;
  Bytes := 0;
  for I := 0 to High(Frames) do
  begin
    if not (Frames[I].opcode in [focBinary, focText]) then Exit;
    Inc(Bytes, Length(Frames[I].payload));
  end;
  if Bytes > KVM_OUTGOING_MAX_BYTES then Exit;
  // Protect the process lifetime: never retain a process pointer after the
  // connection-list read lock is released.
  fWebSocketConnections.Safe.ReadOnlyLock;
  try
    P := Pointer(fWebSocketConnections.List);
    for I := 1 to fWebSocketConnections.Count do
    begin
      if (P^.State = wpsRun) and (P^.Protocol.ConnectionID = ID) then
      begin
        Q := P^.Outgoing;
        // SendPending holds this lock during socket writes. A slow viewer
        // must not block the capture thread or unrelated viewers.
        if not Q.Safe.TryLock then Exit;
        try
          N := Q.Count;
          if (N < 0) or (N > Length(Q.List)) or
             (N + Length(Frames) > KVM_OUTGOING_MAX_FRAMES) then Exit;
          for J := 0 to N - 1 do Inc(Bytes, Length(Q.List[J].payload));
          if Bytes > KVM_OUTGOING_MAX_BYTES then Exit;
          if Length(Q.List) < N + Length(Frames) then
            SetLength(Q.List, N + Length(Frames));
          try
            for J := 0 to High(Frames) do
            begin
              Q.List[N + J].opcode := Frames[J].opcode;
              Q.List[N + J].content := Frames[J].content;
              // SendFrame may mutate the payload (compression/masking).
              // Never share its writable bytes with an immutable JPEG cache.
              FastSetRawByteString(Q.List[N + J].payload,
                Pointer(Frames[J].payload), Length(Frames[J].payload));
              Q.List[N + J].tix := 0; // mORMot outgoing list has timeoutsec=0
            end;
          except
            // Do not retain partially allocated payloads beyond Q.Count.
            // The already queued prefix is unchanged; nothing new is visible.
            for J := N to N + Length(Frames) - 1 do Q.List[J].payload := '';
            raise;
          end;
          Q.Count := N + Length(Frames);
          Result := True;
        finally Q.Safe.UnLock; end;
        Exit;
      end;
      Inc(P);
    end;
  finally fWebSocketConnections.Safe.ReadOnlyUnLock; end;
end;

function TKvmWebSocketServer.TryQueueText(ID: THttpServerConnectionID;
  const Text: RawByteString): Boolean;
var Frames: TWebSocketFrameDynArray;
begin
  SetLength(Frames, 1);
  Frames[0].opcode := focText; Frames[0].content := [];
  Frames[0].tix := 0; Frames[0].payload := Text;
  Result := TryQueue(ID, Frames);
end;
end.
