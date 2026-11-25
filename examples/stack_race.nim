## P2/P3 example: a lock-based stack checked against the `Stack` model, with
## the default generator `genStackOp`. The buggy `pop` reads the top in one
## critical section and removes it in another (check-then-act), so two
## threads can pop the same value.
##
## Exits with 0 only if the correct stack passes and the buggy one is rejected.
##   nim c -r --threads:on examples/stack_race.nim

when not compileOption("threads"):
  {.error: "this example needs --threads:on".}

import std/[locks, os]
import nimlinear
import nimlinear/models/stack

type RealStack = object
  lock: Lock
  items: seq[int]

var buggy = false

proc setup(s: var RealStack) = initLock s.lock
proc teardown(s: var RealStack) = deinitLock s.lock

proc exec(s: ptr RealStack, op: StackOp): StackRes {.gcsafe.} =
  {.cast(gcsafe).}:
    let bug = buggy
  case op.kind
  of sPush:
    withLock s.lock: s.items.add op.value
    pushed()
  of sPop:
    if not bug:
      withLock s.lock:
        return (if s.items.len == 0: empty() else: popped(s.items.pop()))
    var v: int
    withLock s.lock:
      if s.items.len == 0: return empty()
      v = s.items[^1]
    sleep(0)                            # BUG: the top is removed later
    withLock s.lock:
      let i = s.items.find(v)
      if i >= 0: s.items.delete(i)
    popped(v)

let cfg = RoundsConfig(threads: 3, rounds: 300, opsPerThread: 6, name: "stack")
buggy = false
let good = runRounds(cfg, StackState(), StackModel, setup, genStackOp, exec, teardown)
echo "correct stack: ", good.describe
buggy = true
let bad = runRounds(cfg, StackState(), StackModel, setup, genStackOp, exec, teardown)
echo "buggy stack: ", bad.describe
quit(if good.passed and not bad.passed and bad.verdict.kind == vkNotLinearizable: 0 else: 1)
