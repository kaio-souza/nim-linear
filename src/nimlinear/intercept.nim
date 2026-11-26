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
##   `release`, `withLock` keep their names) and `Cond` a `SchedCond`. Under an active scheduler
##   (`nimlinear/schedule`) these become its switch points; otherwise the
##   random perturbation of `nimlinear/perturb` applies.
##
## By default loads get no point: the window between a load and the write
## that depends on it is opened by the point before the write. That misses a
## window between two loads (read `head`, read `tail`, decide without a
## write). `-d:nimlinearInterceptLoads` (opt-in) also puts a point before
## every `load`. Opt-in because loads sit in spin-wait loops, and under the
## PCT scheduler a high-priority thread spinning on a load can wait forever
## for a lower-priority one; use it with random perturbation (no scheduler)
## or on code without spin waits.
##
## `Cond` is a `SchedCond` (`initCond`, `deinitCond`, `wait`, `signal`,
## `broadcast` keep their names): `wait` is a switch point and a waiting
## thread yields to the scheduler. `-d:nimlinearInterceptNoLocks` leaves
## `Lock` and `Cond` from `std/locks` (atomics only); then a point inside a
## critical section can hang a round under the scheduler, so use it with
## random perturbation.
## Memory model: still sequential consistency; orderings are passed through
## but relaxed-memory behaviors are not explored.

import std/[macros, strutils]

when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
  import ./perturb as perturbOf
  template perturbImplOf*(kind: static string, lp: untyped, isWrite: bool) =
    ## Internal: the switch point of `interceptAtomics` (P18).
    const ii = instantiationInfo(-2)    # -1 is the generated wrapper; -2 its caller
    perturbOf.perturbImpl(kind, ii.filename.cstring, ii.line, cast[pointer](lp), isWrite)
else:
  template perturbImplOf*(kind: static string, lp: untyped, isWrite: bool) = discard

macro forwardCall*(callee, first: untyped, rest: varargs[untyped]): untyped =
  ## Internal: `callee(first, rest...)` (used by `interceptAtomics`).
  result = newCall(callee, first)
  for a in rest: result.add a

macro interceptAtomics*(module: untyped; writes: untyped = nil; reads: untyped = nil;
                        types: untyped = nil): untyped =
  ## P18: switch points on an atomics module other than `std/atomics` (for
  ## example `threading/atomics`). Used in a small shim module the code
  ## under test imports instead of the original:
  ##
  ##   import threading/atomics as ta
  ##   import nimlinear/intercept
  ##   interceptAtomics(ta, writes = [store, exchange, compareExchange, fetchAdd, fetchSub],
  ##                    reads = [load], types = [Ordering])
  ##
  ## Without `-d:nimlinearPerturb` it expands to `export ta` (no cost). With
  ## it, every listed proc is replaced by a template that puts a switch
  ## point on its first argument (the atomic location) and then calls the
  ## original with the same arguments; the rest of the module is
  ## re-exported. `reads` get a point only with `-d:nimlinearInterceptLoads`,
  ## like `load` of `std/atomics`. The first argument must be addressable
  ## (a `var` location), as for any atomic operation. `types` re-exports
  ## types explicitly: Nim's `export m except ...` hides the values of a
  ## `{.pure.}` enum such as `threading/atomics`' `Ordering` (`Acquire` would
  ## need `Ordering.Acquire`); listing the enum type here fixes that.
  proc names(n: NimNode): seq[NimNode] =
    if n.kind == nnkNilLit: return
    if n.kind notin {nnkBracket, nnkPar, nnkTupleConstr}:
      error("interceptAtomics: expected a list like [store, load]", n)
    for c in n:
      if c.kind notin {nnkIdent, nnkAccQuoted, nnkSym}:
        error("interceptAtomics: expected a proc name", c)
      result.add c
  let ws = names(writes)
  let rs = names(reads)
  let all = ws & rs
  if all.len == 0: error("interceptAtomics: no proc listed", module)
  var typeExports = newStmtList()
  for t in names(types): typeExports.add nnkExportStmt.newTree(newDotExpr(module, t))
  var plainExport = nnkExportStmt.newTree(module)
  var exceptExport = nnkExportExceptStmt.newTree(module)
  for n in all: exceptExport.add n
  var templates = newStmtList()
  let impl = bindSym"perturbImplOf"
  let unpack = bindSym"forwardCall"
  for (list, isWrite) in [(ws, true), (rs, false)]:
    for n in list:
      let label = newLit(($n).strip(chars = {'`'}))
      # Plain identifiers: the template's own hygiene renames them (a
      # genSym'd `let` here breaks inside closures, "environment misses").
      let loc = ident"location"
      let args = ident"args"
      let lp = ident"lp"
      let target = newDotExpr(module, n)
      let pointCall =
        if isWrite: newCall(impl, label, lp, newLit(true))
        else:
          quote do:
            when (defined(nimlinearInterceptLoads) or defined(nimlinearStrict)): `impl`(`label`, `lp`, false)
      templates.add quote do:
        template `n`*(`loc`: untyped, `args`: varargs[untyped]): untyped =
          let `lp` = addr(`loc`)        # evaluated once
          `pointCall`
          `unpack`(`target`, `lp`[], `args`)
      # quote turns the exported name into `n*`; nothing else to fix.
  result = quote do:
    when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
      `exceptExport`
      `typeExports`
      `templates`
    else:
      `plainExport`

