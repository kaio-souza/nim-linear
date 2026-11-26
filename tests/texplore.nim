## D-32: bounded exhaustive exploration (`RoundsConfig.explore`).
## Compiled with -d:nimlinearPerturb (texplore.nims).
import std/[hashes, random, unittest]
when not compileOption("threads"):
  suite "explore":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/intercept

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
  func hash(s: CState): Hash = hash(s.value)

  var racy = false
  proc setup(c: var Counter) = c.racy = racy
  proc genOp(r: var Rand, thread, index: int): COp = COp(inc: true)
  proc exec(c: ptr Counter, op: COp): CRes {.gcsafe.} =
    if c.racy:
      let x = c.v.load            # BUG: load, then store (the store is a switch point)
      c.v.store(x + 1)
      CRes(value: x + 1)
    else:
      CRes(value: c.v.fetchAdd(1) + 1)

  proc run(isRacy: bool, preemptions = 2, maxSchedules = 10_000, rounds = 3,
           pct = false): RoundsResult[COp, CRes] =
    racy = isRacy
    runRounds(RoundsConfig(threads: 2, rounds: rounds, opsPerThread: 2, explore: true,
                           preemptions: preemptions, maxSchedules: maxSchedules,
                           schedule: pct, name: "explore"),
              CState(), CModel, setup, genOp, exec)

  suite "explore":
    test "correct counter: every schedule passes, search complete":
      let r = run(false)
      check r.passed
      check r.complete
      check r.explored > 3        # more than one schedule per round

    test "racy counter: found, and found the same way every time":
      let a = run(true)
      check not a.passed
      check a.verdict.kind == vkNotLinearizable
      check a.schedule.len > 0
      let b = run(true)
      check b.explored == a.explored
      check b.schedule == a.schedule
      check b.original.toJsonLines == a.original.toJsonLines

    test "zero preemptions: only serial schedules, the race is out of reach":
      let r = run(true, preemptions = 0)
      check r.passed
      check r.complete

    test "maxSchedules caps a round and says it is not complete":
      let r = run(false, maxSchedules = 1, rounds = 1)
      check r.passed
      check not r.complete
      check r.explored == 1

    test "schedule and explore together are refused":
      expect ValueError:
        discard run(false, pct = true)
