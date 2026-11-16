{ A parallel for: Run(i) for i = 0 .. n - 1 on up to `threads` threads
  (the calling one among them), each taking the next i as it finishes. With
  one thread, or one item, everything runs here, in order, without a thread.
  An exception in an item is caught and given back: the first one raised
  again in the caller once all are done (an EOutOfMemory as one, the others
  as Exception). The program needs cthreads first
  in its uses on Unix (the ppa command has it). }
unit ppathreads;

{$I ppa.inc}

interface

uses SysUtils, Classes, ppajoin;

type
  TItemProc = procedure(i: SizeInt) is nested;

procedure ParallelFor(n: SizeInt; threads: Integer; run: TItemProc);

var
  { run by every worker thread as it ends: PJA's codec keeps its models in
    threadvars, which FreePascal does not free when a thread ends; ppacodec
    sets this to pjamodel.ReleaseThreadModels }
  OnThreadEnd: procedure = nil;

implementation

type
  TShared = record
    next: LongInt;     { LongInt: what InterlockedIncrement takes everywhere }
    n: LongInt;
    run: TItemProc;
    failure: string;
    failed: LongInt;
    { the first failure was memory the system did not give }
    noMemory: Boolean;
  end;
  PShared = ^TShared;

  { joined without TThread.WaitFor's 100 ms naps (ppajoin) }
  TWorker = class(TJoinThread)
    sh: PShared;
    procedure Execute; override;
  end;

procedure Work(sh: PShared);
var i: LongInt;
begin
  repeat
    i := InterlockedIncrement(sh^.next) - 1;
    if i >= sh^.n then Break;
    try
      sh^.run(i);
    except
      on e: Exception do
        if InterlockedIncrement(sh^.failed) = 1 then begin
          sh^.failure := e.ClassName + ': ' + e.Message;
          sh^.noMemory := e is EOutOfMemory;
        end;
    end;
  until False;
end;

procedure TWorker.Execute;
begin
  Work(sh);
  if Assigned(OnThreadEnd) then OnThreadEnd;
end;

procedure ParallelFor(n: SizeInt; threads: Integer; run: TItemProc);
var sh: TShared; pool: array of TWorker; i, k: Integer;
begin
  if n <= 0 then Exit;
  if n > High(LongInt) then raise ERangeError.Create('ParallelFor: too many items');
  if (threads <= 1) or (n = 1) then begin
    for i := 0 to n - 1 do run(i);
    Exit;
  end;
  sh.next := 0; sh.n := n; sh.run := run; sh.failure := ''; sh.failed := 0; sh.noMemory := False;
  k := threads;
  if k > n then k := n;
  pool := nil;
  SetLength(pool, k - 1);
  { a thread the system refuses (a host at its limit) leaves the items to
    the ones it gave and to this one: the same result, only slower }
  k := 0;
  while k < Length(pool) do begin
    try
      pool[k] := TWorker.Create(True);
    except
      on EThread do Break;
    end;
    pool[k].sh := @sh;
    pool[k].Start;
    Inc(k);
  end;
  SetLength(pool, k);
  Work(@sh);
  for i := 0 to High(pool) do begin pool[i].Join; pool[i].Free; end;
  { memory stays memory (the caller tells it from a damaged input) }
  if sh.failed > 0 then
    if sh.noMemory then raise EOutOfMemory.Create(sh.failure) else raise Exception.Create(sh.failure);
end;

end.
