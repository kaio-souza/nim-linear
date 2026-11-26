## Exploration with reduction (sleep sets over step footprints): same
## verdicts as plain exploration, fewer schedules. Compiled with
## -d:nimlinearPerturb -d:nimlinearInterceptLoads (treduce.nims).
import std/[hashes, random, unittest]
when not compileOption("threads"):
  suite "reduce":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/intercept

  type
    Kind = enum
      kAtomic       ## fetchAdd on one shared counter: correct
      kRacy         ## load then store on one shared counter: lost update
      kSeparate     ## each thread its own counter: correct, all steps independent
      kLocked       ## one lock, plain field inside: correct
      kRacyLocked   ## read and write in two critical sections: lost update
    COp = object
      inc: bool
    CRes = object
      value: int
    CState = object
      value: int
    CModel = object
    Counter = object
      v: Atomic[int]
      own: array[3, Atomic[int]]
      lock: Lock
      plain: int
      kind: Kind

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes(value: s.value + 1))
  func hash(s: CState): Hash = hash(s.value)

  # kSeparate has its own model: each thread counts alone, results 1, 2, ...
  type SState = object
    n: array[3, int]
  type SOp = object
    thread: int
  type SModel = object

  var kind = kAtomic
  proc setup(c: var Counter) =
    c.kind = kind
    initLock c.lock
  proc teardown(c: var Counter) = deinitLock c.lock
  proc genOp(r: var Rand, thread, index: int): COp = COp(inc: true)
  proc exec(c: ptr Counter, op: COp): CRes {.gcsafe.} =
    {.cast(gcsafe).}:
      case c.kind
      of kAtomic: CRes(value: c.v.fetchAdd(1) + 1)
      of kRacy:
        let x = c.v.load
        c.v.store(x + 1)
        CRes(value: x + 1)
      of kSeparate:
        discard c.own[0].fetchAdd(1)      # replaced below per thread
        CRes(value: 0)
      of kLocked:
        var r: int
        withLock c.lock:
          inc c.plain
          r = c.plain
        CRes(value: r)
      of kRacyLocked:
        var x: int
        withLock c.lock: x = c.plain
        withLock c.lock: c.plain = x + 1
        CRes(value: x + 1)

  proc run(k: Kind, reduce: bool): RoundsResult[COp, CRes] =
    kind = k
    runRounds(RoundsConfig(threads: 2, rounds: 3, opsPerThread: 2, explore: true,
                           reduce: reduce, trackProgress: false, name: "reduce"),
              CState(), CModel, setup, genOp, exec, teardown)

  # Separate counters, with a thread-aware operation so steps touch different objects.
  type Sep = object
    own: array[2, Atomic[int]]
  proc setupSep(s: var Sep) = discard
  proc genSep(r: var Rand, thread, index: int): SOp = SOp(thread: thread)
  proc execSep(s: ptr Sep, op: SOp): CRes {.gcsafe.} =
    discard s.own[op.thread].load
    CRes(value: s.own[op.thread].fetchAdd(1) + 1)
  func step(m: typedesc[SModel], s: SState, op: SOp): Expected[SState, CRes] {.raises: [].} =
    var n = s
    inc n.n[op.thread]
    Expected[SState, CRes](next: n, res: CRes(value: n.n[op.thread]))
  func hash(s: SState): Hash = hash(s.n)
  proc runSep(reduce: bool): RoundsResult[SOp, CRes] =
    runRounds(RoundsConfig(threads: 2, rounds: 1, opsPerThread: 3, explore: true,
                           reduce: reduce, trackProgress: false, name: "reduce-sep"),
              SState(), SModel, setupSep, genSep, execSep)

  suite "exploration with reduction":
    for k in [kAtomic, kRacy, kLocked, kRacyLocked]:
      test "same verdict as plain exploration, no more schedules: " & $k:
        let plain = run(k, false)
        let red = run(k, true)
        check plain.passed == red.passed
        check red.explored <= plain.explored
        if plain.passed: check red.complete
        else: check red.verdict.kind == vkNotLinearizable

    test "separate counters: same verdict, complete, no more schedules":
      # Steps that record an invoke or a return touch the shared history, so
      # with two switch points per operation there is little to prune here;
      # the point is that the reduction stays sound and complete.
      let plain = runSep(false)
      let red = runSep(true)
      check plain.passed and red.passed
      check plain.complete and red.complete
      check red.explored <= plain.explored

    # The refusal without -d:nimlinearInterceptLoads: tests/treduce_noloads.nim.
