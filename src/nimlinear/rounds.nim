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

import std/[atomics, monotimes, os, random, sets, times]
import std/strutils
import ./[history, checker, json, perturb, recorder, report, shrink]

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
    shrinkTimeout*: Duration    ## overall limit for `shrink` (and replay); zero = none
    replayShrink*: bool         ## also shrink by re-running the real code (D-27); needs deterministic rounds
    schedule*: bool             ## run every round under the PCT scheduler (D-29); needs -d:nimlinearPerturb
    depth*: int = 3             ## PCT depth when `schedule`
    steps*: int                 ## PCT steps when `schedule`; 0 = calibrate on round 1 (D-29)
    explore*: bool              ## D-32: enumerate the schedules of every round instead of PCT; needs -d:nimlinearPerturb
    preemptions*: int = 2       ## when `explore`: most preemptions per schedule
    maxSchedules*: int = 10_000 ## when `explore`: cap per round; beyond it the round is not complete
    reduce*: bool               ## when `explore`: skip schedules that only reorder independent steps
                                ## (sleep sets); needs -d:nimlinearInterceptLoads, see docs/API.md
    stepLimit*: int = 1_000_000 ## P14: under `schedule`/`explore`, abort a round past this many
                                ## switch points (livelock); 0 = no limit. Deadlocks always abort
    roundTimeout*: Duration     ## watchdog: a round longer than this writes a `.hung.txt`
                                ## report and ends the process with exit code 124; zero = none
    trackProgress*: bool = true ## P13: write seed and round to `<saveDir>/<name>-seed<s>.inprogress`
                                ## before each round; removed when the run ends, kept if the process dies
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
    scenario*: seq[seq[Op]]      ## operations per thread of the failing round (reduced by replay)
    replay*: string              ## what `replayShrink` did, "" if not requested
    steps*: int                  ## PCT steps used when `schedule` (calibrated if `cfg.steps == 0`)
    saveError*: string           ## why saving failed, "" if it did not
    trace*: seq[SwitchPoint]     ## switch points of the failing round under `schedule` (P12)
    traceDropped*: int           ## switch points beyond the trace limit, not kept
    traceSavedTo*: string        ## path of the saved trace (`.trace.txt`), "" if none
    invariant*: string           ## P15: message of the `quiescent` hook in the failing round, "" if none
    previousRun*: string         ## P13: contents of an `.inprogress` file left by a run that died, "" if none
    explored*: int               ## schedules run when `explore` (D-32)
    complete*: bool              ## `explore`: every round ran all its schedules within `preemptions`
    schedule*: seq[int]          ## `explore`: thread chosen at each decision of the failing schedule
    warnings*: seq[string]       ## signs that the run tested less than it seems (no switch
                                 ## points, OS scheduler only); `describe` prints them
    originalVerdict*: Verdict[Op, Res] ## verdict of `original` (before shrink)
    originalSavedTo*: string     ## path of the recorded history when it differs
                                 ## from `history` (`<savedTo minus .jsonl>.original.jsonl`), "" if none

  Ctx[Obj, Op, Res] = object
    obj: ptr Obj
    rec: ptr Recorder[Op, Res]
    ops: ptr seq[Op]
    err: ptr string
    tid: int
    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.}
    hooks: ThreadHooks

var gLastTrace: seq[SwitchPoint]   # trace of the last scheduled round (P12)
var gLastDropped: int
var gForced: seq[int]              # D-32: choices to force in the next round
var gChosen: seq[int]              # D-32: choices made in the last round
var gDiverged: bool
var gLastInvariant: string         # P15: message of the quiescent hook, "" = fine

type Watch = object
  ## Watchdog of one round: a round that hangs outside the switch points
  ## (I/O, a plain lock, a join) cannot be stopped, but it can be reported.
  done: ptr Atomic[bool]
  limitMs: int
  path: string       # report file
  report: string     # seed, round and scenario, prepared before the round
  traced: bool       # append the scheduler's trace so far

var gTraceNow: proc (): string {.nimcall, gcsafe.}   # set when the scheduler exists

