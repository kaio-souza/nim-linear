## Round harness (M17): runs many short concurrent rounds against a real
## object, records them, checks each one, and on the first failure shrinks
## and saves the history. Requires --threads:on.
##
## Per round: `setup` builds a fresh object; every thread gets its own list of
## `opsPerThread` operations from `genOp(rng, thread, index)` (drawn on the main thread from
## `initRand(seed, round)`, so the same seed gives the same operations);
## threads start, run `exec` on each operation through `Recorder.record`, and
## join; `teardown` runs; the history is checked. See docs/GUIDE.md.

when not compileOption("threads"):
  {.error: "nimlinear/rounds requires --threads:on".}

import std/[os, random]
import ./[history, checker, json, recorder, report, shrink]

type
  RoundsConfig* = object
    threads*: int = 3
    rounds*: int = 100
    opsPerThread*: int = 4
    seed*: int = 1
    budget*: int = 1_000_000
    shrink*: bool = true        ## shrink the failing history (M16)
    saveDir*: string            ## where to save it; "" = getTempDir()
    name*: string = "nimlinear" ## file name prefix

  ThreadHooks* = object
    ## Optional calls at the start and end of each thread, e.g. to register
    ## with a `Scheduler` (nimlinear/schedule). `nil` = no call.
    enter*: proc (thread: int) {.nimcall, gcsafe, raises: [].}
    leave*: proc () {.nimcall, gcsafe, raises: [].}

  RoundsResult*[Op, Res] = object
    passed*: bool                ## every round linearizable
    rounds*: int                 ## rounds run (the failing one included)
    seed*: int
    verdict*: Verdict[Op, Res]   ## of the failing round (shrunk history if shrink)
    history*: History[Op, Res]   ## failing history (shrunk if shrink)
    original*: History[Op, Res]  ## failing history as recorded
    savedTo*: string             ## path of the saved (shrunk) history, "" if none

  Ctx[Obj, Op, Res] = object
    obj: ptr Obj
    rec: ptr Recorder[Op, Res]
    ops: ptr seq[Op]
    tid: int
    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.}
    hooks: ThreadHooks

proc worker[Obj, Op, Res](c: Ctx[Obj, Op, Res]) {.thread.} =
  if c.hooks.enter != nil: c.hooks.enter(c.tid)
  for op in c.ops[]:
    discard c.rec[].record(c.tid, op): c.exec(c.obj, op)
  if c.hooks.leave != nil: c.hooks.leave()

proc validate*(cfg: RoundsConfig) =
  ## Raises `ValueError` for a config that cannot run.
  if cfg.threads < 1: raise newException(ValueError, "RoundsConfig.threads must be >= 1, got " & $cfg.threads)
  if cfg.opsPerThread < 0: raise newException(ValueError, "RoundsConfig.opsPerThread must be >= 0, got " & $cfg.opsPerThread)
  if cfg.rounds < 0: raise newException(ValueError, "RoundsConfig.rounds must be >= 0, got " & $cfg.rounds)

proc runRound*[Obj, Op, Res](cfg: RoundsConfig, round: int,
                             setup: proc (obj: var Obj) {.nimcall.},
                             genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
                             exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                             teardown: proc (obj: var Obj) {.nimcall.} = nil,
                             hooks = ThreadHooks()): History[Op, Res] =
  ## One recorded round (no check). Exposed for tests that drive rounds
  ## themselves, e.g. to compare settings.
  validate(cfg)
  var rng = initRand(cfg.seed * 1_000_003 + round + 1)
  var ops = newSeq[seq[Op]](cfg.threads)
  for t in 0 ..< cfg.threads:
    for k in 0 ..< cfg.opsPerThread: ops[t].add genOp(rng, t, k)
  var obj: Obj
  setup(obj)
  var rec = newRecorder[Op, Res](cfg.threads)
  # Thread objects in fixed shared memory (not a seq): their addresses must
  # stay valid for the OS thread's whole life.
  type T = Thread[Ctx[Obj, Op, Res]]
  let ths = cast[ptr UncheckedArray[T]](allocShared0(sizeof(T) * cfg.threads))
  for t in 0 ..< cfg.threads:
    createThread(ths[t], worker[Obj, Op, Res],
                 Ctx[Obj, Op, Res](obj: addr obj, rec: addr rec, ops: addr ops[t], tid: t,
                                   exec: exec, hooks: hooks))
  for t in 0 ..< cfg.threads: joinThread(ths[t])
  for t in 0 ..< cfg.threads: `=destroy`(ths[t])
  deallocShared(ths)
  if teardown != nil: teardown(obj)
  rec.snapshot()

proc runRounds*[S, Obj, Op, Res](cfg: RoundsConfig, init: S, model: typedesc,
                                 setup: proc (obj: var Obj) {.nimcall.},
                                 genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
                                 exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                 teardown: proc (obj: var Obj) {.nimcall.} = nil,
                                 hooks = ThreadHooks()): RoundsResult[Op, Res] =
  ## Runs up to `cfg.rounds` rounds and stops at the first one that is not
  ## linearizable (`vkNotLinearizable` or `vkInconclusive`). On failure the
  ## history is shrunk (if `cfg.shrink` and not inconclusive) and saved as
  ## `<saveDir>/<name>-seed<seed>-round<r>.jsonl`. `describe` prints it all.
  validate(cfg)
  result.seed = cfg.seed
  result.passed = true
  for r in 1 .. cfg.rounds:
    result.rounds = r
    let h = runRound(cfg, r, setup, genOp, exec, teardown, hooks)
    let v = checkLinearizable(h, init, model, cfg.budget)
    if v.kind == vkLinearizable: continue
    result.passed = false
    result.original = h
    result.history = h
    result.verdict = v
    if cfg.shrink and v.kind == vkNotLinearizable:
      result.history = shrink(h, init, model, cfg.budget)
      result.verdict = checkLinearizable(result.history, init, model, cfg.budget)
    let dir = if cfg.saveDir.len > 0: cfg.saveDir else: getTempDir()
    result.savedTo = dir / (cfg.name & "-seed" & $cfg.seed & "-round" & $r & ".jsonl")
    try:
      createDir(dir)
      writeFile(result.savedTo, result.history.toJsonLines())
    except CatchableError:
      result.savedTo = ""
    return

proc describe*[Op, Res](r: RoundsResult[Op, Res]): string =
  ## Summary for test output: rounds, seed, report with timeline, saved file.
  if r.passed:
    return "linearizable in all " & $r.rounds & " rounds (seed " & $r.seed & ")\n"
  result = "failed in round " & $r.rounds & " (seed " & $r.seed & ")"
  if r.history.events.len < r.original.events.len:
    result.add ", shrunk from " & $r.original.events.len & " to " & $r.history.events.len & " events"
  result.add "\n" & report(r.verdict, r.history)
  if r.savedTo.len > 0: result.add "history saved to " & r.savedTo & "\n"
