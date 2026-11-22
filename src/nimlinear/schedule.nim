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
## - between `enter` and `leave`, a thread must not block waiting for another
##   registered thread: no `perturb()` while holding a lock others may take,
##   no joins, no blocking channel reads;
## - one scheduler active at a time.

when not compileOption("threads"):
  {.error: "nimlinear/schedule requires --threads:on".}
when not defined(nimlinearPerturb):
  {.error: "nimlinear/schedule requires -d:nimlinearPerturb".}

import std/[locks, random]
import ./perturb

type
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

var gSched: ptr Scheduler
var tTid {.threadvar.}: int

proc pickNext(s: var Scheduler): int =
  result = -1
  for t in 0 ..< s.n:
    if not s.done[t] and (result == -1 or s.prio[t] > s.prio[result]): result = t

proc switchPoint() {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}:
    let s = gSched
    if s == nil: return
    acquire s.lock
    inc s.step
    for i, c in s.changeAt:
      if c == s.step: s.prio[tTid] = s.changeAt.len - i   # below every initial priority
    s.current = s[].pickNext
    broadcast s.cond
    while s.current != tTid: wait(s.cond, s.lock)
    release s.lock

proc `=copy`*(dest: var Scheduler, src: Scheduler) {.error.}

proc initScheduler*(s: var Scheduler, threads: Positive, seed: int, depth = 3,
                    steps = 100) =
  ## Prepares a round for `threads` threads and installs the scheduler. `depth`
  ## is PCT's bug depth (number of priority changes + 1); `steps` estimates the
  ## number of scheduling points in the round, where change points are drawn.
  initLock s.lock
  initCond s.cond
  s.n = threads
  s.arrived = 0
  s.current = -1
  s.step = 0
  s.done = newSeq[bool](threads)
  var rng = initRand(seed + 1)
  var p = newSeq[int](threads)
  for t in 0 ..< threads: p[t] = depth + t
  rng.shuffle(p)
  s.prio = p
  s.changeAt = @[]
  for _ in 1 ..< depth: s.changeAt.add rng.rand(1 .. max(1, steps))
  gSched = addr s
  setYieldHook(switchPoint)

proc deinitScheduler*(s: var Scheduler) =
  ## Removes the scheduler. Call after joining the threads.
  setYieldHook(nil)
  gSched = nil
  deinitCond s.cond
  deinitLock s.lock

proc enter*(s: var Scheduler, thread: int) {.raises: [].} =
  ## First call in each registered thread (`thread` in `0 ..< threads`).
  ## Blocks until every thread arrived and this one is scheduled.
  tTid = thread
  acquire s.lock
  inc s.arrived
  if s.arrived == s.n:
    s.current = s.pickNext
    broadcast s.cond
  while s.current != thread: wait(s.cond, s.lock)
  release s.lock

proc leave*(s: var Scheduler) {.raises: [].} =
  ## Last call in each registered thread: hands control to the next one.
  acquire s.lock
  s.done[tTid] = true
  s.current = s.pickNext
  broadcast s.cond
  release s.lock