proc isSet(d: Duration): bool = d > DurationZero
  # non-generic, so the Duration operator resolves here (as in shrink.nim)
proc millis(d: Duration): int = int(d.inMilliseconds)

proc watchdog(w: Watch) {.thread.} =
  var waited = 0
  while not w.done[].load:
    if waited >= w.limitMs:
      var text = w.report
      if w.traced and gTraceNow != nil: text.add gTraceNow()
      try: writeFile(w.path, text)
      except CatchableError: discard
      try:
        stderr.writeLine "nimlinear: round still running after " & $w.limitMs &
          " ms; report written to " & w.path & "; ending the process (exit 124)"
      except CatchableError: discard
      quit(124)
    sleep(10)
    waited += 10

when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
  import ./schedule
  var gRoundSched: Scheduler   # the scheduler of `RoundsConfig.schedule`
  var gExplored: seq[Decision]     # D-32: decisions of the last round
  var gDone: seq[seq[(int, Footprint)]]   # D-32: per node of the current path, options explored
  proc nextForced(d: seq[Decision], bound: int, reduce: bool,
                  done: var seq[seq[(int, Footprint)]]): (bool, seq[int]) =
    ## Depth-first: the deepest decision with an option not yet explored
    ## (and, with `reduce`, not asleep) within the preemption bound; the
    ## prefix before it is kept. `done` records, per node, what was explored
    ## there with its footprint, for the sleep sets of the next run.
    done.setLen d.len
    var pre = newSeq[int](d.len + 1)   # preemptions in d[0 ..< j]
    for j, x in d: pre[j + 1] = pre[j] + ord(x.isPreemption(x.chosen))
    for j in countdown(d.high, 0):
      var tried = @[d[j].chosen]
      for (t, _) in done[j]: tried.add t
      for m in d[j].options:          # exploration order
        if m in tried or (reduce and m in d[j].sleep): continue
        if pre[j] + ord(d[j].isPreemption(m)) <= bound:
          done[j].add (d[j].chosen, d[j].fp)
          done.setLen j + 1
          var f: seq[int]
          for x in d[0 ..< j]: f.add x.chosen
          f.add m
          return (true, f)
    (false, @[])
  proc traceNow(): string {.nimcall, gcsafe.} =
    {.cast(gcsafe).}:
      result = "switch points so far (last 50):\n"
      let tr = gRoundSched.traceSnapshot
      for p in tr[max(0, tr.len - 50) .. ^1]:
        result.add "  " & $p.step & "  thread " & $p.thread & "  " & p.kind & "  " &
          p.file & ":" & $p.line & "\n"
  proc schedEnter(tid: int) {.nimcall, gcsafe, raises: [].} =
    {.cast(gcsafe).}: gRoundSched.enter(tid)
  proc schedLeave() {.nimcall, gcsafe, raises: [].} =
    {.cast(gcsafe).}: gRoundSched.leave()

proc worker[Obj, Op, Res](c: Ctx[Obj, Op, Res]) {.thread.} =
  if c.hooks.enter != nil: c.hooks.enter(c.tid)
  try:
    for k, op in c.ops[]:
      try:
        when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
          try:
            # The invoke and the return are writes to the shared history: steps
            # that record events never commute (reduction, D-32).
            noteAccess(c.rec)
            discard c.rec[].record(c.tid, op):
              (let r = c.exec(c.obj, op); noteAccess(c.rec); r)
          except RoundAborted as e:
            # P14: the scheduler found the round stuck; the operation stays pending.
            c.err[] = "round aborted by the scheduler: " & e.msg &
                      " (thread " & $c.tid & " was in operation " & $k & ", " & $op & ")"
            break
        else:
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
  if cfg.schedule:
    when not (defined(nimlinearPerturb) or defined(nimlinearStrict)):
      raise newException(ValueError, "RoundsConfig.schedule needs -d:nimlinearPerturb (or -d:nimlinearStrict)")
    if cfg.depth < 1: raise newException(ValueError, "RoundsConfig.depth must be >= 1, got " & $cfg.depth)
    if cfg.steps < 0: raise newException(ValueError, "RoundsConfig.steps must be >= 0, got " & $cfg.steps)
  if cfg.explore:
    when not (defined(nimlinearPerturb) or defined(nimlinearStrict)):
      raise newException(ValueError, "RoundsConfig.explore needs -d:nimlinearPerturb (or -d:nimlinearStrict)")
    if cfg.schedule:
      raise newException(ValueError, "RoundsConfig: choose `schedule` (PCT) or `explore`, not both")
    if cfg.preemptions < 0: raise newException(ValueError, "RoundsConfig.preemptions must be >= 0")
    if cfg.maxSchedules < 1: raise newException(ValueError, "RoundsConfig.maxSchedules must be >= 1")
    if cfg.reduce and not (defined(nimlinearInterceptLoads) or defined(nimlinearStrict)):
      raise newException(ValueError, "RoundsConfig.reduce needs -d:nimlinearInterceptLoads: " &
        "a load that is not a switch point is an access the reduction cannot see")

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

