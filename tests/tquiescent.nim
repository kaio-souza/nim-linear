## P15: the `quiescent` hook of `runRounds` checks the object after every
## thread finished; a message fails the round, with its seed.
import std/[hashes, random, strutils, unittest]
when not compileOption("threads"):
  suite "quiescent":
    test "skipped without threads":
      skip()
else:
  import std/atomics
  import nimlinear

  type
    COp = object
    CRes = object
    CState = object
    CModel = object
    Obj = object
      refs: Atomic[int]    # a reference count that must return to 1
      leakAt: int
      round: int

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    Expected[CState, CRes](next: s)
  func hash(s: CState): Hash = 0

  var leakAt = 0
  proc setupObj(o: var Obj, info: RoundInfo) =
    o.refs.store(1)
    o.leakAt = leakAt
    o.round = info.round
  proc genOp(r: var Rand, thread, index: int): COp = COp()
  proc exec(o: ptr Obj, op: COp): CRes {.gcsafe.} =
    discard o.refs.fetchAdd(1)                  # acquire a reference
    if not (o.round == o.leakAt and op == COp()):
      discard o.refs.fetchSub(1)                # BUG in round leakAt: never released
    CRes()
  proc refsBack(o: var Obj): string =
    let n = o.refs.load
    if n != 1: "reference count is " & $n & ", expected 1" else: ""

  proc run(): RoundsResult[COp, CRes] =
    runRounds(RoundsConfig(threads: 2, rounds: 10, opsPerThread: 2, trackProgress: false),
              CState(), CModel, setupObj, genOp, exec, quiescent = refsBack)

  suite "quiescent hook (P15)":
    test "holds in every round: passes":
      leakAt = 0
      check run().passed

    test "a leaked reference fails its round, though every result was right":
      leakAt = 6
      let r = run()
      check not r.passed
      check r.rounds == 6
      check r.verdict.kind == vkLinearizable     # the history itself is fine
      check "reference count is" in r.invariant
      check "invariant broken after the round" in r.describe

    test "no hook: the leak goes unseen":
      leakAt = 6
      check runRounds(RoundsConfig(threads: 2, rounds: 10, opsPerThread: 2, trackProgress: false),
                      CState(), CModel, setupObj, genOp, exec).passed
