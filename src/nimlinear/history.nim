## History types and validation (M1). See docs/API.md and docs/HISTORY.md.

import std/[algorithm, hashes, tables]

type
  ArgumentError* = object of CatchableError
    ## Invalid history (invariants in docs/API.md#history). Does not inherit
    ## from ValueError, which is reserved for malformed JSON in parseJsonLines.

  OpId* = distinct int      ## identifies an operation (invoke + return)
  ThreadId* = distinct int  ## originating thread
  SeqNo* = distinct int     ## global sequence number of the event (D-03, D-19)

  EventKind* = enum ekInvoke, ekReturn, ekTick
    ## `ekTick` is an instantaneous operation (M10): one event, no `return`,
    ## linearized exactly at its `seq`. Used for clock advances.

  Event*[Op, Res] = object
    op*: OpId
    thread*: ThreadId
    seqNo*: SeqNo                 ## called `seq` in prose and in JSON (D-19)
    case kind*: EventKind
    of ekInvoke, ekTick: call*: Op
    of ekReturn: res*: Res

  History*[Op, Res] = object
    events*: seq[Event[Op, Res]]  ## ordered by seq

template defineId(T: typedesc) =
  proc `==`*(a, b: T): bool {.borrow.}
  proc `<`*(a, b: T): bool {.borrow.}
  proc `<=`*(a, b: T): bool {.borrow.}
  proc hash*(x: T): Hash {.borrow.}
  proc `$`*(x: T): string = $int(x)

defineId(OpId)
defineId(ThreadId)
defineId(SeqNo)

proc invokeEvent*[Op, Res](op, thread, seqNo: int, call: Op): Event[Op, Res] =
  Event[Op, Res](op: OpId(op), thread: ThreadId(thread), seqNo: SeqNo(seqNo),
                 kind: ekInvoke, call: call)

proc returnEvent*[Op, Res](op, thread, seqNo: int, res: Res): Event[Op, Res] =
  Event[Op, Res](op: OpId(op), thread: ThreadId(thread), seqNo: SeqNo(seqNo),
                 kind: ekReturn, res: res)

proc tickEvent*[Op, Res](op, thread, seqNo: int, call: Op): Event[Op, Res] =
  Event[Op, Res](op: OpId(op), thread: ThreadId(thread), seqNo: SeqNo(seqNo),
                 kind: ekTick, call: call)

proc `==`*[Op, Res](a, b: Event[Op, Res]): bool =
  if a.kind != b.kind or a.op != b.op or a.thread != b.thread or a.seqNo != b.seqNo:
    return false
  case a.kind
  of ekInvoke, ekTick: a.call == b.call
  of ekReturn: a.res == b.res

proc newHistory*[Op, Res](events: seq[Event[Op, Res]]): History[Op, Res] {.raises: [ArgumentError].} =
  ## Checks the invariants in docs/API.md#history and sorts by seq.
  var evs = events
  evs.sort(proc (a, b: Event[Op, Res]): int = cmp(int(a.seqNo), int(b.seqNo)))
  var invoked = initTable[OpId, ThreadId]()  # op -> thread of the invoke
  var returned = initTable[OpId, bool]()
  var open = initTable[ThreadId, OpId]()     # thread -> open op
  var ticks = initTable[OpId, bool]()
  for i, e in evs:
    if i > 0 and evs[i - 1].seqNo == e.seqNo:
      raise newException(ArgumentError, "seq " & $e.seqNo & " repeated")
    case e.kind
    of ekTick:
      if e.op in invoked or e.op in ticks:
        raise newException(ArgumentError, "op " & $e.op & " is used by more than one invoke or tick")
      ticks[e.op] = true
    of ekInvoke:
      if e.op in invoked or e.op in ticks:
        raise newException(ArgumentError, "op " & $e.op & " has more than one invoke")
      if e.thread in open:
        raise newException(ArgumentError, "thread " & $e.thread & " invokes op " & $e.op &
          " while op " & $open.getOrDefault(e.thread) & " is still open")
      invoked[e.op] = e.thread
      open[e.thread] = e.op
    of ekReturn:
      if e.op in ticks:
        raise newException(ArgumentError, "return of op " & $e.op & ", which is a tick")
      if e.op notin invoked:
        raise newException(ArgumentError, "return of op " & $e.op & " without a previous invoke")
      if e.op in returned:
        raise newException(ArgumentError, "op " & $e.op & " has more than one return")
      if invoked.getOrDefault(e.op) != e.thread:
        raise newException(ArgumentError, "return of op " & $e.op & " on a different thread than its invoke")
      returned[e.op] = true
      open.del(e.thread)
  History[Op, Res](events: evs)