proc genOps[Op](cfg: RoundsConfig, round: int,
                genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.}): seq[seq[Op]] =
  ## The operations of a round, per thread: `genOp` with `initRand(roundSeed(seed, round))`.
  var rng = initRand(roundSeed(cfg.seed, round))
  result = newSeq[seq[Op]](cfg.threads)
  for t in 0 ..< cfg.threads:
    for k in 0 ..< cfg.opsPerThread: result[t].add genOp(rng, t, k)

proc runOps[Obj, Op, Res, SP](cfg: RoundsConfig, round: int, ops: seq[seq[Op]], setup: SP,
                              exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                              teardown: proc (obj: var Obj) {.nimcall.},
                              hooks: ThreadHooks,
                              quiescent: proc (obj: var Obj): string {.nimcall.} = nil):
                              (History[Op, Res], string, int) =
  ## Runs one round; returns the history, the first `exec` error ("" if
  ## none) and the switch points taken under `cfg.schedule` (0 otherwise).
  ## Under `cfg.schedule`, `cfg.steps` must already be resolved (> 0).
  if ops.len != cfg.threads:
    raise newException(ValueError, "scenario has " & $ops.len &
      " thread lists, RoundsConfig.threads is " & $cfg.threads)
  let info = RoundInfo(round: round, seed: roundSeed(cfg.seed, round))
  var ops = ops
  var obj: Obj
  if (cfg.schedule or cfg.explore) and (hooks.enter != nil or hooks.leave != nil):
    # checked before `setup`, which may install things `teardown` removes
    raise newException(ValueError, "RoundsConfig.schedule installs its own ThreadHooks; pass none")
  when compiles(setup(obj, info)): setup(obj, info)
  else: setup(obj)
  var hooks = hooks
  var taken = 0
  if cfg.schedule or cfg.explore:
    when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
      gRoundSched.initScheduler(cfg.threads, info.seed, cfg.depth, max(1, cfg.steps),
                                explore = cfg.explore, forced = gForced,
                                abortOnStuck = true, stepLimit = cfg.stepLimit,
                                reduce = cfg.reduce, doneIn = gDone)
      hooks = ThreadHooks(enter: schedEnter, leave: schedLeave)
  var rec = newRecorder[Op, Res](cfg.threads)
  var errs = newSeq[string](cfg.threads)
  # Thread objects in fixed shared memory (not a seq): their addresses must
  # stay valid for the OS thread's whole life.
  type T = Thread[Ctx[Obj, Op, Res]]
  let ths = cast[ptr UncheckedArray[T]](allocShared0(sizeof(T) * cfg.threads))
  var started = 0
  var wdone: Atomic[bool]
  var wth: Thread[Watch]
  let watching = isSet(cfg.roundTimeout)
  if watching:
    when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
      gTraceNow = traceNow
    var rep = "nimlinear: round " & $round & " did not end within " & $cfg.roundTimeout &
      " (seed " & $cfg.seed & ", per-round seed " & $info.seed & ")\n" &
      "Rerun with the same RoundsConfig and rounds = " & $round &
      "; under schedule or explore it repeats exactly.\noperations per thread:\n"
    for t, l in ops: rep.add "  thread " & $t & ": " & $l & "\n"
    let dir = if cfg.saveDir.len > 0: cfg.saveDir else: getTempDir()
    try: createDir(dir)
    except CatchableError: discard
    createThread(wth, watchdog, Watch(done: addr wdone, limitMs: millis(cfg.roundTimeout),
      path: dir / (cfg.name & "-seed" & $cfg.seed & "-round" & $round & ".hung.txt"),
      report: rep, traced: cfg.schedule or cfg.explore))
  try:
    for t in 0 ..< cfg.threads:
      createThread(ths[t], worker[Obj, Op, Res],
                   Ctx[Obj, Op, Res](obj: addr obj, rec: addr rec, ops: addr ops[t],
                                     err: addr errs[t], tid: t, exec: exec, hooks: hooks))
      inc started
  finally:
    # Also on a failed createThread: join what started, then free.
    for t in 0 ..< started: joinThread(ths[t])
    if watching:
      wdone.store(true)
      joinThread(wth)
    for t in 0 ..< cfg.threads: `=destroy`(ths[t])
    deallocShared(ths)
    when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
      if cfg.schedule or cfg.explore:
        taken = gRoundSched.stepsTaken
        gLastTrace = gRoundSched.trace
        gLastDropped = gRoundSched.traceDropped
        if cfg.explore:
          gExplored = gRoundSched.decisions
          gDiverged = gRoundSched.diverged
        gRoundSched.deinitScheduler()
    if quiescent != nil:
      # P15: every thread finished; the object is quiescent.
      try: gLastInvariant = quiescent(obj)
      except CatchableError as e: gLastInvariant = "raised " & $e.name & ": " & e.msg
    if teardown != nil: teardown(obj)
  var err = ""
  for e in errs:
    if e.len > 0:
      err = e
      break
  (rec.snapshot(), err, taken)

