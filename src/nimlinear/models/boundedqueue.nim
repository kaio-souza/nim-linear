## `BoundedQueue` model: enqueue, dequeue, close. See docs/MODELS.md#boundedqueue.

import std/[hashes, json, random]
import ../model

type
  QueueOpKind* = enum qEnqueue, qDequeue, qClose
  QueueOp* = object
    case kind*: QueueOpKind
    of qEnqueue: value*: int
    of qDequeue, qClose: discard
  QueueResKind* = enum qrOk, qrFull, qrClosed, qrValue, qrEmpty
  QueueRes* = object
    case kind*: QueueResKind
    of qrValue: value*: int
    else: discard
  QueueState* = object
    items*: seq[int]
    capacity*: int
    closed*: bool
  QueueModel* = object

func enqueue*(v: int): QueueOp = QueueOp(kind: qEnqueue, value: v)
func dequeue*(): QueueOp = QueueOp(kind: qDequeue)
func close*(): QueueOp = QueueOp(kind: qClose)

func okRes*(): QueueRes = QueueRes(kind: qrOk)
func fullRes*(): QueueRes = QueueRes(kind: qrFull)
func closedRes*(): QueueRes = QueueRes(kind: qrClosed)
func valueRes*(v: int): QueueRes = QueueRes(kind: qrValue, value: v)
func emptyRes*(): QueueRes = QueueRes(kind: qrEmpty)

func `==`*(a, b: QueueOp): bool =
  if a.kind != b.kind: return false
  case a.kind
  of qEnqueue: a.value == b.value
  of qDequeue, qClose: true

func `==`*(a, b: QueueRes): bool =
  a.kind == b.kind and (a.kind != qrValue or a.value == b.value)

func `==`*(a, b: QueueState): bool =
  a.items == b.items and a.capacity == b.capacity and a.closed == b.closed

func hash*(s: QueueState): Hash =
  var h: Hash = 0
  h = h !& hash(s.items)
  h = h !& hash(s.capacity)
  h = h !& hash(s.closed)
  !$h

func `$`*(op: QueueOp): string =
  case op.kind
  of qEnqueue: "enqueue(" & $op.value & ")"
  of qDequeue: "dequeue()"
  of qClose: "close()"

func `$`*(r: QueueRes): string =
  case r.kind
  of qrOk: "ok"
  of qrFull: "full"
  of qrClosed: "closed"
  of qrValue: "value(" & $r.value & ")"
  of qrEmpty: "empty"

func step*(m: typedesc[QueueModel], s: QueueState, op: QueueOp):
    Expected[QueueState, QueueRes] {.raises: [].} =
  type E = Expected[QueueState, QueueRes]
  case op.kind
  of qEnqueue:
    if s.closed:
      E(next: s, res: closedRes(), why: "queue closed")
    elif s.items.len >= s.capacity:
      E(next: s, res: fullRes(), why: "queue full: " & $s.items.len & " of " & $s.capacity)
    else:
      var n = s
      n.items.add op.value
      E(next: n, res: okRes())
  of qDequeue:
    if s.items.len == 0:
      if s.closed: E(next: s, res: closedRes(), why: "empty and closed")
      else: E(next: s, res: emptyRes(), why: "queue empty")
    else:
      var n = s
      let v = n.items[0]
      n.items.delete(0)
      E(next: n, res: valueRes(v))
  of qClose:
    var n = s
    n.closed = true
    E(next: n, res: okRes())

proc toPayload*(x: QueueOp): JsonNode =
  case x.kind
  of qEnqueue: %*{"kind": "enqueue", "value": x.value}
  of qDequeue: %*{"kind": "dequeue"}
  of qClose: %*{"kind": "close"}

proc fromPayload*(n: JsonNode, t: typedesc[QueueOp]): QueueOp =
  case n["kind"].getStr
  of "enqueue": enqueue(n["value"].getInt)
  of "dequeue": dequeue()
  of "close": close()
  else: raise newException(ValueError, "unknown QueueOp: " & $n)

proc toPayload*(x: QueueRes): JsonNode =
  case x.kind
  of qrOk: %*{"kind": "ok"}
  of qrFull: %*{"kind": "full"}
  of qrClosed: %*{"kind": "closed"}
  of qrValue: %*{"kind": "value", "value": x.value}
  of qrEmpty: %*{"kind": "empty"}

proc fromPayload*(n: JsonNode, t: typedesc[QueueRes]): QueueRes =
  case n["kind"].getStr
  of "ok": okRes()
  of "full": fullRes()
  of "closed": closedRes()
  of "value": valueRes(n["value"].getInt)
  of "empty": emptyRes()
  else: raise newException(ValueError, "unknown QueueRes: " & $n)

proc randomQueueOp*(rng: var Rand, thread, index: int, closePercent = 0): QueueOp =
  ## Default generator (P3): enqueue or dequeue, 50% each (values unique per
  ## thread and index); `closePercent` of operations are `close`.
  if closePercent > 0 and rng.rand(99) < closePercent: close()
  elif rng.rand(1) == 0: enqueue(thread * 1000 + index + 1)
  else: dequeue()

proc genQueueOp*(rng: var Rand, thread, index: int): QueueOp =
  ## `randomQueueOp` without `close`, in the signature `runRounds` expects.
  randomQueueOp(rng, thread, index)
