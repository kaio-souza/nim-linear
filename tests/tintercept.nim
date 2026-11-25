## P6 (D-26): nimlinear/intercept puts switch points on atomic writes and
## lock acquires, so a race in code with no perturb() is found under the
## scheduler. Compiled with -d:nimlinearPerturb (tintercept.nims).
import std/[random, strutils, unittest]
when not compileOption("threads"):
  suite "intercept":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/intercept      # instead of std/[atomics, locks]

  type
    COp = object
      inc: bool
    CRes = object
      value: int
    CState = object
      value: int
    CModel = object
    Kind = enum kAtomic, kRacyAtomic, kLocked, kRacyLocked
    Counter = object
      v: Atomic[int]
      lock: Lock
      plain: int
      kind: Kind

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    if op.inc: Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes(value: s.value + 1))
    else: Expected[CState, CRes](next: s, res: CRes(value: s.value))

  # The objects under test: no perturb() anywhere.
  proc incr(c: var Counter): int =
    case c.kind
    of kAtomic: result = c.v.fetchAdd(1) + 1
    of kRacyAtomic:
      let x = c.v.load          # BUG: load then store
      c.v.store(x + 1)
      result = x + 1
    of kLocked:
      withLock c.lock:
        inc c.plain
        result = c.plain
    of kRacyLocked:
      var x: int
      withLock c.lock: x = c.plain      # BUG: two critical sections
      withLock c.lock: c.plain = x + 1
      result = x + 1

  proc get(c: var Counter): int =
    case c.kind
    of kAtomic, kRacyAtomic: result = c.v.load
    of kLocked, kRacyLocked:
      withLock c.lock: result = c.plain

  const nThreads = 3
  var kind = kAtomic
  proc setup(c: var Counter) =
    c.kind = kind
    initLock c.lock
  proc teardown(c: var Counter) = deinitLock c.lock
  proc genOp(r: var Rand, thread, index: int): COp = COp(inc: r.rand(3) > 0)
  proc exec(c: ptr Counter, op: COp): CRes {.gcsafe.} =
    {.cast(gcsafe).}:
      CRes(value: if op.inc: c[].incr() else: c[].get())

  proc run(k: Kind): RoundsResult[COp, CRes] =
    kind = k
    # D-29: the scheduler is built in; steps are calibrated on round 1
    runRounds(RoundsConfig(threads: nThreads, rounds: 100, opsPerThread: 4, name: "intercept-" & $k,
                           schedule: true, depth: 4),
              CState(), CModel, setup, genOp, exec, teardown)

  suite "intercept":
    test "correct atomic and locked counters pass":
      check run(kAtomic).passed
      check run(kLocked).passed

    test "load-then-store race on an atomic is found without perturb()":
      let r = run(kRacyAtomic)
      check not r.passed
      check r.verdict.kind == vkNotLinearizable

    test "race between two critical sections is found without perturb()":
      let r = run(kRacyLocked)
      check not r.passed
      check r.verdict.kind == vkNotLinearizable

    test "same seed, same failing round (deterministic)":
      check run(kRacyAtomic).rounds == run(kRacyAtomic).rounds
      check run(kRacyLocked).original.toJsonLines == run(kRacyLocked).original.toJsonLines

    test "steps are calibrated to the switch points of a round":
      let r = run(kRacyAtomic)
      check r.steps > 0 and r.steps < 100
      check "PCT steps" in r.describe

    test "Lock and atomics work without a scheduler":
      var c: Counter
      initLock c.lock
      c.kind = kLocked
      check c.incr() == 1
      var f: AtomicFlag
      check not f.testAndSet()
      f.clear()
      var a: Atomic[int]
      a += 2
      a.atomicInc()
      check a.load == 3
      check c.lock.tryAcquire()
      c.lock.release()
      deinitLock c.lock
