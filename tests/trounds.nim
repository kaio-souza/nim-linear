## M17: runRounds on a tiny object: an atomic counter (correct) and a
## read-then-write counter (lost updates). Deterministic: every round runs
## under the PCT scheduler (seeded per round in `setup`), and the racy window
## is a `perturb()` point, so the outcome does not depend on the OS.
## Compiled with -d:nimlinearPerturb (trounds.nims).
import std/[algorithm, atomics, os, random, strutils, unittest]
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
  var roundNo = 0
  var nThreads = 3     # must match the RoundsConfig threads of each test
  proc setupCounter(c: var Counter) =
    c.racy = racy
    inc roundNo
    sched.initScheduler(nThreads, roundNo, depth = 3, steps = 30)
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
