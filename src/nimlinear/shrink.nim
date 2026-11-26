## Minimization of failing histories (M16).
##
## Greedy and deterministic: first tries to drop whole threads (in increasing
## thread id), then single operations (in increasing invoke `seq`). A removal
## is kept only if the history is still `vkNotLinearizable`, **stuck on the
## same operation, with the same expected result for it** as the original
## witness; the stuck operation is never removed. Repeats until no removal is kept.
##
## Why the "same stuck operation" guard: removing an operation can create a
## failure that was not in the original (drop the only `write(1)` and a
## `read() -> 1` becomes unexplainable). Requiring the same stuck operation
## and the same expected result for it rejects most of those removals. It is a heuristic, not a proof: always confirm the
## shrunk history against the original report.
##
## Removing an operation removes all of its events, so every intermediate
## history is valid. An inconclusive check counts as "not failing".

import std/[algorithm, monotimes, sets, times]
import ./[history, checker]

type Signature[Res] = object
  fails: bool
  stuck: OpId
  expected: Res     # what the model expected from the stuck operation

proc `==`[Res](a, b: Signature[Res]): bool =
  mixin `==`
  a.fails == b.fails and a.stuck == b.stuck and a.expected == b.expected

proc stuckOf[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                         budget: int, partitioned: bool, timeout: Duration): Signature[Res] =
  var v: Verdict[Op, Res]
  when compiles(checkPartitioned(h, init, model, budget, timeout)):
    if partitioned: v = checkPartitioned(h, init, model, budget, timeout)
    else: v = checkLinearizable(h, init, model, budget, timeout)
  else:
    v = checkLinearizable(h, init, model, budget, timeout)
  if v.kind == vkNotLinearizable:
    result = Signature[Res](fails: true, stuck: v.witness.stuck)
    for a in v.witness.alternatives:
      if a.candidate == v.witness.stuck:
        result.expected = a.expected
        break

type Deadline = object
  use: bool
  at: MonoTime

# Non-generic, so Duration/MonoTime operators resolve here, not at the caller.
proc initDeadline(timeout: Duration): Deadline =
  Deadline(use: timeout > DurationZero, at: getMonoTime() + timeout)

proc expired(d: Deadline): bool = d.use and getMonoTime() >= d.at

proc left(d: Deadline): Duration =
  ## What is left for one check; zero = no limit. Never zero when limited.
  if not d.use: return DurationZero
  max(d.at - getMonoTime(), initDuration(nanoseconds = 1))

proc without[Op, Res](h: History[Op, Res], drop: HashSet[OpId]): History[Op, Res] =
  var keep = initHashSet[OpId]()
  for e in h.events:
    if e.op notin drop: keep.incl e.op
  h.subHistory(keep)

proc shrink*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                         budget = 1_000_000, partitioned = false,
                         timeout = DurationZero): History[Op, Res] {.raises: [].} =
  ## Returns a history with as few operations as this greedy search finds
  ## that is still `vkNotLinearizable` (with `checkPartitioned` when
  ## `partitioned`). If `h` is not `vkNotLinearizable`, returns `h` unchanged.
  ## The same input always gives the same output, unless `timeout` stops it.
  ##
  ## Cost: up to O(n²) checks for n operations, each with the full `budget`.
  ## `timeout` (zero = none) bounds the whole call: when it runs out, the
  ## smallest history found so far is returned (still failing the same way).
  ## Each check gets what is left of it, so a check cut short counts as
  ## "not failing" and its removal is not kept.
  let dl = initDeadline(timeout)
  var evs = h
  let sig = stuckOf(evs, init, model, budget, partitioned, dl.left())
  if not sig.fails: return h
  let stuck = sig.stuck
  template keeps(cand: History[Op, Res]): bool =
    cand.events.len < evs.events.len and stuckOf(cand, init, model, budget, partitioned, dl.left()) == sig

  var progress = true
  while progress:
    progress = false
    # Whole threads first: cheap big steps.
    var threads: seq[int]
    for e in evs.events:
      if e.kind != ekTick and int(e.thread) notin threads: threads.add int(e.thread)
    threads.sort()
    if threads.len > 1:
      for t in threads:
        var drop = initHashSet[OpId]()
        for e in evs.events:
          if e.kind != ekTick and int(e.thread) == t: drop.incl e.op
        if dl.expired(): return evs
        if stuck in drop: continue
        let cand = evs.without(drop)
        if keeps(cand):
          evs = cand
          progress = true
    # Then single operations, in increasing invoke seq.
    var opsOrder: seq[OpId]
    for e in evs.events:
      if e.kind != ekReturn: opsOrder.add e.op
    for id in opsOrder:
      if dl.expired(): return evs
      if id == stuck: continue
      var drop = initHashSet[OpId]()
      drop.incl id
      let cand = evs.without(drop)
      if keeps(cand):
        evs = cand
        progress = true
  evs
