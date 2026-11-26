## Optional controlled scheduler (M13, D-18). Not imported by the core.
## Requires --threads:on and -d:nimlinearPerturb.
##
## Only one registered thread runs at a time. Threads switch only at
## `perturb()` points (from `nimlinear/perturb`), in `enter` and in `leave`.
## Who runs next is decided by PCT (Probabilistic Concurrency Testing,
## Burckhardt et al., ASPLOS 2010): each thread gets a random distinct
## priority; the highest-priority unfinished thread runs; at `depth - 1`
## random steps the running thread's priority drops below all initial ones.
## The same seed, threads and code give the same interleaving, so the same
## recorded history, byte for byte.
##
## Rules (otherwise the round can hang):
## - between `enter` and `leave`, a thread must not block in the OS waiting
##   for another registered thread: no joins, no blocking channel reads, and
##   no `perturb()` while holding a plain `Lock` others may take. Use
##   `SchedLock` (below) for locks inside the object under test: waiting for
##   it yields to the scheduler, so `perturb()` inside critical sections is
##   safe and bugs there can be found (M19);
## - one scheduler active at a time.
##
## `perturb()` and `SchedLock` from a thread that is not registered (did not
## call `enter`, or already called `leave`), such as the main thread in
## `setup`/`teardown`, are ignored by the scheduler: no switch, no waiting.
##
## Switches happen only at the points listed above: `perturb()`, `enter`,
## `leave`, `SchedLock.acquire` and `SchedCond.wait`. Code between two points runs atomically
## under the scheduler, so a bug whose window has no point is not explored.

when not compileOption("threads"):
  {.error: "nimlinear/schedule requires --threads:on".}
when not (defined(nimlinearPerturb) or defined(nimlinearStrict)):
  {.error: "nimlinear/schedule requires -d:nimlinearPerturb (or -d:nimlinearStrict)".}

import std/[atomics, locks, random, strutils]
import ./perturb

const traceCap* = 100_000
  ## Most switch points a Scheduler keeps in its trace (P12); later ones are
  ## counted in `traceDropped`.

export SwitchPoint

type
  RoundAborted* = object of Defect
    ## P14: raised at the next switch point of every registered thread when a
    ## scheduler with `abortOnStuck` finds the round stuck (deadlock, or more
    ## switch points than `stepLimit`). The round harness catches it; code that
    ## wires the scheduler itself must catch it in its threads. Needs the
    ## default `--panics:off`.

  Access* = object
    ## One object a step touches (reduction): its address, and whether the
    ## step may change it. `obj = nil` means unknown, which conflicts with
    ## everything.
    obj*: pointer
    write*: bool

  Footprint* = seq[Access]

  Decision* = object
    ## One scheduling decision in exploration mode (D-32).
    options*: seq[int]   ## runnable threads, in exploration order (see `order`)
    chosen*: int         ## thread that ran next
    current*: int        ## thread that reached the point (-1 at the start or after `leave`)
    sleep*: seq[int]     ## reduction: threads whose next step need not be tried here
    fp*: Footprint       ## reduction: what the step chosen here touched (set at the next decision)
    redundant*: bool     ## reduction: every option was asleep; the run continues on `chosen`

  Scheduler* = object
    lock: Lock
    cond: Cond
    n: int
    arrived: int
    current: int          # thread allowed to run; -1 before start
    done: seq[bool]
    prio: seq[int]
    changeAt: seq[int]    # step numbers where the running thread is demoted
    step: int
    waitingOn: seq[ptr SchedLock]   # lock each thread waits for (nil: runnable)
    condOf: seq[ptr SchedCond]      # condition each thread waits on (nil: none)
    deadlocked*: bool     ## every unfinished thread waited on a held SchedLock or a SchedCond
    trace: seq[SwitchPoint]
    traceDropped: int
    explore: bool                    # D-32: choices come from `forced`, then the default
    forced: seq[int]
    decisions: seq[Decision]
    diverged: bool                   # a forced choice was not runnable
    reduce: bool                     # sleep sets over step footprints
    doneIn: seq[seq[(int, Footprint)]]   # per node: siblings already explored, with footprints
    sleepAt: seq[seq[(int, Footprint)]]  # per node: sleep set with footprints
    pendingAcc: seq[Footprint]       # per thread: the operation it is parked before
    stepFp: Footprint                # what the running step touched so far
    abortOnStuck: bool               # P14: abort instead of waking a waiter
    stepLimit: int                   # P14: abort past this many switch points (0: none)
    aborted: bool
    abortReason: string

  SchedLock* = object
    ## Lock that cooperates with the scheduler. Without an active scheduler it
    ## is an ordinary `Lock`.
    lock: Lock
    held: bool            # under the scheduler (one thread runs at a time)

  SchedCond* = object
    ## Condition variable that cooperates with the scheduler, used with a
    ## `SchedLock`. Without an active scheduler it is an ordinary `Cond`.
    cond: Cond