const calibrationSteps = high(int) div 2
  ## steps while calibrating: change points fall after the round ends, so the
  ## run is plain priority order and only counts the switch points.

proc resolveSteps[Obj, Op, Res, SP](cfg: RoundsConfig, ops: seq[seq[Op]], setup: SP,
                                    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                    teardown: proc (obj: var Obj) {.nimcall.},
                                    hooks: ThreadHooks): (RoundsConfig, int) =
  ## D-29: with `schedule` and `steps == 0`, runs `ops` once as round 1 to
  ## count the switch points and uses that count as `steps`. Also returns
  ## the count (-1 when not calibrated).
  result = (cfg, -1)
  if cfg.schedule and cfg.steps == 0:
    var c = cfg
    c.steps = calibrationSteps
    let (_, _, taken) = runOps(c, 1, ops, setup, exec, teardown, hooks)
    result[0].steps = max(1, taken)
    result[1] = taken

proc runRoundImpl[Obj, Op, Res, SP](cfg: RoundsConfig, round: int, setup: SP,
                                    genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
                                    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                    teardown: proc (obj: var Obj) {.nimcall.},
                                    hooks: ThreadHooks): (History[Op, Res], string) =
  validate(cfg)
  let c = resolveSteps(cfg, genOps(cfg, 1, genOp), setup, exec, teardown, hooks)[0]
  let (h, err, _) = runOps(c, round, genOps(cfg, round, genOp), setup, exec, teardown, hooks)
  (h, err)

