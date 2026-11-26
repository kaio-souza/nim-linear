## P10: a model built from a sequential implementation gives the same verdicts
## as the hand-written BoundedQueue model. Compiled with -d:nimlinearDebug
## (tseqmodel.nims), so the aliasing guard is on.
import std/[hashes, random, unittest]
import nimlinear
import nimlinear/seqmodel
import nimlinear/models/boundedqueue
import ./oracle/oracle

# A plain sequential bounded queue, written as one would write the real thing.
type SeqQueue = object
  items: seq[int]
  capacity: int
  closed: bool

proc apply(q: var SeqQueue, op: QueueOp): QueueRes =
  case op.kind
  of qEnqueue:
    if q.closed: closedRes()
    elif q.items.len >= q.capacity: fullRes()
    else:
      q.items.add op.value
      okRes()
  of qDequeue:
    if q.items.len == 0: (if q.closed: closedRes() else: emptyRes())
    else:
      let v = q.items[0]
      q.items.delete(0)
      valueRes(v)
  of qClose:
    q.closed = true
    okRes()

func hash(q: SeqQueue): Hash = !$(hash(q.items) !& hash(q.capacity) !& hash(q.closed))

sequentialModel(QueueSpec, SeqQueue, QueueOp, QueueRes, apply)

# A state with a ref inside: copies share it, which the guard must catch.
type
  Box = ref object
    items: seq[int]
  RefQueue = object
    box: Box

proc applyRef(q: var RefQueue, op: QueueOp): QueueRes =
  if op.kind == qEnqueue:
    q.box.items.add op.value
    okRes()
  else:
    emptyRes()

func hash(q: RefQueue): Hash = hash(q.box.items)
func `==`(a, b: RefQueue): bool = a.box.items == b.box.items

sequentialModel(RefSpec, RefQueue, QueueOp, QueueRes, applyRef)

proc queueOp(r: var Rand): QueueOp =
  case r.rand(9)
  of 0..4: enqueue(r.rand(0..2))
  of 5..8: dequeue()
  else: close()

proc queueOther(r: var Rand, res: QueueRes): QueueRes =
  let all = @[okRes(), fullRes(), closedRes(), emptyRes(),
              valueRes(0), valueRes(1), valueRes(2)]
  while true:
    result = all[r.rand(all.len - 1)]
    if not (result == res): return

suite "sequentialModel (P10)":
  test "same verdicts as the hand-written model on 10,000 random histories":
    var lin, notLin = 0
    for seed in 0 ..< 10_000:
      var rng = initRand(seed)
      let cap = rng.rand(1..2)
      let (h, _) = generate(rng, QueueState(capacity: cap), QueueModel, queueOp, queueOther)
      let hand = checkLinearizable(h, QueueState(capacity: cap), QueueModel)
      let spec = checkLinearizable(h, SeqQueue(capacity: cap), QueueSpec)
      if hand.kind != spec.kind: checkpoint("seed=" & $seed)
      check hand.kind == spec.kind
      if spec.kind == vkLinearizable: inc lin else: inc notLin
    check lin > 1000 and notLin > 1000

  test "a state that shares memory through a ref is caught (nimlinearDebug)":
    let h = newHistory(@[
      invokeEvent[QueueOp, QueueRes](1, 0, 1, enqueue(1)),
      returnEvent[QueueOp, QueueRes](1, 0, 2, okRes())])
    expect AssertionDefect:
      discard checkLinearizable(h, RefQueue(box: Box()), RefSpec)