var gSched: Atomic[pointer]   # the active Scheduler, or nil

template active(): ptr Scheduler = cast[ptr Scheduler](gSched.load(moAcquire))
var tTid {.threadvar.}: int
var tRegistered {.threadvar.}: bool   # between `enter` and `leave`

proc runnable(s: Scheduler, t: int): bool =
  not s.done[t] and s.condOf[t] == nil and
    (s.waitingOn[t] == nil or not s.waitingOn[t].held)

proc order*(d: Decision): seq[int] =
  ## Exploration order of `d.options`: the current thread first when it can
  ## go on (no preemption), then the others by increasing index.
  if d.current >= 0 and d.current in d.options: result.add d.current
  for t in d.options:
    if t != d.current: result.add t

proc isPreemption*(d: Decision, choice: int): bool =
  ## Choosing `choice` stops a thread that could have gone on.
  d.current >= 0 and d.current in d.options and choice != d.current

proc independent*(a, b: Footprint): bool =
  ## Two steps commute: no unknown access, and no object that both touch
  ## with at least one write.
  for x in a:
    if x.obj == nil: return false
    for y in b:
      if y.obj == nil: return false
      if x.obj == y.obj and (x.write or y.write): return false
  for y in b:
    if y.obj == nil: return false
  true

proc noteAccess(s: var Scheduler, obj: pointer, write: bool) =
  if s.reduce: s.stepFp.add Access(obj: obj, write: write)

proc noteAccess*(obj: pointer, write = true) {.raises: [].} =
  ## Records that the running step touches `obj` (for exploration with
  ## reduction), when the access is not a switch point: shared state the
  ## scheduler cannot see otherwise. The round harness calls it for every
  ## invoke and return it records. No effect outside a registered thread.
  {.cast(gcsafe).}:
    let s = active()
    if s == nil or not tRegistered: return
    acquire s.lock
    s[].noteAccess(obj, write)
    release s.lock

proc pickNext(s: var Scheduler, current = -1): int =
  result = -1
  if s.explore:
    var d = Decision(current: current, fp: @[Access(obj: nil, write: true)])  # unknown until it ends
    for t in 0 ..< s.n:
      if s.runnable(t): d.options.add t
    if d.options.len > 0:
      d.options = d.order
      let i = s.decisions.len
      var sleep: seq[(int, Footprint)]
      if s.reduce and i > 0:
        # The step chosen at node i-1 just ended: record what it touched, and
        # inherit into node i every sleeping or explored sibling of node i-1
        # whose next step commutes with it.
        let prev = s.decisions[i - 1].chosen
        s.decisions[i - 1].fp = s.stepFp
        var cands = s.sleepAt[i - 1]
        if i - 1 < s.doneIn.len: cands.add s.doneIn[i - 1]
        for (u, f) in cands:
          if u != prev and independent(f, s.stepFp):
            var dup = false
            for (v, _) in sleep:
              if v == u: dup = true
            if not dup: sleep.add (u, f)
      s.sleepAt.add sleep
      for (u, _) in sleep: d.sleep.add u
      result = -1
      if i < s.forced.len:
        if s.forced[i] in d.options: result = s.forced[i]
        else: s.diverged = true
      if result == -1:
        for t in d.options:
          if t notin d.sleep:
            result = t
            break
        if result == -1:
          d.redundant = true
          result = d.options[0]
      d.chosen = result
      s.decisions.add d
      if s.reduce: s.stepFp = s.pendingAcc[result]
      return
  for t in 0 ..< s.n:
    if s.runnable(t) and (result == -1 or s.prio[t] > s.prio[result]): result = t
  if result == -1:
    # Nobody can run: either all done, or a real deadlock in the code under
    # test. In the second case, flag it and wake the highest-priority waiter
    # so the round ends; its acquire then proceeds without the lock.
    for t in 0 ..< s.n:
      if not s.done[t] and (result == -1 or s.prio[t] > s.prio[result]): result = t
    if result != -1:
      s.deadlocked = true
      if s.abortOnStuck:
        if not s.aborted:
          var who: seq[string]
          for t in 0 ..< s.n:
            if not s.done[t]:
              who.add "thread " & $t & (if s.condOf[t] != nil: " waits on a condition"
                                        else: " waits on a lock")
          s.aborted = true
          s.abortReason = "deadlock: every unfinished thread waits (" & who.join(", ") & ")"
        return -1
      s.waitingOn[result] = nil
      s.condOf[result] = nil    # a spurious wakeup, which `wait` allows