proc runScenario*[Obj, Op, Res, SP](cfg: RoundsConfig, round: int, ops: seq[seq[Op]], setup: SP,
                                    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                    teardown: proc (obj: var Obj) {.nimcall.} = nil,
                                    hooks = ThreadHooks()): History[Op, Res] =
  ## One recorded round from explicit operations (D-27): `ops[t]` runs on
  ## thread `t` (`ops.len` must equal `cfg.threads`; a list may be empty).
  ## `opsPerThread` is ignored. `setup` receives the same `RoundInfo` as
  ## round `round` of `runRounds`, so a scheduler gets the same seed. Raises
  ## `ExecError` like `runRound`, `ValueError` for a wrong number of lists.
  ## With `schedule` and `steps == 0`, `steps` is calibrated on `ops`
  ## itself; to replay a round of `runRounds`, pass its `RoundsResult.steps`.
  validate(cfg)
  let c = resolveSteps(cfg, ops, setup, exec, teardown, hooks)[0]
  let (h, err, _) = runOps(c, round, ops, setup, exec, teardown, hooks)
  if err.len > 0: raise newException(ExecError, err)
  h

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

type ReplayDeadline = object
  use: bool
  at: MonoTime

# Non-generic, so MonoTime/Duration operators resolve here, not at the caller.
proc initReplayDeadline(timeout: Duration): ReplayDeadline =
  ReplayDeadline(use: timeout > DurationZero, at: getMonoTime() + timeout)

proc expired(d: ReplayDeadline): bool = d.use and getMonoTime() >= d.at

type ReplaySig[Op, Res] = object
  fails: bool
  thread: int
  call: Op
  expected: Res

proc replaySig[Op, Res](h: History[Op, Res], v: Verdict[Op, Res]): ReplaySig[Op, Res] =
  ## The D-24 signature by content (thread, call, expected): `OpId`s shift
  ## when operations are removed from a scenario.
  if v.kind != vkNotLinearizable: return
  result.fails = true
  for e in h.events:
    if e.op == v.witness.stuck and e.kind != ekReturn:
      result.thread = int(e.thread)
      result.call = e.call
      break
  for a in v.witness.alternatives:
    if a.candidate == v.witness.stuck:
      result.expected = a.expected
      break

proc sameSig[Op, Res](a, b: ReplaySig[Op, Res]): bool =
  mixin `==`
  a.fails and b.fails and a.thread == b.thread and a.call == b.call and a.expected == b.expected

proc opCount[Op](ops: seq[seq[Op]]): int =
  for l in ops: result += l.len

proc replayShrink[S, Obj, Op, Res, SP](cfg: RoundsConfig, round: int, ops: seq[seq[Op]],
                                       h: History[Op, Res], v: Verdict[Op, Res], init: S,
                                       model: typedesc, setup: SP,
                                       exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                       teardown: proc (obj: var Obj) {.nimcall.},
                                       hooks: ThreadHooks, keepHint: HashSet[(int, int)]):
                                       (seq[seq[Op]], History[Op, Res], Verdict[Op, Res], string) =
  ## D-27: greedy removal over the scenario, keeping a removal only if the
  ## real code still fails with the same signature. `keepHint` holds the
  ## (thread, index) of operations the history-only shrink kept; the others
  ## are tried first.
  let dl = initReplayDeadline(cfg.shrinkTimeout)
  template expired(): bool = dl.expired
  # 1. Determinism is checked, not assumed: the same scenario again must
  #    give the same history, byte for byte.
  let (h2, err2, _) = runOps(cfg, round, ops, setup, exec, teardown, hooks)
  if err2.len > 0 or h2.toJsonLines() != h.toJsonLines():
    return (ops, h, v, "skipped: the round is not deterministic (running it again gave " &
                       "another history); run it under nimlinear/schedule")
  let sig = replaySig(h, v)
  var cur = ops
  var curH = h
  var curV = v
  var timedOut = false
  template attempt(cand: seq[seq[Op]]): bool =
    let (ch, cerr, _) = runOps(cfg, round, cand, setup, exec, teardown, hooks)
    var kept = false
    if cerr.len == 0:
      let cv = checkWith(cfg, ch, init, model)
      if sameSig(sig, replaySig(ch, cv)):
        cur = cand; curH = ch; curV = cv
        kept = true
    kept
  var progress = true
  while progress and not timedOut:
    progress = false
    for t in 0 ..< cur.len:                  # whole threads first
      if expired(): timedOut = true; break
      if cur[t].len == 0 or t == sig.thread: continue
      var cand = cur
      cand[t] = @[]
      if attempt(cand): progress = true
    # Single operations, from the end of each thread: first those the
    # history-only shrink dropped (index in the original scenario), then the rest.
    for pass in 0 .. 1:
      for t in 0 ..< cur.len:
        var k = cur[t].len - 1
        while k >= 0 and not timedOut:
          if expired(): timedOut = true; break
          if (pass == 0) == ((t, k) notin keepHint):
            var cand = cur
            cand[t].delete(k)
            if attempt(cand): progress = true
          dec k
  let msg = "shrunk the scenario from " & $opCount(ops) & " to " & $opCount(cur) &
            " operations by running the real code" &
            (if timedOut: " (stopped by shrinkTimeout)" else: "")
  (cur, curH, curV, msg)