type Shared*[T] = object
  ## A plain (non-atomic) field the scheduler should see. Declare the field
  ## as `Shared[T]` and access it with `x[]` and `x[] = v`. Without
  ## `-d:nimlinearPerturb` it is a plain value with inline accessors (no
  ## cost); with it, every read and write is a switch point. Same memory
  ## model as the field it replaces: not atomic, not synchronized.
  v: T

when not (defined(nimlinearPerturb) or defined(nimlinearStrict)):
  import std/[atomics, locks]
  export atomics, locks

  template `[]`*[T](s: Shared[T]): T = s.v
  template `[]=`*[T](s: var Shared[T], x: T) = s.v = x
else:
  import std/atomics as stdatomics
  import std/locks as stdlocks
  import ./[perturb, schedule]
  export stdatomics except store, exchange, compareExchange, compareExchangeWeak,
    fetchAdd, fetchSub, fetchAnd, fetchOr, fetchXor, atomicInc, atomicDec, `+=`, `-=`,
    testAndSet, clear, load
  export perturb, schedule

  # Wrappers are templates so that the switch point records the line of the
  # code under test, not of this module (trace, P12).
  template point(kind: static string, location: untyped, isWrite = true) =
    const ii = instantiationInfo(-2)   # -1 is the wrapper below; -2 its caller
    perturbImpl(kind, ii.filename.cstring, ii.line, cast[pointer](addr location), isWrite)

  when (defined(nimlinearInterceptLoads) or defined(nimlinearStrict)):
    template load*[T](location: var Atomic[T];
                      order: MemoryOrder = moSequentiallyConsistent): T =
      let lp = addr(location)          # evaluated once
      point("load", lp[], false)
      stdatomics.load(lp[], order)
  else:
    template load*[T](location: var Atomic[T];
                      order: MemoryOrder = moSequentiallyConsistent): T =
      stdatomics.load(location, order)

  when defined(nimlinearInterceptNoLocks):
    export stdlocks
  else:
    export stdlocks except Lock, initLock, deinitLock, acquire, tryAcquire, release, withLock,
      Cond, initCond, deinitCond, wait, signal, broadcast

    type
      Lock* = SchedLock
      Cond* = SchedCond

    proc initLock*(l: var Lock) {.inline.} = initSchedLock(l)
    proc deinitLock*(l: var Lock) {.inline.} = deinitSchedLock(l)
    proc initCond*(c: var Cond) {.inline.} = initSchedCond(c)
    proc deinitCond*(c: var Cond) {.inline.} = deinitSchedCond(c)

  template store*[T](location: var Atomic[T]; desired: T;
                     order: MemoryOrder = moSequentiallyConsistent) =
    let lp = addr(location)          # evaluated once
    point("store", lp[])
    stdatomics.store(lp[], desired, order)

  template exchange*[T](location: var Atomic[T]; desired: T;
                        order: MemoryOrder = moSequentiallyConsistent): T =
    let lp = addr(location)          # evaluated once
    point("exchange", lp[])
    stdatomics.exchange(lp[], desired, order)

  template compareExchange*[T](location: var Atomic[T]; expected: var T; desired: T;
                               order: MemoryOrder = moSequentiallyConsistent): bool =
    let lp = addr(location)          # evaluated once
    point("compareExchange", lp[])
    stdatomics.compareExchange(lp[], expected, desired, order)

  template compareExchange*[T](location: var Atomic[T]; expected: var T; desired: T;
                               success, failure: MemoryOrder): bool =
    let lp = addr(location)          # evaluated once
    point("compareExchange", lp[])
    stdatomics.compareExchange(lp[], expected, desired, success, failure)

  template compareExchangeWeak*[T](location: var Atomic[T]; expected: var T; desired: T;
                                   order: MemoryOrder = moSequentiallyConsistent): bool =
    let lp = addr(location)          # evaluated once
    point("compareExchangeWeak", lp[])
    stdatomics.compareExchangeWeak(lp[], expected, desired, order)

  template compareExchangeWeak*[T](location: var Atomic[T]; expected: var T; desired: T;
                                   success, failure: MemoryOrder): bool =
    let lp = addr(location)          # evaluated once
    point("compareExchangeWeak", lp[])
    stdatomics.compareExchangeWeak(lp[], expected, desired, success, failure)

  template rmw(name: untyped, label: static string) =
    template name*[T: SomeInteger](location: var Atomic[T]; value: T;
                                   order: MemoryOrder = moSequentiallyConsistent): T =
      let lp = addr(location)          # evaluated once
      point(label, lp[])
      stdatomics.name(lp[], value, order)
  rmw(fetchAdd, "fetchAdd")
  rmw(fetchSub, "fetchSub")
  rmw(fetchAnd, "fetchAnd")
  rmw(fetchOr, "fetchOr")
  rmw(fetchXor, "fetchXor")

  template atomicInc*[T: SomeInteger](location: var Atomic[T]; value: T = 1) =
    let lp = addr(location)          # evaluated once
    point("atomicInc", lp[])
    stdatomics.atomicInc(lp[], value)

  template atomicDec*[T: SomeInteger](location: var Atomic[T]; value: T = 1) =
    let lp = addr(location)          # evaluated once
    point("atomicDec", lp[])
    stdatomics.atomicDec(lp[], value)

  template `+=`*[T: SomeInteger](location: var Atomic[T]; value: T) =
    let lp = addr(location)          # evaluated once
    point("+=", lp[])
    stdatomics.`+=`(lp[], value)

  template `-=`*[T: SomeInteger](location: var Atomic[T]; value: T) =
    let lp = addr(location)          # evaluated once
    point("-=", lp[])
    stdatomics.`-=`(lp[], value)

  template testAndSet*(location: var AtomicFlag;
                       order: MemoryOrder = moSequentiallyConsistent): bool =
    let lp = addr(location)          # evaluated once
    point("testAndSet", lp[])
    stdatomics.testAndSet(lp[], order)

  template clear*(location: var AtomicFlag; order: MemoryOrder = moSequentiallyConsistent) =
    let lp = addr(location)          # evaluated once
    point("clear", lp[])
    stdatomics.clear(lp[], order)

  template `[]`*[T](s: Shared[T]): T =
    let lp = addr(s)          # evaluated once
    point("read", lp[], false)
    lp[].v

  template `[]=`*[T](s: var Shared[T], x: T) =
    let lp = addr(s)          # evaluated once
    point("write", lp[])
    lp[].v = x
