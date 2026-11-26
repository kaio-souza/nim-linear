## M17: runRounds on a tiny object: an atomic counter (correct) and a
## read-then-write counter (lost updates). Deterministic: every round runs
## under the PCT scheduler (seeded per round in `setup` from `RoundInfo`), and the racy window
## is a `perturb()` point, so the outcome does not depend on the OS.
## Compiled with -d:nimlinearPerturb (trounds.nims).
import std/[algorithm, atomics, hashes, os, random, strutils, times, unittest]
when not compileOption("threads"):
  suite "rounds":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/[perturb, schedule]

  type
    COp = object
      inc: bool
    CRes = object
      value: int
    CState = object
      value: int
    CModel = object
    Counter = object
      v: Atomic[int]
      racy: bool

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    if op.inc: Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes(value: s.value + 1))
    else: Expected[CState, CRes](next: s, res: CRes(value: s.value))

  var racy = false
  var sched: Scheduler
  var nThreads = 3     # must match the RoundsConfig threads of each test
  proc setupCounter(c: var Counter, info: RoundInfo) =
    c.racy = racy
    sched.initScheduler(nThreads, info.seed, depth = 3, steps = 30)
  var teardowns = 0
  proc teardownCounter(c: var Counter) =
    inc teardowns
    sched.deinitScheduler()
  proc enterHook(tid: int) {.nimcall, gcsafe, raises: [].} =
    {.cast(gcsafe).}: sched.enter(tid)
  proc leaveHook() {.nimcall, gcsafe, raises: [].} =
    {.cast(gcsafe).}: sched.leave()
  let hooks = ThreadHooks(enter: enterHook, leave: leaveHook)
  proc genOp(r: var Rand, thread, index: int): COp = COp(inc: r.rand(3) > 0)
  proc exec(c: ptr Counter, op: COp): CRes {.gcsafe.} =
    if not op.inc: return CRes(value: c.v.load)
    if c.racy:
      let x = c.v.load
      perturb()      # the scheduler may switch threads here
      c.v.store(x + 1)
      CRes(value: x + 1)
    else:
      CRes(value: c.v.fetchAdd(1) + 1)

  let dir = getTempDir() / "nimlinear-trounds"
  removeDir(dir)     # saved histories get -2, -3... suffixes (R9): start clean

  # R1: an object whose exec raises on a given operation index.
  type Boom = object
    calls: Atomic[int]
  var boomAt = 2
  proc setupBoom(b: var Boom) = discard
  proc execBoom(b: ptr Boom, op: COp): CRes {.gcsafe.} =
    {.cast(gcsafe).}:
      if b.calls.fetchAdd(1) == boomAt: raise newException(IOError, "boom")
    CRes(value: 0)
  proc genRead(r: var Rand, thread, index: int): COp = COp(inc: false)

  # R3: two independent keyed counters; only linearizable per key.
  type
    KOp = object
      key: int
      inc: bool
    KModel = object
    KObj = object
      v: array[2, Atomic[int]]
  func step(m: typedesc[KModel], s: CState, op: KOp): Expected[CState, CRes] {.raises: [].} =
    if op.inc: Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes(value: s.value + 1))
    else: Expected[CState, CRes](next: s, res: CRes(value: s.value))
  func partition(m: typedesc[KModel], op: KOp): int = op.key
  proc setupK(o: var KObj) = discard
  proc genK(r: var Rand, thread, index: int): KOp = KOp(key: thread mod 2, inc: r.rand(1) == 0)
  proc execK(o: ptr KObj, op: KOp): CRes {.gcsafe.} =
    if op.inc: CRes(value: o.v[op.key].fetchAdd(1) + 1) else: CRes(value: o.v[op.key].load)

  # R5: object that starts at the round number.
  proc setupBoom2(c: var Counter) = discard
  proc setupFrom(c: var Counter, info: RoundInfo) = c.v.store(info.round)
  proc initFrom(round: int): CState = CState(value: round)
  proc execPlain(c: ptr Counter, op: COp): CRes {.gcsafe.} =
    if op.inc: CRes(value: c.v.fetchAdd(1) + 1) else: CRes(value: c.v.load)

  suite "rounds":
    test "correct object passes every round":
      racy = false
      let r = runRounds(RoundsConfig(rounds: 50, saveDir: dir, name: "ok"), CState(), CModel,
                        setupCounter, genOp, exec, teardownCounter, hooks)
      check r.passed
      check r.rounds == 50
      check teardowns == 50           # teardown runs once per round
      check r.savedTo == ""

    test "racy object fails, is shrunk and saved":
      racy = true
      let r = runRounds(RoundsConfig(rounds: 200, opsPerThread: 12, saveDir: dir, name: "racy"),
                        CState(), CModel, setupCounter, genOp, exec, teardownCounter, hooks)
      check not r.passed
      if not r.passed:
        check r.verdict.kind == vkNotLinearizable
        check r.history.events.len <= r.original.events.len
        check fileExists(r.savedTo)
        if fileExists(r.savedTo):
          let back = parseJsonLines[COp, CRes](readFile(r.savedTo))
          check checkLinearizable(back, CState(), CModel).kind == vkNotLinearizable
        # R16: the recorded history is kept next to the shrunk one.
        if r.history.events.len < r.original.events.len:
          check fileExists(r.originalSavedTo)
          if fileExists(r.originalSavedTo):
            check readFile(r.originalSavedTo) == r.original.toJsonLines()
        else:
          check r.originalSavedTo == ""
        check "failed in round" in r.describe

    test "same seed, same operations":
      var cfg = RoundsConfig(threads: 2, opsPerThread: 3, seed: 9)
      nThreads = 2
      defer: nThreads = 3
      racy = false
      var calls1, calls2: seq[string]
      for e in runRound(cfg, 1, setupCounter, genOp, exec, teardownCounter, hooks).events:
        if e.kind == ekInvoke: calls1.add $e.call & "@" & $e.thread
      for e in runRound(cfg, 1, setupCounter, genOp, exec, teardownCounter, hooks).events:
        if e.kind == ekInvoke: calls2.add $e.call & "@" & $e.thread
      calls1.sort(); calls2.sort()
      check calls1 == calls2

    test "invalid config raises ValueError":
      expect ValueError:
        discard runRounds(RoundsConfig(threads: 0), CState(), CModel, setupCounter, genOp, exec, teardownCounter, hooks)

    test "R1: an exception in exec fails the round and is reported":
      boomAt = 2
      let r = runRounds(RoundsConfig(threads: 2, rounds: 5, opsPerThread: 3, saveDir: dir, name: "boom"),
                        CState(), CModel, setupBoom, genRead, execBoom)
      check not r.passed
      check r.rounds == 1
      check "IOError: boom" in r.error
      check "exec raised" in r.describe

    test "R1: exception under the scheduler: leave runs, no hang":
      boomAt = 1
      racy = false
      proc setupBoomSched(b: var Boom, info: RoundInfo) =
        sched.initScheduler(nThreads, info.seed, depth = 3, steps = 30)
      proc teardownBoom(b: var Boom) = sched.deinitScheduler()
      let r = runRounds(RoundsConfig(rounds: 3, saveDir: dir, name: "boomsched"),
                        CState(), CModel, setupBoomSched, genRead, execBoom, teardownBoom, hooks)
      check not r.passed
      check "boom" in r.error

    test "R1: runRound raises ExecError":
      boomAt = 0
      expect ExecError:
        discard runRound(RoundsConfig(threads: 1, opsPerThread: 2), 1, setupBoom, genRead, execBoom)

    test "R3: partitioned uses checkPartitioned":
      let cfg = RoundsConfig(threads: 2, rounds: 20, opsPerThread: 4, saveDir: dir, name: "keyed")
      var p = cfg
      p.partitioned = true
      check runRounds(p, CState(), KModel, setupK, genK, execK).passed
      check not runRounds(cfg, CState(), KModel, setupK, genK, execK).passed
      var bad = RoundsConfig(rounds: 1, partitioned: true)
      expect ValueError:
        discard runRounds(bad, CState(), CModel, setupBoom, genRead, execBoom)

    test "R4: timeout is passed to the checker":
      let r = runRounds(RoundsConfig(rounds: 5, timeout: initDuration(seconds = 5)),
                        CState(), CModel, setupFrom, genOp, execPlain)
      check not r.passed      # init 0 but object starts at round: not linearizable
      check runRounds(RoundsConfig(rounds: 5, timeout: initDuration(seconds = 5)),
                      initFrom, CModel, setupFrom, genOp, execPlain).passed

    test "R9/R14: no overwrite of a saved history, save errors are reported":
      boomAt = -1
      let d = dir / "unique"
      removeDir(d)
      let cfg = RoundsConfig(rounds: 1, saveDir: d, name: "u")
      let a = runRounds(cfg, CState(), CModel, setupFrom, genOp, execPlain)
      let b = runRounds(cfg, CState(), CModel, setupFrom, genOp, execPlain)
      check a.savedTo.len > 0 and b.savedTo.len > 0
      check a.savedTo != b.savedTo
      writeFile(dir / "afile", "")
      let c = runRounds(RoundsConfig(rounds: 1, saveDir: dir / "afile" / "sub", name: "u"),
                        CState(), CModel, setupFrom, genOp, execPlain)
      check c.savedTo == ""
      check c.saveError.len > 0
      check "history not saved" in c.describe

    test "R15: roundSeed has no overflow and no trivial collisions":
      check roundSeed(high(int), high(int)) > 0
      check roundSeed(low(int), -1) > 0
      check roundSeed(1, 1_000_003) != roundSeed(2, 0)
      check roundSeed(1, 1) != roundSeed(1, 2)
      check roundSeed(9, 3) == roundSeed(9, 3)
      discard runRound(RoundsConfig(threads: 1, opsPerThread: 1, seed: high(int)), high(int),
                       setupBoom, genRead, execBoom)

    test "P4: replay shrink under the scheduler gives a real, reproducible scenario":
      racy = true
      let cfg = RoundsConfig(rounds: 200, opsPerThread: 12, saveDir: dir, name: "replay",
                             replayShrink: true)
      let r = runRounds(cfg, CState(), CModel, setupCounter, genOp, exec, teardownCounter, hooks)
      check not r.passed
      check r.replay.startsWith("shrunk the scenario from 36 to ")
      var n = 0
      for l in r.scenario: n += l.len
      check n < 36
      check r.verdict.kind == vkNotLinearizable
      # the reduced scenario fails again, with the same history
      let again = runScenario(cfg, r.rounds, r.scenario, setupCounter, exec, teardownCounter, hooks)
      check again.toJsonLines == r.history.toJsonLines
      check checkLinearizable(again, CState(), CModel).kind == vkNotLinearizable
      check "replay: shrunk" in r.describe

    test "P4: replay is skipped when the round is not deterministic":
      # reads return a value that changes between runs of the same scenario
      proc execDrift(c: ptr Counter, op: COp): CRes {.gcsafe.} =
        {.cast(gcsafe).}:
          inc teardowns
          if op.inc: CRes(value: c.v.fetchAdd(1) + 1) else: CRes(value: -teardowns)
      let r = runRounds(RoundsConfig(threads: 1, rounds: 1, opsPerThread: 4, saveDir: dir,
                                     name: "drift", replayShrink: true),
                        CState(), CModel, setupBoom2, genRead, execDrift)
      check not r.passed
      check r.replay.startsWith("skipped: the round is not deterministic")

    test "P4: runScenario checks the number of thread lists":
      expect ValueError:
        discard runScenario(RoundsConfig(threads: 2), 1, @[@[COp(inc: true)]], setupBoom2, execPlain)

    test "D-29: built-in scheduler, calibrated steps, replay with runScenario":
      racy = true
      proc setupPlain(c: var Counter) = c.racy = racy
      let cfg = RoundsConfig(rounds: 200, opsPerThread: 12, saveDir: dir, name: "builtin",
                             schedule: true, depth: 4)
      let r = runRounds(cfg, CState(), CModel, setupPlain, genOp, exec)
      check not r.passed
      check r.steps > 0
      let r2 = runRounds(cfg, CState(), CModel, setupPlain, genOp, exec)
      check r2.rounds == r.rounds and r2.steps == r.steps          # deterministic
      var c = cfg
      c.steps = r.steps
      let again = runScenario(c, r.rounds, r.scenario, setupPlain, exec)
      check again.toJsonLines == r.original.toJsonLines

    test "D-29: schedule rejects user hooks and bad depth":
      expect ValueError:
        discard runRounds(RoundsConfig(rounds: 1, schedule: true), CState(), CModel,
                          setupCounter, genOp, exec, teardownCounter, hooks)
      expect ValueError:
        discard runRounds(RoundsConfig(rounds: 1, schedule: true, depth: 0), CState(), CModel,
                          setupBoom2, genOp, execPlain)
