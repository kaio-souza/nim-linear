## Round harness (M17): runs many short concurrent rounds against a real
## object, records them, checks each one, and on the first failure shrinks
## and saves the history. Requires --threads:on.
##
## Per round: `setup` builds a fresh object; every thread gets its own list of
## `opsPerThread` operations from `genOp(rng, thread, index)` (drawn on the
## main thread from `initRand(roundSeed(seed, round))`, so the same seed gives
## the same operations); threads start, run `exec` on each operation through
## `Recorder.record`, and join; `teardown` runs; the history is checked.
## An exception raised by `exec` fails the round. See docs/GUIDE.md.

when not compileOption("threads"):
  {.error: "nimlinear/rounds requires --threads:on".}

import std/[os, random, times]
import ./[history, checker, json, recorder, report, shrink]

type
  RoundsConfig* = object
    threads*: int = 3
    rounds*: int = 100
    opsPerThread*: int = 4
    seed*: int = 1
    budget*: int = 1_000_000
    timeout*: Duration          ## per check; zero = none. Makes the verdict machine-dependent
    partitioned*: bool          ## use `checkPartitioned` (the model must define `partition`)
    shrink*: bool = true        ## shrink the failing history (M16)
    shrinkTimeout*: Duration    ## overall limit for `shrink`; zero = none
    saveDir*: string            ## where to save it; "" = getTempDir()
    name*: string = "nimlinear" ## file name prefix

  RoundInfo* = object
    ## Passed to a `setup` that takes two arguments.
    round*: int   ## 1-based round number
    seed*: int    ## per-round seed, `roundSeed(cfg.seed, round)`; use it for a `Scheduler`

  ThreadHooks* = object
    ## Optional calls at the start and end of each thread, e.g. to register
    ## with a `Scheduler` (nimlinear/schedule). `nil` = no call. `leave` runs
    ## even if `exec` raised.
    enter*: proc (thread: int) {.nimcall, gcsafe, raises: [].}
    leave*: proc () {.nimcall, gcsafe, raises: [].}

  ExecError* = object of CatchableError
    ## Raised by `runRound` when `exec` raised in some thread.

  RoundsResult*[Op, Res] = object
    passed*: bool                ## every round linearizable, no `exec` exception
    rounds*: int                 ## rounds run (the failing one included)
    seed*: int
    error*: string               ## exception raised by `exec` in the failing round, "" if none
    verdict*: Verdict[Op, Res]   ## of the failing round (shrunk history if shrink)
    history*: History[Op, Res]   ## failing history (shrunk if shrink)
    original*: History[Op, Res]  ## failing history as recorded
    savedTo*: string             ## path of the saved (shrunk) history, "" if none
    saveError*: string           ## why saving failed, "" if it did not

  Ctx[Obj, Op, Res] = object
    obj: ptr Obj
    rec: ptr Recorder[Op, Res]
    ops: ptr seq[Op]
    err: ptr string
    tid: int
    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.}
    hooks: ThreadHooks

proc worker[Obj, Op, Res](c: Ctx[Obj, Op, Res]) {.thread.} =
  if c.hooks.enter != nil: c.hooks.enter(c.tid)
  try:
    for k, op in c.ops[]:
      try:
        discard c.rec[].record(c.tid, op): c.exec(c.obj, op)
      except CatchableError as e:
        # The operation stays pending in the history; the thread stops here.
        c.err[] = "thread " & $c.tid & ", operation " & $k & " (" & $op & "): " &
                  $e.name & ": " & e.msg
        break
  finally:
    if c.hooks.leave != nil: c.hooks.leave()

proc validate*(cfg: RoundsConfig) =
  ## Raises `ValueError` for a config that cannot run.
  if cfg.threads < 1: raise newException(ValueError, "RoundsConfig.threads must be >= 1, got " & $cfg.threads)
  if cfg.opsPerThread < 0: raise newException(ValueError, "RoundsConfig.opsPerThread must be >= 0, got " & $cfg.opsPerThread)
  if cfg.rounds < 0: raise newException(ValueError, "RoundsConfig.rounds must be >= 0, got " & $cfg.rounds)

