## Usability: -d:nimlinearStrict alone (tstrict.nims) turns on switch points
## and intercepted loads; `RoundsResult.warnings` flags a run without switch
## points; `describe` adds the recorded history when the shrunk one is tiny.
import std/[hashes, random, strutils, unittest]
when not compileOption("threads"):
  suite "strict":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/intercept

  type
    COp = object
      write: bool
    CRes = object
      value: int
    CState = object
      value: int
    CModel = object
    Kind = enum kNoPoints, kTwoLoads, kSafe
    Obj = object
      a, b: Atomic[int]
      plain: int
      kind: Kind

  # Model: a pair (a, b) always written together; read returns a + b.
  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    if op.write: Expected[CState, CRes](next: CState(value: s.value + 2), res: CRes(value: 0))
    else: Expected[CState, CRes](next: s, res: CRes(value: s.value))
  func hash(s: CState): Hash = hash(s.value)

  var kind = kNoPoints
  proc setup(o: var Obj) = o.kind = kind
  proc genOp(r: var Rand, thread, index: int): COp = COp(write: thread == 0)
  proc exec(o: ptr Obj, op: COp): CRes {.gcsafe.} =
    {.cast(gcsafe).}:
      case o.kind
      of kNoPoints:                      # no intercepted operation at all
        if op.write: o.plain += 2
        CRes(value: (if op.write: 0 else: o.plain))
      of kTwoLoads:                      # BUG: two loads, a write can fall between
        if op.write:
          discard o.a.fetchAdd(1)
          discard o.b.fetchAdd(1)
          CRes(value: 0)
        else:
          let x = o.a.load
          let y = o.b.load
          CRes(value: x + y)
      of kSafe:
        if op.write:
          discard o.a.fetchAdd(2)
          CRes(value: 0)
        else:
          CRes(value: o.a.load)

  proc run(k: Kind, rounds = 200): RoundsResult[COp, CRes] =
    kind = k
    runRounds(RoundsConfig(threads: 2, rounds: rounds, opsPerThread: 3, schedule: true,
                           name: "strict-" & $k),
              CState(), CModel, setup, genOp, exec)

  suite "strict":
    test "strict alone intercepts loads: a race between two loads is found":
      let r = run(kTwoLoads)
      check not r.passed
      check r.verdict.kind == vkNotLinearizable

    test "a correct object passes with no warning":
      let r = run(kSafe)
      check r.passed
      check r.warnings.len == 0

    test "no switch points: warned, in the result and in describe":
      let r = run(kNoPoints, rounds = 5)
      check r.passed
      check r.warnings.len == 1
      check "no switch points" in r.warnings[0]
      check "warning: round 1 had no switch points" in r.describe

    test "a tiny shrunk history comes with the recorded one":
      let r = run(kTwoLoads)
      check not r.passed
      check r.history.events.len < r.original.events.len
      check "recorded history before shrinking" in r.describe
