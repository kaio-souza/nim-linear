## P6: without -d:nimlinearPerturb, nimlinear/intercept is a plain re-export
## of std/atomics and std/locks (Cond included).
import std/unittest
import nimlinear/intercept

suite "intercept off":
  test "plain std/atomics and std/locks":
    var a: Atomic[int]
    a.store(1)
    check a.fetchAdd(1) == 1
    when compileOption("threads"):
      var l: Lock
      var c: Cond
      initLock l
      initCond c
      withLock l: discard
      deinitCond c
      deinitLock l
    check not defined(nimlinearPerturb)
