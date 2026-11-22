## Shared by the examples: a lock-based bounded queue with an injectable
## check-then-act bug, plus the pieces `runRounds` needs.

import std/[locks, os, random]
import nimlinear
import nimlinear/[perturb, models/boundedqueue]
export boundedqueue

const prefill* = @[100, 101]

type
  Window* = enum
    wSleep     ## buggy dequeue yields the CPU in its window (wide, found fast)
    wNarrow    ## buggy dequeue has only a perturb() point in its window

  Queue* = object
    lock: Lock
    items: seq[int]
    capacity: int
    closed: bool
    buggy: bool
    window: Window

var mode* = (buggy: false, window: wSleep)   ## set before running rounds

proc setup*(q: var Queue) =
  initLock q.lock
  q.items = prefill
  q.capacity = 4
  q.buggy = mode.buggy
  q.window = mode.window

proc teardown*(q: var Queue) = deinitLock q.lock

let initState* = QueueState(items: prefill, capacity: 4)

proc enqueue(q: var Queue, v: int): QueueRes =
  perturb()                               # outside the lock (see schedule rules)
  withLock q.lock:
    if q.closed: return closedRes()
    if q.items.len >= q.capacity: return fullRes()
    q.items.add v
    result = okRes()

proc dequeue(q: var Queue): QueueRes =
  perturb()
  if not q.buggy:
    withLock q.lock:
      if q.items.len == 0:
        return (if q.closed: closedRes() else: emptyRes())
      let v = q.items[0]
      q.items.delete(0)
      return valueRes(v)
  # BUG: the read and the removal are two separate critical sections.
  var v: int
  withLock q.lock:
    if q.items.len == 0:
      return (if q.closed: closedRes() else: emptyRes())
    v = q.items[0]
  case q.window
  of wSleep: sleep(0)
  of wNarrow: perturb()
  withLock q.lock:
    if q.items.len > 0: q.items.delete(0)
  valueRes(v)

proc genOp*(rng: var Rand, thread, index: int): QueueOp =
  ## Enqueue (unique values, so a duplicate is visible) or dequeue.
  if rng.rand(1) == 0: enqueue(thread * 1000 + index) else: dequeue()

proc exec*(q: ptr Queue, op: QueueOp): QueueRes {.gcsafe.} =
  case op.kind
  of qEnqueue: q[].enqueue(op.value)
  of qDequeue: q[].dequeue()
  of qClose: okRes()

proc config*(rounds: int, seed = 1, name = "queue"): RoundsConfig =
  RoundsConfig(threads: 3, rounds: rounds, opsPerThread: 6, seed: seed,
               budget: 500_000, name: name)
