## Shared by the examples: a lock-based bounded queue with an injectable
## check-then-act bug, and one recorded, checked round of 3 threads.

import std/[locks, os]
import nimlinear
import nimlinear/[perturb, models/boundedqueue]
export boundedqueue

const
  threads* = 3
  opsPerThread = 6
  capacity = 4
  prefill = @[100, 101]

type
  Window* = enum
    wSleep     ## buggy dequeue yields the CPU in its window (wide, found fast)
    wNarrow    ## buggy dequeue has only a perturb() point in its window

  Queue = object
    lock: Lock
    items: seq[int]
    capacity: int
    closed: bool
    buggy: bool
    window: Window

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

type
  Hooks* = object
    ## Optional calls at the start and end of each worker (used by the
    ## controlled scheduler). `nil` = no call.
    enter*: proc (tid: int) {.nimcall, gcsafe, raises: [].}
    leave*: proc () {.nimcall, gcsafe, raises: [].}

  Ctx = object
    q: ptr Queue
    rec: ptr Recorder[QueueOp, QueueRes]
    tid: int
    hooks: Hooks

proc worker(c: Ctx) {.thread.} =
  if c.hooks.enter != nil: c.hooks.enter(c.tid)
  for i in 0 ..< opsPerThread:
    if i mod 2 == 0:
      let v = c.tid * 100 + i        # unique values: a duplicate is visible
      discard c.rec[].record(c.tid, enqueue(v)): c.q[].enqueue(v)
    else:
      discard c.rec[].record(c.tid, dequeue()): c.q[].dequeue()
  if c.hooks.leave != nil: c.hooks.leave()

proc runRound*(buggy: bool, window = wSleep, hooks = Hooks()): History[QueueOp, QueueRes] =
  ## Runs one round with 3 threads and returns the recorded history.
  var q = Queue(items: prefill, capacity: capacity, buggy: buggy, window: window)
  initLock q.lock
  var rec = newRecorder[QueueOp, QueueRes](threads)
  var ths: array[threads, Thread[Ctx]]
  for t in 0 ..< threads:
    createThread(ths[t], worker, Ctx(q: addr q, rec: addr rec, tid: t, hooks: hooks))
  joinThreads(ths)
  deinitLock q.lock
  rec.snapshot()

proc check*(h: History[QueueOp, QueueRes]): Verdict[QueueOp, QueueRes] =
  checkLinearizable(h, QueueState(items: prefill, capacity: capacity),
                    QueueModel, budget = 500_000)

proc save*(h: History[QueueOp, QueueRes], name: string): string =
  result = getTempDir() / name
  writeFile(result, h.toJsonLines())