proc mix64(x: uint64): uint64 =
  # splitmix64 finalizer: a bijection on uint64 with good avalanche.
  var z = x + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc roundSeed*(seed, round: int): int =
  ## Per-round seed derived from `(seed, round)`: no overflow for any input,
  ## and different pairs give different values except by rare hash collision.
  ## `(seed, round)` is the only guaranteed identity of a round.
  let z = mix64(mix64(cast[uint64](seed)) xor cast[uint64](round))
  result = int(z and 0x7FFF_FFFF_FFFF_FFFF'u64)
  if result == 0: result = 1

proc runRoundImpl[Obj, Op, Res, SP](cfg: RoundsConfig, round: int, setup: SP,
                                    genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
                                    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                    teardown: proc (obj: var Obj) {.nimcall.},
                                    hooks: ThreadHooks): (History[Op, Res], string) =
  validate(cfg)
  let info = RoundInfo(round: round, seed: roundSeed(cfg.seed, round))
  var rng = initRand(info.seed)
  var ops = newSeq[seq[Op]](cfg.threads)
  for t in 0 ..< cfg.threads:
    for k in 0 ..< cfg.opsPerThread: ops[t].add genOp(rng, t, k)
  var obj: Obj
  when compiles(setup(obj, info)): setup(obj, info)
  else: setup(obj)
  var rec = newRecorder[Op, Res](cfg.threads)
  var errs = newSeq[string](cfg.threads)
  # Thread objects in fixed shared memory (not a seq): their addresses must
  # stay valid for the OS thread's whole life.
  type T = Thread[Ctx[Obj, Op, Res]]
  let ths = cast[ptr UncheckedArray[T]](allocShared0(sizeof(T) * cfg.threads))
  var started = 0
  try:
    for t in 0 ..< cfg.threads:
      createThread(ths[t], worker[Obj, Op, Res],
                   Ctx[Obj, Op, Res](obj: addr obj, rec: addr rec, ops: addr ops[t],
                                     err: addr errs[t], tid: t, exec: exec, hooks: hooks))
      inc started
  finally:
    # Also on a failed createThread: join what started, then free.
    for t in 0 ..< started: joinThread(ths[t])
    for t in 0 ..< cfg.threads: `=destroy`(ths[t])
    deallocShared(ths)
    if teardown != nil: teardown(obj)
  var err = ""
  for e in errs:
    if e.len > 0:
      err = e
      break
  (rec.snapshot(), err)

proc runRound*[Obj, Op, Res, SP](cfg: RoundsConfig, round: int, setup: SP,
                                 genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
                                 exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                 teardown: proc (obj: var Obj) {.nimcall.} = nil,
                                 hooks = ThreadHooks()): History[Op, Res] =
  ## One recorded round (no check). Exposed for tests that drive rounds
  ## themselves. `setup` is `proc (obj: var Obj)` or
  ## `proc (obj: var Obj, info: RoundInfo)`. Raises `ExecError` if `exec`
  ## raised in some thread (after joining the threads and running `teardown`).
  let (h, err) = runRoundImpl(cfg, round, setup, genOp, exec, teardown, hooks)
  if err.len > 0: raise newException(ExecError, err)
  h

proc freePath(dir, base: string): string =
  # `base.jsonl`, or `base-2.jsonl`, `base-3.jsonl`... if it already exists.
  result = dir / (base & ".jsonl")
  var n = 2
  while fileExists(result):
    result = dir / (base & "-" & $n & ".jsonl")
    inc n

proc checkWith[S, Op, Res](cfg: RoundsConfig, h: History[Op, Res], init: S,
                           model: typedesc): Verdict[Op, Res] =
  when compiles(checkPartitioned(h, init, model, cfg.budget, cfg.timeout)):
    if cfg.partitioned: checkPartitioned(h, init, model, cfg.budget, cfg.timeout)
    else: checkLinearizable(h, init, model, cfg.budget, cfg.timeout)
  else:
    if cfg.partitioned:
      raise newException(ValueError, "RoundsConfig.partitioned needs a `partition` for the model")
    checkLinearizable(h, init, model, cfg.budget, cfg.timeout)

proc runRounds*[I, Obj, Op, Res, SP](cfg: RoundsConfig, init: I, model: typedesc, setup: SP,
                                     genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
                                     exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                     teardown: proc (obj: var Obj) {.nimcall.} = nil,
                                     hooks = ThreadHooks()): RoundsResult[Op, Res] =
  ## Runs up to `cfg.rounds` rounds and stops at the first one that fails:
  ## `exec` raised (`error`), or the history is not linearizable
  ## (`vkNotLinearizable` or `vkInconclusive`). `init` is the model's initial
  ## state, or `proc (round: int): S` giving it per round. `setup` is
  ## `proc (obj: var Obj)` or `proc (obj: var Obj, info: RoundInfo)`. On
  ## failure the history is shrunk (if `cfg.shrink` and not inconclusive) and
  ## saved as `<saveDir>/<name>-seed<seed>-round<r>.jsonl` (with `-2`, `-3`...
  ## if that file exists). `describe` prints it all.
  validate(cfg)
  result.seed = cfg.seed
  result.passed = true
  template check(h, st): untyped =
    checkWith(cfg, h, st, model)
  for r in 1 .. cfg.rounds:
    result.rounds = r
    when compiles(init(r)):
      let st = init(r)
    else:
      let st = init
    let (h, err) = runRoundImpl(cfg, r, setup, genOp, exec, teardown, hooks)
    let v = check(h, st)
    if err.len == 0 and v.kind == vkLinearizable: continue
    result.passed = false
    result.error = err
    result.original = h
    result.history = h
    result.verdict = v
    if cfg.shrink and v.kind == vkNotLinearizable:
      result.history = shrink(h, st, model, cfg.budget, cfg.partitioned, cfg.shrinkTimeout)
      result.verdict = check(result.history, st)
    let dir = if cfg.saveDir.len > 0: cfg.saveDir else: getTempDir()
    try:
      createDir(dir)
      let path = freePath(dir, cfg.name & "-seed" & $cfg.seed & "-round" & $r)
      writeFile(path, result.history.toJsonLines())
      result.savedTo = path
    except CatchableError as e:
      result.saveError = $e.name & ": " & e.msg
    return

proc describe*[Op, Res](r: RoundsResult[Op, Res]): string =
  ## Summary for test output: rounds, seed, error, report with timeline, saved file.
  if r.passed:
    return "linearizable in all " & $r.rounds & " rounds (seed " & $r.seed & ")\n"
  result = "failed in round " & $r.rounds & " (seed " & $r.seed & ")"
  if r.history.events.len < r.original.events.len:
    result.add ", shrunk from " & $r.original.events.len & " to " & $r.history.events.len & " events"
  if r.error.len > 0:
    result.add "\nexec raised in " & r.error & "\n"
  result.add "\n" & report(r.verdict, r.history)
  if r.savedTo.len > 0: result.add "history saved to " & r.savedTo & "\n"
  if r.saveError.len > 0: result.add "history not saved: " & r.saveError & "\n"
