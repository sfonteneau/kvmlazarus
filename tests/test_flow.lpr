program test_flow;

{$mode objfpc}{$H+}

uses SysUtils, kvm_wire, kvm_flow;

procedure Check(Condition: Boolean; const Msg: string);
begin
  if not Condition then
  begin
    WriteLn('FAIL: ', Msg);
    Halt(1);
  end;
end;

var
  State: TKvmFlowState;
  Batch: TKvmFlowBatch;
  Cache: array of RawByteString;
  Versions: array of Cardinal;
  Groups: array of Integer;
  I, Batches, Received: Integer;
  LastSerial: Cardinal;
  Bytes: Integer;
begin
  SetLength(Cache, 30);
  SetLength(Versions, 30);
  SetLength(Groups, 30);
  for I := 0 to 29 do
  begin
    Cache[I] := MakeTile(0, 0, 1, 1, #$ff + #$d8 + #$ff + #$d9);
    Versions[I] := 1;
    Groups[I] := I;
  end;
  InitFlow(State);
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23, 1000, Batch),
    'initial snapshot');
  Check(Batch.SendScreen and Batch.SendCursor, 'initial S and C');
  Check(Length(Batch.Indices) = 20, 'first ACK can cover 20 small rectangles');
  Check((Length(Batch.Indices) > 0) and
    (Length(Batch.Indices) <= KVM_BATCH_MAX_TILES), 'bounded tiles');
  Check(not PrepareFlowBatch(State, Cache, Versions, Groups, True, 18, 24,
    1001, Batch), 'no second batch before ACK');
  Check(not AcknowledgeFlowBatch(State, 999), 'wrong ACK rejected');
  Check(FlowTimedOut(State, 21001), 'stalled viewer times out');
  Check(not FlowTimedOut(State, 1005), 'fresh flight is not timed out');
  LastSerial := State.FlightSerial;
  Check(AcknowledgeFlowBatch(State, LastSerial), 'first batch ACK');
  Check(not AcknowledgeFlowBatch(State, LastSerial), 'duplicate ACK rejected');
  Batches := 1;
  Received := 0;
  for I := 0 to High(State.AckedVersions) do
    if State.AckedVersions[I] = 1 then Inc(Received);
  while PrepareFlowBatch(State, Cache, Versions, Groups, True, 17, 23,
      1000 + Batches, Batch) do
  begin
    Inc(Batches);
    Check(Batches < 15, 'batch progress / no starvation');
    Check(not Batch.SendScreen, 'only first batch sends screen');
    Check(Length(Batch.Indices) <= KVM_BATCH_MAX_TILES, 'batch tile cap');
    Inc(Received, Length(Batch.Indices));
    Check(AcknowledgeFlowBatch(State, Batch.Serial), 'ACK next batch');
  end;
  Check(Received = 30, 'all thirty tiles reconstructed');
  Check(not State.WaitingAck, 'no in-flight on unchanged screen');

  // Size cap is independent of the tile-count cap.
  for I := 0 to 29 do
  begin
    Cache[I] := StringOfChar('x', 750000);
    Inc(Versions[I]);
  end;
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, False, 0, 0,
    1500, Batch), 'large tile batch');
  Bytes := 0;
  for I := 0 to High(Batch.Indices) do
    Inc(Bytes, Length(Cache[Batch.Indices[I]]));
  Check(Bytes <= KVM_BATCH_MAX_BYTES, 'outgoing byte cap');
  Check(Length(Batch.Indices) <= 4, 'byte cap limits selected count');
  Check(AcknowledgeFlowBatch(State, Batch.Serial), 'ACK large batch');
  while PrepareFlowBatch(State, Cache, Versions, Groups, False, 0, 0,
      1510, Batch) do
    Check(AcknowledgeFlowBatch(State, Batch.Serial), 'drain large batches');

  Inc(Versions[0]);
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, False, 0, 0,
    2000, Batch), 'changed tile');
  Check(Length(Batch.Indices) = 1, 'send changed tile only');
  LastSerial := Batch.Serial;
  Inc(Versions[0]); // another update while the first one is in flight
  Check(AcknowledgeFlowBatch(State, LastSerial), 'ACK old version');
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, False, 0, 0,
    2001, Batch), 'newer version not lost');
  Check(Length(Batch.Indices) = 1, 'newer version sent');
  Check(AcknowledgeFlowBatch(State, Batch.Serial), 'ACK new version');

  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 44, 55,
    3000, Batch), 'cursor-only batch');
  Check(Batch.SendCursor and (Length(Batch.Indices) = 0), 'cursor only');
  Check(AcknowledgeFlowBatch(State, Batch.Serial), 'ACK cursor');
  Check(not PrepareFlowBatch(State, Cache, Versions, Groups, True, 44, 55,
    3001, Batch), 'no repeated cursor after ACK');

  InvalidateFlowGeometry(State);
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 44, 55,
    4000, Batch), 'geometry reset');
  Check(Batch.SendScreen, 'send new S on geometry reset');
  InvalidateFlowGeometry(State);
  Check(not PrepareFlowBatch(State, Cache, Versions, Groups, True, 44, 55,
    4001, Batch), 'geometry change cannot pile up behind unacked batch');
  LastSerial := State.FlightSerial;
  Check(RequestFlowReset(State, 6000), 'refresh queued behind in-flight batch');
  Check(State.WaitingAck, 'refresh never abandons flight');
  Check(not PrepareFlowBatch(State, Cache, Versions, Groups, True, 44, 55,
    6001, Batch), 'refresh cannot pile up another snapshot');
  Check(not RejectFlowBatch(State, LastSerial + 1), 'wrong NACK ignored');
  Check(RejectFlowBatch(State, LastSerial), 'NACK releases only matching flight');
  Check(not AcknowledgeFlowBatch(State, LastSerial), 'ACK of rejected flight ignored');
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, True, 44, 55,
    6002, Batch, 1), 'small budget still sends one indivisible JPEG');
  Check(Batch.SendScreen and (Length(Batch.Indices) = 1), 'bounded restart makes progress');
  Check(not RequestFlowReset(State, 7000), 'refresh rate limited');
  Check(AcknowledgeFlowBatch(State, Batch.Serial), 'ACK after NACK works');
  // One merged rectangle is sent ONCE and ACKs all of its constituent tiles.
  InitFlow(State);
  for I := 1 to 3 do Groups[I] := 0;
  Cache[0] := MakeTile(0, 0, 512, 512, #$ff + #$d8 + #$ff + #$d9);
  Cache[1] := Cache[0];
  Cache[2] := Cache[0];
  Cache[3] := Cache[0];
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, False, 0, 0,
    13000, Batch), 'merged group initial batch');
  for I := 0 to High(Batch.Indices) do
    Check(not (Batch.Indices[I] in [1,2,3]), 'no duplicated grouped jpeg');
  Check(AcknowledgeFlowBatch(State, Batch.Serial), 'merged group ACK');
  Check((State.AckedVersions[0] = Versions[0]) and
    (State.AckedVersions[3] = Versions[3]), 'all members acknowledged');
  // Drain other initial leaders before checking the single group update.
  while PrepareFlowBatch(State, Cache, Versions, Groups, False, 0, 0,
      14000, Batch) do
    Check(AcknowledgeFlowBatch(State, Batch.Serial), 'drain groups');
  Inc(Versions[2]);
  Check(PrepareFlowBatch(State, Cache, Versions, Groups, False, 0, 0,
    15000, Batch), 'member changed');
  Check((Length(Batch.Indices) = 1) and (Batch.Indices[0] = 0),
    'one image for any changed group member');
  Check(AcknowledgeFlowBatch(State, Batch.Serial), 'group update ACK');
  Check(State.AckedVersions[2] = Versions[2], 'modified member ACK');
  WriteLn('OK: grouped flow, ACK, stale batches, cursor and resync');
end.