proc switchPoint(kind, file: cstring, line: int, obj: pointer = nil, write = true) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    let s = active()
    # Threads that did not call `enter` (the main thread in setup/teardown,
    # helpers) or already called `leave` are not scheduled: no switch.
    if s == nil or not tRegistered: return
    acquire s.lock
    if s.aborted:
      let why = s.abortReason
      release s.lock
      raise newException(RoundAborted, why)
    inc s.step
    if s.reduce: s.pendingAcc[tTid] = @[Access(obj: obj, write: write)]
    if s.stepLimit > 0 and s.step > s.stepLimit:
      s.aborted = true
      s.abortReason = "no end after " & $s.stepLimit & " switch points (livelock, or a " &
        "spin-wait that never sees its condition); raise RoundsConfig.stepLimit if the round is just long"
      broadcast s.cond
      let why = s.abortReason
      release s.lock
      raise newException(RoundAborted, why)
    if s.trace.len < traceCap:
      s.trace.add SwitchPoint(step: s.step, thread: tTid, kind: $kind, file: $file, line: line)
    else:
      inc s.traceDropped
    for i, c in s.changeAt:
      if c == s.step: s.prio[tTid] = s.changeAt.len - i   # below every initial priority
    s.current = s[].pickNext(tTid)
    broadcast s.cond
    while s.current != tTid and not s.aborted: wait(s.cond, s.lock)
    let ab = s.aborted
    let why = s.abortReason
    release s.lock
    if ab: raise newException(RoundAborted, why)

proc `=copy`*(dest: var Scheduler, src: Scheduler) {.error.}

proc traceSnapshot*(s: var Scheduler): seq[SwitchPoint] {.raises: [].} =
  ## A copy of the trace taken under the scheduler's lock, safe to call from
  ## another thread while the round runs (the round watchdog uses it).
  acquire s.lock
  result = s.trace
  release s.lock

proc abortReason*(s: Scheduler): string =
  ## P14: why the round was aborted, "" if it was not.
  s.abortReason

proc decisions*(s: Scheduler): seq[Decision] =
  ## Exploration mode: every scheduling decision of the round, in order.
  s.decisions

proc diverged*(s: Scheduler): bool =
  ## Exploration mode: a forced choice was not runnable, so the code under
  ## test did not behave the same under the same schedule (not deterministic).
  s.diverged

proc trace*(s: Scheduler): seq[SwitchPoint] =
  ## Switch points of the round so far, in order (P12). At most `traceCap`.
  s.trace

proc traceDropped*(s: Scheduler): int =
  ## Switch points not kept because the trace reached `traceCap`.
  s.traceDropped

proc stepsTaken*(s: Scheduler): int =
  ## Switch points that happened since `initScheduler` (each `perturb()`,
  ## `SchedLock` acquire and intercepted operation of a registered thread).
  ## Read it before `deinitScheduler` to size `steps` for the next rounds.
  s.step

