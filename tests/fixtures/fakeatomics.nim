## A stand-in for an atomics module that is not `std/atomics` (like
## `threading/atomics`): its own `Atomic[T]` and procs (P18 test).
type
  Atomic*[T: SomeInteger] = object
    value: T
  Ordering* = enum Relaxed, SeqCst

proc load*[T](a: var Atomic[T]; order = SeqCst): T =
  atomicLoadN(addr a.value, ATOMIC_SEQ_CST)
proc store*[T](a: var Atomic[T]; v: T; order = SeqCst) =
  atomicStoreN(addr a.value, v, ATOMIC_SEQ_CST)
proc fetchAdd*[T](a: var Atomic[T]; v: T; order = SeqCst): T =
  atomicFetchAdd(addr a.value, v, ATOMIC_SEQ_CST)
proc isLockFree*[T](a: var Atomic[T]): bool = true   # not intercepted