proc progressPath*(cfg: RoundsConfig): string =
  ## P13: where `runRounds` records the round in progress; "" when
  ## `trackProgress` is off.
  if not cfg.trackProgress: return ""
  let dir = if cfg.saveDir.len > 0: cfg.saveDir else: getTempDir()
  dir / (cfg.name & "-seed" & $cfg.seed & ".inprogress")

proc writeProgress(path: string, cfg: RoundsConfig, round: int) =
  # One small file, rewritten (and so flushed and closed) before each round,
  # so it survives a crash inside the round. A failed write never stops the run.
  if path.len == 0: return
  try:
    createDir(path.parentDir)
    writeFile(path, "nimlinear: round " & $round & " of " & $cfg.rounds & " was running, seed " &
      $cfg.seed & ", per-round seed " & $roundSeed(cfg.seed, round) &
      (if cfg.schedule: ", PCT steps " & $cfg.steps else: "") &
      (if cfg.explore: ", explore" else: "") &
      ". Rerun it with the same RoundsConfig and rounds = " & $round &
      " (or runRound(cfg, " & $round & ", ...)); under schedule or explore it repeats exactly.\n")
  except CatchableError: discard

proc formatTrace*(trace: seq[SwitchPoint], dropped = 0, last = 0): string =
  ## One line per switch point: `step  thread  kind  file:line` (P12). With
  ## `last > 0`, only the last `last` points (the ones closest to the end of
  ## the round). The trace is that of the recorded round, not of the shrunk
  ## history, and exact only at controlled switch points.
  let first = (if last > 0: max(0, trace.len - last) else: 0)
  if first > 0: result.add "(" & $first & " earlier switch points omitted)\n"
  for p in trace[first .. ^1]:
    result.add align($p.step, 6) & "  thread " & $p.thread & "  " &
      alignLeft(p.kind, 18) & p.file & ":" & $p.line & "\n"
  if dropped > 0: result.add "(" & $dropped & " later switch points not kept)\n"

const noPointsHint = "Check that the code under test imports nimlinear/intercept (or calls perturb()) " &
  "in this build, and compile the test with -d:nimlinearStrict"

