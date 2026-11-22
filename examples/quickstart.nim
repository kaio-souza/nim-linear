# Quickstart: check a shared register under real threads.
# nim c -r --threads:on examples/quickstart.nim
import std/[locks, random]
import nimlinear
import nimlinear/models/register

type Reg = object      # the object under test: a register behind a lock
  lock: Lock
  value: int

proc setup(r: var Reg) = initLock r.lock
proc teardown(r: var Reg) = deinitLock r.lock

proc genOp(rng: var Rand, thread, index: int): RegOp =
  case rng.rand(2)
  of 0: read()
  of 1: write(rng.rand(1..3))
  else: cas(rng.rand(0..3), rng.rand(1..3))

proc exec(r: ptr Reg, op: RegOp): RegRes {.gcsafe.} =
  withLock r.lock:
    result = RegRes(ok: true)
    case op.kind
    of rRead: result.value = r.value
    of rWrite: r.value = op.value
    of rCas:
      if r.value == op.expected: r.value = op.desired
      else: result.ok = false

let res = runRounds(RoundsConfig(threads: 3, rounds: 100, opsPerThread: 4),
                    RegState(value: 0), RegisterModel, setup, genOp, exec, teardown)
echo res.describe           # on failure: shrunk report, timeline, saved file
quit(if res.passed: 0 else: 1)
