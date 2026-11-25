## P2/P3 example: an atomic counting semaphore checked against the
## `Semaphore` model, with the default generator `genSemaphoreOp`. The buggy
## `tryAcquire` loads the count and stores `count - 1` later instead of a
## compare-and-swap, so two threads can take the last permit.
##
## Exits with 0 only if the correct semaphore passes and the buggy one is rejected.
##   nim c -r --threads:on examples/semaphore_race.nim

when not compileOption("threads"):
  {.error: "this example needs --threads:on".}

import std/[atomics, os]
import nimlinear
import nimlinear/models/semaphore

const maxPermits = 1

type RealSem = object
  permits: Atomic[int]

var buggy = false

proc setup(s: var RealSem) = s.permits.store(maxPermits)

proc exec(s: ptr RealSem, op: SemOp): SemRes {.gcsafe.} =
  {.cast(gcsafe).}:
    let bug = buggy
  case op.kind
  of semTryAcquire:
    var p = s.permits.load
    if bug:
      if p <= 0: return SemRes(ok: false)
      sleep(0)                          # BUG: load, then store, no CAS
      s.permits.store(p - 1)
      return SemRes(ok: true)
    while p > 0:
      if s.permits.compareExchange(p, p - 1): return SemRes(ok: true)
    SemRes(ok: false)
  of semRelease:
    var p = s.permits.load
    while p < maxPermits:
      if s.permits.compareExchange(p, p + 1): return SemRes(ok: true)
    SemRes(ok: false)

let cfg = RoundsConfig(threads: 3, rounds: 300, opsPerThread: 4, name: "semaphore")
buggy = false
let good = runRounds(cfg, initSemState(maxPermits), SemaphoreModel, setup, genSemaphoreOp, exec)
echo "correct semaphore: ", good.describe
buggy = true
let bad = runRounds(cfg, initSemState(maxPermits), SemaphoreModel, setup, genSemaphoreOp, exec)
echo "buggy semaphore: ", bad.describe
quit(if good.passed and not bad.passed and bad.verdict.kind == vkNotLinearizable: 0 else: 1)
