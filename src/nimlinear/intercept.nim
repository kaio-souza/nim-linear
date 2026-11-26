## Switch points on atomics and locks without editing the code under test
## (P6, D-26). Not imported by the core.
##
## A drop-in replacement for `std/atomics` and `std/locks`. The code under
## test switches its import in one place, behind a define of its own, so a
## production build never imports nimlinear:
##
##   when defined(nimlinearIntercept): import nimlinear/intercept
##   else: import std/[atomics, locks]
##
## - Without `-d:nimlinearPerturb` it is a plain re-export: no cost.
## - With `-d:nimlinearPerturb`, a `perturb()` runs before every atomic
##   **write or read-modify-write** (`store`, `exchange`, `compareExchange`,
##   `compareExchangeWeak`, `fetchAdd`/`Sub`/`And`/`Or`/`Xor`, `atomicInc`,
##   `atomicDec`, `+=`, `-=`, `testAndSet`, `clear`), and `Lock` is a
##   `SchedLock` (`initLock`, `deinitLock`, `acquire`, `tryAcquire`,
##   `release`, `withLock` keep their names). Under an active scheduler
##   (`nimlinear/schedule`) these become its switch points; otherwise the
##   random perturbation of `nimlinear/perturb` applies.
##
## Loads get no point: the window between a load and the write that depends
## on it is opened by the point before the write. `Cond` is not intercepted:
## `wait` needs a `std/locks` `Lock`, so code that uses `Cond` does not
## compile with interception (keep those locks from `std/locks` directly).
## Memory model: still sequential consistency; orderings are passed through
## but relaxed-memory behaviors are not explored.

when not defined(nimlinearPerturb):
  import std/[atomics, locks]
  export atomics, locks
else:
  import std/atomics as stdatomics
  import std/locks as stdlocks
  import ./[perturb, schedule]
  export stdatomics except store, exchange, compareExchange, compareExchangeWeak,
    fetchAdd, fetchSub, fetchAnd, fetchOr, fetchXor, atomicInc, atomicDec, `+=`, `-=`,
    testAndSet, clear
  export stdlocks except Lock, initLock, deinitLock, acquire, tryAcquire, release, withLock
  export perturb, schedule

  type Lock* = SchedLock

  proc initLock*(l: var Lock) {.inline.} = initSchedLock(l)
  proc deinitLock*(l: var Lock) {.inline.} = deinitSchedLock(l)

  proc store*[T](location: var Atomic[T]; desired: T;
                 order: MemoryOrder = moSequentiallyConsistent) {.inline.} =
    perturb()
    stdatomics.store(location, desired, order)

  proc exchange*[T](location: var Atomic[T]; desired: T;
                    order: MemoryOrder = moSequentiallyConsistent): T {.inline.} =
    perturb()
    stdatomics.exchange(location, desired, order)

  proc compareExchange*[T](location: var Atomic[T]; expected: var T; desired: T;
                           order: MemoryOrder = moSequentiallyConsistent): bool {.inline.} =
    perturb()
    stdatomics.compareExchange(location, expected, desired, order)

  proc compareExchange*[T](location: var Atomic[T]; expected: var T; desired: T;
                           success, failure: MemoryOrder): bool {.inline.} =
    perturb()
    stdatomics.compareExchange(location, expected, desired, success, failure)

  proc compareExchangeWeak*[T](location: var Atomic[T]; expected: var T; desired: T;
                               order: MemoryOrder = moSequentiallyConsistent): bool {.inline.} =
    perturb()
    stdatomics.compareExchangeWeak(location, expected, desired, order)

  proc compareExchangeWeak*[T](location: var Atomic[T]; expected: var T; desired: T;
                               success, failure: MemoryOrder): bool {.inline.} =
    perturb()
    stdatomics.compareExchangeWeak(location, expected, desired, success, failure)

  template rmw(name: untyped) =
    proc name*[T: SomeInteger](location: var Atomic[T]; value: T;
                               order: MemoryOrder = moSequentiallyConsistent): T {.inline.} =
      perturb()
      stdatomics.name(location, value, order)
  rmw(fetchAdd)
  rmw(fetchSub)
  rmw(fetchAnd)
  rmw(fetchOr)
  rmw(fetchXor)

  proc atomicInc*[T: SomeInteger](location: var Atomic[T]; value: T = 1) {.inline.} =
    perturb()
    stdatomics.atomicInc(location, value)

  proc atomicDec*[T: SomeInteger](location: var Atomic[T]; value: T = 1) {.inline.} =
    perturb()
    stdatomics.atomicDec(location, value)

  proc `+=`*[T: SomeInteger](location: var Atomic[T]; value: T) {.inline.} =
    perturb()
    stdatomics.`+=`(location, value)

  proc `-=`*[T: SomeInteger](location: var Atomic[T]; value: T) {.inline.} =
    perturb()
    stdatomics.`-=`(location, value)

  proc testAndSet*(location: var AtomicFlag;
                   order: MemoryOrder = moSequentiallyConsistent): bool {.inline.} =
    perturb()
    stdatomics.testAndSet(location, order)

  proc clear*(location: var AtomicFlag; order: MemoryOrder = moSequentiallyConsistent) {.inline.} =
    perturb()
    stdatomics.clear(location, order)
