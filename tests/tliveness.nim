## P14: the scheduler turns a stuck round (deadlock, livelock) into a failed
## round with its seed, instead of a hung test. Compiled with
## -d:nimlinearPerturb (tliveness.nims).
import std/[hashes, random, strutils, unittest]
when not compileOption("threads"):
  suite "liveness":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/intercept      # Lock = SchedLock, Cond = SchedCond

  type
    Kind = enum kCorrect, kLostWakeup, kSpin
    LOp = object
      producer: bool
    LRes = object
    LState = object
    LModel = object
    Obj = object
      lock: Lock
      cond: Cond
      ready: bool
      kind: Kind

  func step(m: typedesc[LModel], s: LState, op: LOp): Expected[LState, LRes] {.raises: [].} =
    Expected[LState, LRes](next: s)
  func hash(s: LState): Hash = 0

  var kind = kCorrect
  proc setupObj(o: var Obj) =
    initLock o.lock
    initCond o.cond
    o.kind = kind
  proc teardownObj(o: var Obj) =
    deinitCond o.cond
    deinitLock o.lock
  proc genOp(r: var Rand, thread, index: int): LOp = LOp(producer: thread == 0)

  proc exec(o: ptr Obj, op: LOp): LRes {.gcsafe.} =
    {.cast(gcsafe).}:
      case o.kind
      of kSpin:
        while true: perturb()               # never ends: a livelock
      of kCorrect, kLostWakeup:
        if op.producer:
          if o.kind == kCorrect:
            withLock o.lock:
              o.ready = true
              signal o.cond
          else:
            o.ready = true                  # BUG: set and signal without the lock
            signal o.cond
        else:
          acquire o.lock
          if not o.ready:
            perturb()                       # the window between the check and the wait
            wait(o.cond, o.lock)            # BUG (with the above): `if`, not `while`
          release o.lock
      LRes()

  proc run(k: Kind, explore = true, stepLimit = 1_000_000): RoundsResult[LOp, LRes] =
    kind = k
    runRounds(RoundsConfig(threads: 2, rounds: 1, opsPerThread: 1, explore: explore,
                           schedule: not explore, stepLimit: stepLimit, trackProgress: false,
                           name: "liveness"),
              LState(), LModel, setupObj, genOp, exec, teardownObj)

  suite "liveness (P14)":
    test "correct handshake: every schedule passes":
      let r = run(kCorrect)
      check r.passed
      check r.complete

    test "lost wakeup: found by exploration, reported as a deadlock":
      let r = run(kLostWakeup)
      check not r.passed
      check "deadlock" in r.error
      check "waits on a condition" in r.error
      check r.schedule.len > 0

    test "livelock: stopped at stepLimit, reported with its seed":
      let r = run(kSpin, explore = false, stepLimit = 500)
      check not r.passed
      check "no end after 500 switch points" in r.error
      check "failed in round 1" in r.describe
