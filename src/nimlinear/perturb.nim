## Optional perturbation points (M12, D-18). Not imported by the core.
##
## Place `perturb()` inside the object under test, at points where another
## thread acting would matter (between reading and changing shared state).
##
## - Without `-d:nimlinearPerturb`, `perturb()` is an empty template: no code,
##   no cost, and `setPerturbation` does nothing.
## - With `-d:nimlinearPerturb`, each point draws from a per-thread seeded
##   generator: nothing (50%), a short `cpuRelax` spin (25%) or `sleep(0)`
##   (25%). The OS still decides the interleaving, so a seed does not
##   reproduce a run; for that, use `nimlinear/schedule` (M13).
## - When a scheduler from `nimlinear/schedule` is active, `perturb()` is its
##   scheduling point instead.

type
  SwitchPoint* = object
    ## One switch point of a scheduled round (P12): the thread that reached
    ## it, what it was and where in the source (the code under test, when it
    ## calls `perturb()`, an intercepted operation, `acquire` or `wait`).
    step*: int
    thread*: int
    kind*: string        ## "perturb", "store", "load", "acquire", "wait"...
    file*: string
    line*: int

when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
  import std/[atomics, os, random]

  type YieldHook* = proc (kind, file: cstring, line: int, obj: pointer, write: bool)
                        {.nimcall, gcsafe, raises: [].}
    ## Internal: installed by `nimlinear/schedule`.

  var gDisabled: Atomic[bool]
  var gSeed: Atomic[int]
  var gGen: Atomic[int]          # bumped by setPerturbation; threads re-seed
  var gThreadCounter: Atomic[int]
  var gHook: Atomic[pointer]
  var tGen {.threadvar.}: int
  var tRng {.threadvar.}: Rand

  proc setYieldHook*(h: YieldHook) {.raises: [].} =
    ## Internal: used by `nimlinear/schedule`. `nil` removes the hook.
    gHook.store(cast[pointer](h))

  proc perturbImpl*(kind: cstring = "perturb", file: cstring = "", line = 0,
                    obj: pointer = nil, write = true) {.raises: [], gcsafe.} =
    ## Internal. `kind`, `file` and `line` name the switch point for the
    ## scheduler's trace (P12); `obj` and `write` are the object the next
    ## operation touches (nil: unknown, conflicts with everything), for
    ## exploration with reduction. The random draw ignores them.
    let h = cast[YieldHook](gHook.load)
    if h != nil:
      h(kind, file, line, obj, write)
      return
    if gDisabled.load: return
    let g = gGen.load + 1        # + 1: a fresh thread (tGen = 0) always seeds
    if tGen != g:
      tGen = g
      tRng = initRand(gSeed.load * 7919 + gThreadCounter.fetchAdd(1) + 1)
    case tRng.rand(3)
    of 0, 1: discard
    of 2:
      for _ in 0 ..< tRng.rand(1 .. 64): cpuRelax()
    else: sleep(0)

  template perturb*() =
    ## Perturbation point (active: compiled with -d:nimlinearPerturb).
    const ii = instantiationInfo(-1)
    perturbImpl("perturb", ii.filename.cstring, ii.line)

  proc setPerturbation*(enabled: bool, seed = 0) {.raises: [].} =
    ## Turns the random draw on or off and sets its seed. Threads pick up the
    ## new seed at their next `perturb()`. Enabled by default.
    gDisabled.store(not enabled)
    gSeed.store(seed)
    gThreadCounter.store(0)
    discard gGen.fetchAdd(1)

else:
  template perturb*() =
    ## Perturbation point: empty without -d:nimlinearPerturb.
    discard

  proc setPerturbation*(enabled: bool, seed = 0) {.raises: [].} =
    ## No effect without -d:nimlinearPerturb.
    discard
