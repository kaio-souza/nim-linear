## Opt-in defines of nimlinear/intercept: -d:nimlinearInterceptLoads puts a
## switch point before every atomic load; -d:nimlinearInterceptNoLocks keeps
## `Lock` from std/locks, so code that uses `Cond` compiles. Compiled with
## both, plus -d:nimlinearPerturb (tintercept_loads.nims).
import std/unittest
when not compileOption("threads"):
  suite "intercept loads":
    test "skipped without threads":
      skip()
else:
  import nimlinear/intercept

  suite "intercept loads":
    test "every load is a switch point":
      var s: Scheduler
      initScheduler(s, threads = 1, seed = 1)
      enter(s, 0)
      var a: Atomic[int]
      var sum = 0
      for _ in 1 .. 5: sum += a.load(moRelaxed)
      leave(s)
      check s.stepsTaken == 5
      deinitScheduler(s)
      check sum == 0

    test "load and Shared evaluate their argument once":
      var a: Atomic[int]
      var sh: Shared[int]
      var calls = 0
      proc cell(): var Atomic[int] =
        inc calls
        a
      proc field(): var Shared[int] =
        inc calls
        sh
      discard cell().load
      field()[] = 5
      check field()[] == 5
      check calls == 3

    test "Lock stays std/locks, so Cond compiles":
      var l: Lock
      var c: Cond
      initLock l
      initCond c
      withLock l: signal(c)
      deinitCond c
      deinitLock l
