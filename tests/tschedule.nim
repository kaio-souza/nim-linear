## M13/M19: the scheduler with SchedLock. A bug inside a critical section
## (two locks guarding one counter, `perturb()` between read and write) is
## found without hanging; the correct version (one lock) always passes.
## Compiled with -d:nimlinearPerturb (tschedule.nims).
import std/unittest
when not compileOption("threads"):
  suite "schedule":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/[perturb, schedule]

  type
    Counter = object
      a, b: SchedLock
      value: int
      buggy: bool
    COp = object
      inc: bool          # true: increment; false: read
    CRes = object
      value: int
    CState = object
      value: int
    CModel = object

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    if op.inc: Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes())
    else: Expected[CState, CRes](next: s, res: CRes(value: s.value))

  var sched: Scheduler
  var counter: Counter
  var rec: Recorder[COp, CRes]

  proc worker(tid: int) {.thread.} =
    {.cast(gcsafe).}:
      sched.enter(tid)
      for _ in 0 ..< 2:
        discard rec.record(tid, COp(inc: true)):
          # BUG when buggy: thread 0 uses lock a, thread 1 lock b.
          let l = if counter.buggy and tid == 1: addr counter.b else: addr counter.a
          withLock l[]:
            let v = counter.value
            perturb()                 # inside the critical section
            counter.value = v + 1
          CRes()
      discard rec.record(tid, COp(inc: false)):
        var v: int
        withLock counter.a: v = counter.value
        CRes(value: v)
      sched.leave()

  var lastJson: string

  proc round(buggy: bool, seed: int): Verdict[COp, CRes] =
    counter = Counter(buggy: buggy)
    initSchedLock counter.a
    initSchedLock counter.b
    rec = newRecorder[COp, CRes](2)
    sched.initScheduler(2, seed, depth = 2, steps = 12)
    var ths: array[2, Thread[int]]
    for t in 0 ..< 2: createThread(ths[t], worker, t)
    joinThreads(ths)
    check not sched.deadlocked
    sched.deinitScheduler()
    deinitSchedLock counter.a
    deinitSchedLock counter.b
    let h = rec.snapshot()
    lastJson = h.toJsonLines()
    checkLinearizable(h, CState(), CModel)

  suite "schedule + SchedLock":
    test "correct counter: linearizable for 30 seeds, no hang":
      for seed in 1 .. 30:
        check round(false, seed).kind == vkLinearizable

    test "bug inside a critical section is found within 30 seeds":
      var found = 0
      for seed in 1 .. 30:
        if round(true, seed).kind == vkNotLinearizable: inc found
      check found > 0

    test "same seed, same history (byte for byte)":
      for seed in [3, 5, 8]:
        discard round(true, seed)
        let first = lastJson
        for _ in 1 .. 4:
          discard round(true, seed)
          check lastJson == first

    test "SchedLock without a scheduler is an ordinary lock":
      var l: SchedLock
      initSchedLock l
      withLock l: discard
      deinitSchedLock l

    test "R11: perturb and SchedLock from an unregistered thread are ignored":
      var s: Scheduler
      s.initScheduler(2, 1)
      perturb()                  # main thread never called enter: no hang
      var l: SchedLock
      initSchedLock l
      withLock l: perturb()
      deinitSchedLock l
      s.deinitScheduler()

    test "a second active scheduler is refused":
      var a, b: Scheduler
      a.initScheduler(1, 1)
      expect ValueError:
        b.initScheduler(1, 1)
      a.deinitScheduler()
      b.initScheduler(1, 1)      # fine once the first is gone
      b.deinitScheduler()