proc initScheduler*(s: var Scheduler, threads: Positive, seed: int, depth = 3,
                    steps = 100, explore = false, forced: seq[int] = @[],
                    abortOnStuck = false, stepLimit = 0,
                    reduce = false, doneIn: seq[seq[(int, Footprint)]] = @[]) =
  ## Prepares a round for `threads` threads and installs the scheduler. `depth`
  ## is PCT's bug depth (number of priority changes + 1); `steps` estimates the
  ## number of scheduling points in the round, where change points are drawn.
  ## Raises `ValueError` if another scheduler is still installed (call
  ## `deinitScheduler` first): only one can be active at a time.
  ##
  ## `explore = true` (D-32): instead of PCT, decision `i` runs `forced[i]`;
  ## past the end of `forced`, the current thread goes on when it can, else
  ## the runnable thread with the lowest index. `decisions` records every
  ## choice, so an explorer can enumerate schedules by changing `forced`.
  ##
  ## `abortOnStuck = true` (P14): when every unfinished thread waits, or past
  ## `stepLimit` switch points (0: no limit), the round is aborted: each
  ## registered thread raises `RoundAborted` at its next switch point, and
  ## `abortReason` says why. Without it, a deadlock sets `deadlocked` and wakes
  ## a waiter spuriously, as before.
  var none: pointer = nil
  if not gSched.compareExchange(none, cast[pointer](addr s), moSequentiallyConsistent):
    raise newException(ValueError, "nimlinear/schedule: another Scheduler is active; " &
      "call deinitScheduler on it first")
  initLock s.lock
  initCond s.cond
  s.n = threads
  s.arrived = 0
  s.current = -1
  s.step = 0
  s.done = newSeq[bool](threads)
  s.waitingOn = newSeq[ptr SchedLock](threads)
  s.condOf = newSeq[ptr SchedCond](threads)
  s.deadlocked = false
  s.trace = @[]
  s.traceDropped = 0
  s.explore = explore
  s.forced = forced
  s.decisions = @[]
  s.diverged = false
  s.reduce = explore and reduce
  s.doneIn = doneIn
  s.sleepAt = @[]
  s.stepFp = @[]
  s.pendingAcc = newSeq[Footprint](threads)
  for t in 0 ..< threads: s.pendingAcc[t] = @[Access(obj: nil, write: true)]   # unknown until its first point
  s.abortOnStuck = abortOnStuck
  s.stepLimit = stepLimit
  s.aborted = false
  s.abortReason = ""
  var rng = initRand(seed + 1)
  var p = newSeq[int](threads)
  for t in 0 ..< threads: p[t] = depth + t
  rng.shuffle(p)
  s.prio = p
  s.changeAt = @[]
  for _ in 1 ..< depth: s.changeAt.add rng.rand(1 .. max(1, steps))
  setYieldHook(switchPoint)

proc deinitScheduler*(s: var Scheduler) =
  ## Removes the scheduler. Call after joining the threads.
  setYieldHook(nil)
  gSched.store(nil, moRelease)
  deinitCond s.cond
  deinitLock s.lock

proc enter*(s: var Scheduler, thread: int) {.raises: [].} =
  ## First call in each registered thread (`thread` in `0 ..< threads`).
  ## Blocks until every thread arrived and this one is scheduled.
  tTid = thread
  tRegistered = true
  acquire s.lock
  inc s.arrived
  if s.arrived == s.n:
    s.current = s.pickNext
    broadcast s.cond
  while s.current != thread and not s.aborted: wait(s.cond, s.lock)
  release s.lock

proc leave*(s: var Scheduler) {.raises: [].} =
  ## Last call in each registered thread: hands control to the next one.
  tRegistered = false
  acquire s.lock
  s.done[tTid] = true
  s.current = s.pickNext
  broadcast s.cond
  release s.lock

proc initSchedLock*(l: var SchedLock) =
  initLock l.lock
  l.held = false

proc deinitSchedLock*(l: var SchedLock) =
  deinitLock l.lock

proc acquireAt*(l: var SchedLock, file: cstring, line: int) {.raises: [].} =
  ## Internal: `acquire` with the caller's location for the trace.
  ## Under a scheduler: a switch point; if the lock is held, the thread waits
  ## (yielding) until it is released. Otherwise: an ordinary lock acquire.
  {.cast(gcsafe).}:
    let s = active()
    if s == nil or not tRegistered:
      # Unregistered thread under a scheduler: registered threads are parked
      # or run one at a time, so it takes the lock without waiting.
      if s == nil: acquire l.lock
      else: l.held = true
      return
    switchPoint("acquire", file, line, addr l, true)
    if l.held:
      acquire s.lock
      s.waitingOn[tTid] = addr l
      release s.lock
      switchPoint("acquire (blocked)", file, line, addr l, true)   # picked again only when `l` is free (or deadlock)
      acquire s.lock
      s.waitingOn[tTid] = nil
      release s.lock
    l.held = true

