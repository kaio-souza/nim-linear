## `Shared[T]` (nimlinear/intercept): plain fields as switch points.
## Compiled with -d:nimlinearPerturb (tshared.nims).
import std/[hashes, random, unittest]
when not compileOption("threads"):
  suite "Shared":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/intercept

  type
    COp = object
    CRes = object
      value: int
    CState = object
      value: int
    CModel = object
    Counter = object
      shared: Shared[int]   # the field the scheduler can see
      plain: int            # the same race, invisible
      useShared: bool

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes(value: s.value + 1))
  func hash(s: CState): Hash = hash(s.value)

  var useShared = true
  proc setup(c: var Counter) = c.useShared = useShared
  proc genOp(r: var Rand, thread, index: int): COp = COp()
  proc exec(c: ptr Counter, op: COp): CRes {.gcsafe.} =
    {.cast(gcsafe).}:
      if c.useShared:
        let x = c.shared[]             # BUG: read, then write, no lock
        c.shared[] = x + 1
        CRes(value: x + 1)
      else:
        let x = c.plain
        c.plain = x + 1
        CRes(value: x + 1)

  proc run(shared: bool): RoundsResult[COp, CRes] =
    useShared = shared
    runRounds(RoundsConfig(threads: 2, rounds: 2, opsPerThread: 2, explore: true,
                           trackProgress: false, name: "shared"),
              CState(), CModel, setup, genOp, exec)

  suite "Shared[T]":
    test "a race on a Shared field is found without perturb()":
      let r = run(true)
      check not r.passed
      check r.verdict.kind == vkNotLinearizable
      var kinds: seq[string]
      for p in r.trace: kinds.add p.kind
      check "read" in kinds and "write" in kinds

    test "the same race on a plain field is out of reach (no switch point)":
      check run(false).passed

    test "accessors without a scheduler":
      var s: Shared[int]
      s[] = 41
      s[] = s[] + 1
      check s[] == 42
