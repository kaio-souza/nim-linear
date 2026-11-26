## SchedCond: a condition variable that cooperates with the scheduler.
## Compiled with -d:nimlinearPerturb (tschedcond.nims).
import std/unittest
when not compileOption("threads"):
  suite "SchedCond":
    test "skipped without threads":
      skip()
else:
  import nimlinear/schedule

  type Box = object
    s: Scheduler
    l: SchedLock
    c: SchedCond
    items: int
    taken: int
    order: seq[int]

  var box: Box

  proc consumer(t: int) {.thread.} =
    {.cast(gcsafe).}:
      enter(box.s, t)
      for _ in 1 .. 2:
        acquire box.l
        while box.items == 0: wait(box.c, box.l)
        dec box.items
        inc box.taken
        box.order.add t
        release box.l
      leave(box.s)

  proc producer(t: int) {.thread.} =
    {.cast(gcsafe).}:
      enter(box.s, t)
      for _ in 1 .. 4:
        acquire box.l
        inc box.items
        box.order.add t
        signal box.c
        release box.l
      leave(box.s)

  proc runOnce(seed: int): seq[int] =
    box = Box()
    initSchedLock box.l
    initSchedCond box.c
    initScheduler(box.s, threads = 3, seed = seed)
    var th: array[3, Thread[int]]
    createThread(th[0], producer, 0)
    createThread(th[1], consumer, 1)
    createThread(th[2], consumer, 2)
    joinThreads(th)
    check not box.s.deadlocked
    deinitScheduler(box.s)
    deinitSchedCond box.c
    deinitSchedLock box.l
    check box.taken == 4
    check box.items == 0
    box.order

  suite "SchedCond":
    test "waiters wake on signal; every item is taken":
      for seed in 1 .. 50: discard runOnce(seed)

    test "same seed, same interleaving":
      for seed in 1 .. 10: check runOnce(seed) == runOnce(seed)

    test "without a scheduler it is an ordinary Cond":
      var l: SchedLock
      var c: SchedCond
      initSchedLock l
      initSchedCond c
      acquire l
      signal c
      broadcast c
      release l
      deinitSchedCond c
      deinitSchedLock l