proc runRounds*[I, Obj, Op, Res, SP](cfg: RoundsConfig, init: I, model: typedesc, setup: SP,
                                     genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
                                     exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
                                     teardown: proc (obj: var Obj) {.nimcall.} = nil,
                                     hooks = ThreadHooks(),
                                     quiescent: proc (obj: var Obj): string {.nimcall.} = nil):
                                     RoundsResult[Op, Res] =
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
  let (cfg, calibrated) = (if cfg.rounds > 0: resolveSteps(cfg, genOps(cfg, 1, genOp), setup, exec, teardown, hooks)
                           else: (cfg, -1))
  result.steps = (if cfg.schedule: cfg.steps else: 0)
  if calibrated == 0:
    result.warnings.add "round 1 had no switch points, so the scheduler had nothing to interleave. " &
      noPointsHint
  defer:
    if cfg.explore and result.passed and result.rounds > 0 and result.explored == result.rounds:
      result.warnings.add "every round had a single schedule: no switch points to explore. " & noPointsHint
    if not cfg.schedule and not cfg.explore and
        not (defined(nimlinearPerturb) or defined(nimlinearStrict)):
      result.warnings.add "ran under the OS scheduler only, which seldom produces narrow races. " &
        "For a stronger test, compile with -d:nimlinearStrict and set `schedule = true` (or `explore = true`)"
  result.complete = cfg.explore
  template check(h, st): untyped =
    checkWith(cfg, h, st, model)
  let progress = progressPath(cfg)
  if progress.len > 0 and fileExists(progress):
    # P13: a file left behind means an earlier run died inside that round.
    try: result.previousRun = readFile(progress).strip()
    except CatchableError: discard
  try:
    for r in 1 .. cfg.rounds:
      result.rounds = r
      writeProgress(progress, cfg, r)
      when compiles(init(r)):
        let st = init(r)
      else:
        let st = init
      let ops = genOps(cfg, r, genOp)
      gForced.setLen 0
      when (defined(nimlinearPerturb) or defined(nimlinearStrict)): gDone.setLen 0
      var nSched = 0
      var h: History[Op, Res]
      var err: string
      var v: Verdict[Op, Res]
      while true:
        gLastTrace.setLen 0
        gLastDropped = 0
        gDiverged = false
        gLastInvariant = ""
        (h, err) = (let x = runOps(cfg, r, ops, setup, exec, teardown, hooks, quiescent); (x[0], x[1]))
        let inv = gLastInvariant
        v = check(h, st)
        if not cfg.explore: break
        when (defined(nimlinearPerturb) or defined(nimlinearStrict)):
          inc nSched
          inc result.explored
          gChosen.setLen 0
          for d in gExplored: gChosen.add d.chosen
          if gDiverged:
            result.passed = false
            result.complete = false
            result.error = "explore: the code under test chose differently under the same schedule " &
              "(not deterministic), so exploration stopped (D-32)"
            result.original = h
            result.originalVerdict = v
            result.history = h
            result.verdict = v
            result.scenario = ops
            result.schedule = gChosen
            return
          if err.len > 0 or inv.len > 0 or v.kind != vkLinearizable: break
          let (more, next) = nextForced(gExplored, cfg.preemptions, cfg.reduce, gDone)
          if not more: break
          if nSched >= cfg.maxSchedules:
            result.complete = false
            break
          gForced = next
      if err.len == 0 and gLastInvariant.len == 0 and v.kind == vkLinearizable: continue
      result.invariant = gLastInvariant
      if cfg.explore:
        result.schedule = gChosen
        result.complete = false
      result.trace = gLastTrace          # before replay runs other rounds
      result.traceDropped = gLastDropped
      result.passed = false
      result.error = err
      result.original = h
      result.originalVerdict = v
      result.history = h
      result.verdict = v
      result.scenario = ops
      if cfg.shrink and v.kind == vkNotLinearizable:
        result.history = shrink(h, st, model, cfg.budget, cfg.partitioned, cfg.shrinkTimeout)
        result.verdict = check(result.history, st)
        if cfg.replayShrink and cfg.explore:
          result.replay = "skipped: replay shrinks by PCT seed; under `explore` the failing schedule is in `schedule`"
        elif cfg.replayShrink:
          var keep = initHashSet[(int, int)]()   # (thread, index) kept by the history-only shrink
          for e in result.history.events:
            if e.kind == ekInvoke:
              keep.incl (int(e.thread), (int(e.op) - 1) div cfg.threads)
          let (sc, rh, rv, msg) = replayShrink(cfg, r, ops, h, v, st, model, setup, exec,
                                               teardown, hooks, keep)
          result.replay = msg
          if sc.opCount < ops.opCount:
            result.scenario = sc
            result.history = rh        # a real execution of the reduced scenario
            result.verdict = rv
      elif cfg.replayShrink:
        result.replay = "skipped: replay needs a vkNotLinearizable round"
      let dir = if cfg.saveDir.len > 0: cfg.saveDir else: getTempDir()
      try:
        createDir(dir)
        let path = freePath(dir, cfg.name & "-seed" & $cfg.seed & "-round" & $r)
        writeFile(path, result.history.toJsonLines())
        result.savedTo = path
        let orig = result.original.toJsonLines()
        if orig != result.history.toJsonLines():
          let opath = path.changeFileExt("original.jsonl")
          writeFile(opath, orig)
          result.originalSavedTo = opath
        if result.trace.len > 0:
          let tpath = path.changeFileExt("trace.txt")
          writeFile(tpath, formatTrace(result.trace, result.traceDropped))
          result.traceSavedTo = tpath
      except CatchableError as e:
        result.saveError = $e.name & ": " & e.msg
      return
  finally:
    # Reached on pass, failure and exceptions; not on a crash, so the file
    # then still names the round that was running.
    if progress.len > 0:
      try: removeFile(progress)
      except CatchableError: discard

