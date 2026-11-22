## M17: runRounds on a tiny object: an atomic counter (correct) and a
## read-then-write counter (lost updates).
import std/[algorithm, atomics, os, random, strutils, unittest]
when not compileOption("threads"):
  suite "rounds":
    test "skipped without threads":
      skip()
else:
  import nimlinear

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
  proc setupCounter(c: var Counter) = c.racy = racy
  proc genOp(r: var Rand, thread, index: int): COp = COp(inc: r.rand(3) > 0)
  proc exec(c: ptr Counter, op: COp): CRes {.gcsafe.} =
    if not op.inc: return CRes(value: c.v.load)
    if c.racy:
      let x = c.v.load
      sleep(1)       # a real window: thread start-up can outlast sleep(0) (Windows)
      c.v.store(x + 1)
      CRes(value: x + 1)
    else:
      CRes(value: c.v.fetchAdd(1) + 1)

  let dir = getTempDir() / "nimlinear-trounds"

  suite "rounds":
    test "correct object passes every round":
      racy = false
      let r = runRounds(RoundsConfig(rounds: 50, saveDir: dir, name: "ok"), CState(), CModel,
                        setupCounter, genOp, exec)
      check r.passed
      check r.rounds == 50
      check r.savedTo == ""

    test "racy object fails, is shrunk and saved":
      racy = true
      let r = runRounds(RoundsConfig(rounds: 200, opsPerThread: 12, saveDir: dir, name: "racy"),
                        CState(), CModel, setupCounter, genOp, exec)
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
      racy = false
      var calls1, calls2: seq[string]
      for e in runRound(cfg, 1, setupCounter, genOp, exec).events:
        if e.kind == ekInvoke: calls1.add $e.call & "@" & $e.thread
      for e in runRound(cfg, 1, setupCounter, genOp, exec).events:
        if e.kind == ekInvoke: calls2.add $e.call & "@" & $e.thread
      calls1.sort(); calls2.sort()
      check calls1 == calls2
