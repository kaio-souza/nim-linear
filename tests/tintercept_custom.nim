## P18: `interceptAtomics` puts switch points on an atomics module other
## than std/atomics, through a shim (tests/fixtures/fakeatomics_shim.nim).
## Compiled with -d:nimlinearPerturb (tintercept_custom.nims).
import std/[random, unittest]
when not compileOption("threads"):
  suite "interceptAtomics":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/schedule
  import ./fixtures/fakeatomics_shim

  type
    COp = object
    CRes = object
      value: int
    CState = object
      value: int
    CModel = object
    Counter = object
      v: Atomic[int]
      racy: bool

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes(value: s.value + 1))

  var racy = false
  proc setup(c: var Counter) = c.racy = racy
  proc genOp(r: var Rand, thread, index: int): COp = COp()
  proc exec(c: ptr Counter, op: COp): CRes {.gcsafe.} =
    {.cast(gcsafe).}:
      if c.racy:
        let x = c.v.load             # BUG: load then store
        c.v.store(x + 1)
        CRes(value: x + 1)
      else:
        CRes(value: c.v.fetchAdd(1) + 1)

  proc run(r: bool): RoundsResult[COp, CRes] =
    racy = r
    runRounds(RoundsConfig(threads: 2, rounds: 2, opsPerThread: 2, explore: true,
                           trackProgress: false, name: "intercept-custom"),
              CState(), CModel, setup, genOp, exec)

  suite "interceptAtomics":
    test "a load-then-store race on a non-std atomic is found":
      let r = run(true)
      check not r.passed
      check r.verdict.kind == vkNotLinearizable
      var kinds: seq[string]
      var lines: seq[string]
      for p in r.trace:
        kinds.add p.kind
        lines.add p.file
      check "store" in kinds
      check "tintercept_custom.nim" in lines   # the caller's line, not the shim's

    test "the correct fetchAdd counter passes":
      check run(false).passed

    test "procs not listed are re-exported untouched":
      var a: Atomic[int]
      check a.isLockFree
      a.store(3)
      check a.load == 3
