## M8 end-to-end example: a real lock-based bounded queue, recorded from
## several threads and checked against the `BoundedQueue` model.
##
## The queue has an injectable bug: with `buggy = true`, `dequeue` reads the
## head under the lock, releases it, and removes the head later under a second
## lock (check-then-act). Two threads can then dequeue the same value.
##
## The program runs both versions and exits with 0 only if:
## - the correct queue is linearizable in every round, and
## - the buggy queue is rejected in some round (its report is printed).
##
## Run: nim c -r --threads:on examples/queue_race.nim

when not compileOption("threads"):
  {.error: "this example needs --threads:on".}

import std/[locks, os]
import nimlinear
import nimlinear/models/boundedqueue

const
  threads = 3
  opsPerThread = 6
  capacity = 4
  prefill = @[100, 101]
  rounds = 300

# ---------------------------------------------------------------- the object

type
  Queue = object
    lock: Lock
    items: seq[int]
    capacity: int
    closed: bool
    buggy: bool

proc initQueue(q: var Queue, capacity: int, buggy: bool) =
  initLock q.lock
  q.items = prefill
  q.capacity = capacity
  q.buggy = buggy

proc enqueue(q: var Queue, v: int): QueueRes =
  withLock q.lock:
    if q.closed: return closedRes()
    if q.items.len >= q.capacity: return fullRes()
    q.items.add v
    result = okRes()

proc dequeue(q: var Queue): QueueRes =
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
  sleep(0)                  # yields the CPU: widens the window; the bug exists without it
  withLock q.lock:
    if q.items.len > 0: q.items.delete(0)
  valueRes(v)

# ---------------------------------------------------------------- the test

type Ctx = object
  q: ptr Queue
  rec: ptr Recorder[QueueOp, QueueRes]
  tid: int

proc worker(c: Ctx) {.thread.} =
  for i in 0 ..< opsPerThread:
    if i mod 2 == 0:
      let v = c.tid * 100 + i        # unique values: a duplicate is visible
      let id = c.rec[].begin(c.tid, enqueue(v))
      c.rec[].finish(id, c.q[].enqueue(v))
    else:
      let id = c.rec[].begin(c.tid, dequeue())
      c.rec[].finish(id, c.q[].dequeue())

proc round(buggy: bool): Verdict[QueueOp, QueueRes] =
  var q: Queue
  q.initQueue(capacity, buggy)
  var rec = newRecorder[QueueOp, QueueRes](threads)
  var ths: array[threads, Thread[Ctx]]
  for t in 0 ..< threads:
    createThread(ths[t], worker, Ctx(q: addr q, rec: addr rec, tid: t))
  joinThreads(ths)
  deinitLock q.lock
  let h = rec.snapshot()
  result = checkLinearizable(h, QueueState(items: prefill, capacity: capacity),
                             QueueModel, budget = 500_000)
  if result.kind != vkLinearizable:
    writeFile(getTempDir() / "queue_race_failure.jsonl", h.toJsonLines())

proc main(): int =
  for r in 1 .. rounds:
    let v = round(buggy = false)
    if v.kind != vkLinearizable:
      echo "correct queue rejected in round ", r, ":\n", v.report
      return 1
  echo "correct queue: linearizable in all ", rounds, " rounds"

  for r in 1 .. rounds:
    let v = round(buggy = true)
    case v.kind
    of vkNotLinearizable:
      echo "buggy queue: rejected in round ", r
      echo v.report
      echo "history saved to ", getTempDir() / "queue_race_failure.jsonl"
      return 0
    of vkInconclusive:
      echo "buggy queue: round ", r, " inconclusive:\n", v.report
      return 1
    of vkLinearizable: discard
  echo "buggy queue: bug not found in ", rounds, " rounds"
  1

quit main()
