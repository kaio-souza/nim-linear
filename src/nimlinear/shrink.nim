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

import std/[algorithm, sets]
import ./[history, checker]

type Signature[Res] = object
  fails: bool
  stuck: OpId
  expected: Res     # what the model expected from the stuck operation

proc `==`[Res](a, b: Signature[Res]): bool =
  mixin `==`
  a.fails == b.fails and a.stuck == b.stuck and a.expected == b.expected

proc stuckOf[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                         budget: int, partitioned: bool): Signature[Res] =
  var v: Verdict[Op, Res]
  when compiles(checkPartitioned(h, init, model, budget)):
    if partitioned: v = checkPartitioned(h, init, model, budget)
    else: v = checkLinearizable(h, init, model, budget)
  else:
    v = checkLinearizable(h, init, model, budget)
  if v.kind == vkNotLinearizable:
    result = Signature[Res](fails: true, stuck: v.witness.stuck)
    for a in v.witness.alternatives:
      if a.candidate == v.witness.stuck:
        result.expected = a.expected
        break

proc without[Op, Res](h: History[Op, Res], drop: HashSet[OpId]): History[Op, Res] =
  var keep = initHashSet[OpId]()
  for e in h.events:
    if e.op notin drop: keep.incl e.op
  h.subHistory(keep)

proc shrink*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                         budget = 1_000_000, partitioned = false): History[Op, Res] {.raises: [].} =
  ## Returns a history with as few operations as this greedy search finds
  ## that is still `vkNotLinearizable` (with `checkPartitioned` when
  ## `partitioned`). If `h` is not `vkNotLinearizable`, returns `h` unchanged.
  ## The same input always gives the same output.
  var evs = h
  let sig = stuckOf(evs, init, model, budget, partitioned)
  if not sig.fails: return h
  let stuck = sig.stuck
  template keeps(cand: History[Op, Res]): bool =
    cand.events.len < evs.events.len and stuckOf(cand, init, model, budget, partitioned) == sig

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
      if id == stuck: continue
      var drop = initHashSet[OpId]()
      drop.incl id
      let cand = evs.without(drop)
      if keeps(cand):
        evs = cand
        progress = true
  evs