proc tryAcquireAt*(l: var SchedLock, file: cstring, line: int): bool {.raises: [].} =
  ## Internal: `tryAcquire` with the caller's location for the trace.
  ## Under a scheduler: a switch point, then takes the lock if it is free.
  ## Otherwise: an ordinary `tryAcquire`.
  {.cast(gcsafe).}:
    let s = active()
    if s == nil: return tryAcquire(l.lock)
    if tRegistered: switchPoint("tryAcquire", file, line, addr l, true)
    if l.held: return false
    l.held = true
    true

template acquire*(l: var SchedLock) =
  ## Under a scheduler: a switch point; if the lock is held, the thread waits
  ## (yielding) until it is released. Otherwise: an ordinary lock acquire.
  const ii = instantiationInfo(-1)
  acquireAt(l, ii.filename.cstring, ii.line)

template tryAcquire*(l: var SchedLock): bool =
  ## Under a scheduler: a switch point, then takes the lock if it is free.
  ## Otherwise: an ordinary `tryAcquire`.
  const ii = instantiationInfo(-1)
  tryAcquireAt(l, ii.filename.cstring, ii.line)

proc release*(l: var SchedLock) {.raises: [].} =
  {.cast(gcsafe).}:
    let s = active()
    if s == nil:
      release l.lock
    else:
      l.held = false
      if tRegistered:
        acquire s.lock
        s[].noteAccess(addr l, true)    # part of the running step (reduction)
        release s.lock

template withLock*(l: var SchedLock, body: untyped) =
  block:
    const ii = instantiationInfo(-1)   # the caller of withLock, for the trace
    acquireAt(l, ii.filename.cstring, ii.line)
  try:
    body
  finally:
    release(l)

proc initSchedCond*(c: var SchedCond) = initCond c.cond
proc deinitSchedCond*(c: var SchedCond) = deinitCond c.cond

proc waitAt*(c: var SchedCond, l: var SchedLock, file: cstring, line: int) {.raises: [].} =
  ## Internal: `wait` with the caller's location for the trace.
  ## Under a scheduler, from a registered thread: releases `l`, waits (yielding)
  ## until `signal` or `broadcast` picks this thread, then takes `l` again.
  ## From an unregistered thread under a scheduler it returns at once, as a
  ## spurious wakeup (callers re-check their condition in a loop, as with
  ## `Cond`). Without a scheduler: an ordinary `wait`.
  ##
  ## When every unfinished thread waits, the scheduler flags `deadlocked` and
  ## wakes the highest-priority one spuriously. A lost wakeup in the code
  ## under test then loops in its wait, as it would hang without the scheduler.
  {.cast(gcsafe).}:
    let s = active()
    if s == nil:
      wait(c.cond, l.lock)
      return
    if not tRegistered: return
    release(l)
    acquire s.lock
    s.condOf[tTid] = addr c
    release s.lock
    switchPoint("wait", file, line, nil, true)   # touches the lock and the condition: unknown   # picked again only when signalled (or deadlock)
    acquireAt(l, file, line)

template wait*(c: var SchedCond, l: var SchedLock) =
  ## Under a scheduler, from a registered thread: releases `l`, waits (yielding)
  ## until `signal` or `broadcast` picks this thread, then takes `l` again.
  ## See `waitAt` for the unregistered and deadlock cases.
  const ii = instantiationInfo(-1)
  waitAt(c, l, ii.filename.cstring, ii.line)

proc wake(c: var SchedCond, all: bool) {.raises: [].} =
  {.cast(gcsafe).}:
    let s = active()
    if s == nil:
      if all: broadcast(c.cond) else: signal(c.cond)
      return
    acquire s.lock
    if tRegistered: s[].noteAccess(addr c, true)
    for t in 0 ..< s.n:      # lowest thread index first: deterministic
      if s.condOf[t] == addr c:
        s.condOf[t] = nil
        if not all: break
    release s.lock

proc signal*(c: var SchedCond) {.raises: [].} =
  ## Wakes one waiting thread (the lowest thread index under a scheduler).
  ## Not a switch point.
  wake(c, false)

proc broadcast*(c: var SchedCond) {.raises: [].} =
  ## Wakes every waiting thread. Not a switch point.
  wake(c, true)