const smallShrunk = 3   ## shrunk to this many operations or fewer: also show the recorded history
const scheduleShown = 60 ## decisions of a failing schedule printed by `describe`

proc opCount[Op, Res](h: History[Op, Res]): int =
  for e in h.events:
    if e.kind in {ekInvoke, ekTick}: inc result

proc warningLines(ws: seq[string]): string =
  for w in ws: result.add "warning: " & w & "\n"

proc describe*[Op, Res](r: RoundsResult[Op, Res]): string =
  ## Summary for test output: rounds, seed, error, report with timeline, saved file.
  if r.passed:
    return (if r.previousRun.len > 0: "note: a previous run did not finish: " & r.previousRun & "\n" else: "") &
      "linearizable in all " & $r.rounds & " rounds (seed " & $r.seed &
      (if r.steps > 0: ", PCT steps " & $r.steps else: "") &
      (if r.explored > 0: ", " & $r.explored & " schedules explored, " &
        (if r.complete: "complete within the preemption bound" else: "NOT complete: maxSchedules reached")
       else: "") & ")\n" & warningLines(r.warnings)
  result.add warningLines(r.warnings)
  if r.previousRun.len > 0:
    result.add "note: a previous run did not finish: " & r.previousRun & "\n"
  result.add "failed in round " & $r.rounds & " (seed " & $r.seed &
    (if r.steps > 0: ", PCT steps " & $r.steps else: "") & ")"
  if r.history.events.len < r.original.events.len:
    result.add ", shrunk from " & $r.original.events.len & " to " & $r.history.events.len & " events"
  if r.explored > 0:
    result.add ", after " & $r.explored & " explored schedules; failing schedule (thread per decision"
    if r.schedule.len > scheduleShown:
      result.add ", last " & $scheduleShown & " of " & $r.schedule.len & "): " &
        $r.schedule[^scheduleShown .. ^1]
    else:
      result.add "): " & $r.schedule
  if r.invariant.len > 0:
    result.add "\ninvariant broken after the round (quiescent): " & r.invariant & "\n"
  if r.error.len > 0:
    result.add "\nexec raised in " & r.error & "\n"
  if r.replay.len > 0:
    result.add "\nreplay: " & r.replay & "\n"
  result.add "\n" & report(r.verdict, r.history)
  let shrunkOps = opCount(r.history)
  if shrunkOps <= smallShrunk and opCount(r.original) > shrunkOps:
    # A tiny shrunk history can look impossible on its own (D-24); the
    # recorded one shows the context the failure came from.
    result.add "recorded history before shrinking (" & $opCount(r.original) & " operations):\n" &
      timeline(r.original, r.originalVerdict)
  if r.trace.len > 0:
    result.add "switch points of the recorded round (last 30):\n" &
      formatTrace(r.trace, r.traceDropped, last = 30)
  if r.savedTo.len > 0: result.add "history saved to " & r.savedTo & "\n"
  if r.traceSavedTo.len > 0: result.add "trace saved to " & r.traceSavedTo & "\n"
  if r.originalSavedTo.len > 0: result.add "recorded history saved to " & r.originalSavedTo & "\n"
  if r.saveError.len > 0: result.add "history not saved: " & r.saveError & "\n"
