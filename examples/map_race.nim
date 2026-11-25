## P2/P3 example: a lock-based map checked against the `Map` model, with the
## default generator `genMapOp` (no hand-written `genOp`) and
## `partitioned: true` (one key at a time). The buggy `put` reads the previous
## entry in one critical section and writes in another, so two concurrent
## puts can both report the same previous value (a lost update).
##
## Exits with 0 only if the correct map passes and the buggy one is rejected.
##   nim c -r --threads:on examples/map_race.nim

when not compileOption("threads"):
  {.error: "this example needs --threads:on".}

import std/[locks, os, tables]
import nimlinear
import nimlinear/models/map

type RealMap = object
  lock: Lock
  t: Table[int, int]

var buggy = false

proc setup(m: var RealMap) = initLock m.lock
proc teardown(m: var RealMap) = deinitLock m.lock

proc exec(m: ptr RealMap, op: MapOp): MapRes {.gcsafe.} =
  {.cast(gcsafe).}:
    let bug = buggy
  template prev(): MapRes =
    (if m.t.hasKey(op.key): found(m.t[op.key]) else: missing())
  case op.kind
  of mGet:
    withLock m.lock: result = prev()
  of mDelete:
    withLock m.lock:
      result = prev()
      m.t.del op.key
  of mPut:
    if not bug:
      withLock m.lock:
        result = prev()
        m.t[op.key] = op.value
    else:
      withLock m.lock: result = prev()
      sleep(0)                          # BUG: the window between read and write
      withLock m.lock: m.t[op.key] = op.value

let cfg = RoundsConfig(threads: 3, rounds: 300, opsPerThread: 6, partitioned: true, name: "map")
buggy = false
let good = runRounds(cfg, initMapState(), MapModel, setup, genMapOp, exec, teardown)
echo "correct map: ", good.describe
buggy = true
let bad = runRounds(cfg, initMapState(), MapModel, setup, genMapOp, exec, teardown)
echo "buggy map: ", bad.describe
quit(if good.passed and not bad.passed and bad.verdict.kind == vkNotLinearizable: 0 else: 1)
