## P1 example: recording async code (std/asyncdispatch). See docs/ASYNC.md.
##
## Three async tasks share one counter on one OS thread. Each task is one
## logical "thread" of the history: it gets its own Recorder index, and
## `begin`/`finish` surround the whole async operation, `await`s included.
## The buggy `increment` reads, awaits, then writes, so another task can
## run in between and an increment is lost.
##
## Exits with 0 only if the correct counter passes every round and the buggy
## one is rejected.
##   nim c -r --threads:on examples/async_counter.nim

when not compileOption("threads"):
  {.error: "the Recorder needs --threads:on (even for one OS thread)".}

import std/[asyncdispatch, random]
import nimlinear

type
  COp = object
    inc: bool          ## false: read
  CRes = object
    value: int
  CState = object
    value: int
  CounterModel = object
  AsyncCounter = ref object
    value: int
    buggy: bool

func step(m: typedesc[CounterModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
  if op.inc: Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes(value: s.value + 1))
  else: Expected[CState, CRes](next: s, res: CRes(value: s.value))

proc increment(c: AsyncCounter): Future[int] {.async.} =
  if c.buggy:
    let x = c.value
    await sleepAsync(0)            # BUG: suspension point between read and write
    c.value = x + 1
    return x + 1
  c.value += 1                     # no await between read and write
  let v = c.value                  # take the result before suspending: after the
  await sleepAsync(0)              # await, c.value may include other increments
  return v

proc read(c: AsyncCounter): Future[int] {.async.} =
  await sleepAsync(0)
  return c.value

proc task(c: AsyncCounter, rec: ptr Recorder[COp, CRes], index: int, ops: seq[COp]) {.async.} =
  for op in ops:
    # Operation boundary: begin before the first step of the call, finish
    # after its last await. Never begin in one task and finish in another.
    let id = rec[].begin(index, op)
    let v = if op.inc: await c.increment() else: await c.read()
    rec[].finish(id, CRes(value: v))

proc round(buggy: bool, seed: int): History[COp, CRes] =
  const tasks = 3
  var rng = initRand(seed)
  var rec = newRecorder[COp, CRes](tasks)    # one index per task, not per OS thread
  let c = AsyncCounter(buggy: buggy)
  var fs: seq[Future[void]]
  for t in 0 ..< tasks:
    var ops: seq[COp]
    for _ in 0 ..< 4: ops.add COp(inc: rng.rand(2) > 0)
    fs.add task(c, addr rec, t, ops)
  waitFor all(fs)
  rec.snapshot()

proc run(buggy: bool): bool =
  ## true if every round is linearizable
  for seed in 1 .. 50:
    let h = round(buggy, seed)
    let v = checkLinearizable(h, CState(), CounterModel)
    if v.kind != vkLinearizable:
      let small = shrink(h, CState(), CounterModel)
      echo "seed ", seed, ":\n", report(checkLinearizable(small, CState(), CounterModel), small)
      return false
  true

let good = run(buggy = false)
echo "correct counter: ", (if good: "linearizable in all rounds" else: "FAILED")
let bad = run(buggy = true)
echo "buggy counter: ", (if bad: "passed (bug not found)" else: "rejected")
quit(if good and not bad: 0 else: 1)
