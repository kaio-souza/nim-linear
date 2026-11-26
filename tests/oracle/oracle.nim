## Brute-force oracle and random history generator for M6.
## See CONTRIBUTING.md#brute-force-oracle-m6.
##
## The oracle is a plain Wing & Gong DFS with no memoization. The generator
## simulates 1..3 threads with a random scheduler: at each step it picks a
## thread and advances it (invoke, linearization point, or return). Results
## come from the model applied at the linearization point, so the history is
## linearizable; with 50% chance one completed result is then swapped for
## another possible value. Each operation has a 10% chance of never returning.

import std/random
import nimlinear

type
  Spec*[Op, Res] = object
    call*: Op
    res*: Res
    inv*, ret*: int
    pending*: bool
    tick*: bool      ## instantaneous (M10): inv == ret, result not compared

proc oracleLinearizable*[S, Op, Res](ops: seq[Spec[Op, Res]], init: S,
                                     model: typedesc): bool =
  mixin step, outcomes, `==`
  let n = ops.len
  var used = newSeq[bool](n)
  var completed = 0
  for o in ops:
    if not o.pending: inc completed

  proc dfs(state: S, left: int): bool =
    if left == 0: return true
    var minRet = high(int)
    for i in 0 ..< n:
      if not used[i] and not ops[i].pending and ops[i].ret < minRet: minRet = ops[i].ret
    for i in 0 ..< n:
      if used[i] or ops[i].inv > minRet: continue
      when hasOutcomes(model, S, Op):
        let outs = outcomes(model, state, ops[i].call)
      else:
        let outs = @[step(model, state, ops[i].call)]
      for e in outs:
        if not ops[i].pending and not ops[i].tick and not (e.res == ops[i].res): continue
        used[i] = true
        if dfs(e.next, if ops[i].pending: left else: left - 1): return true
        used[i] = false
    false

  dfs(init, completed)

proc generate*[S, Op, Res](rng: var Rand, init: S, model: typedesc,
                           genOp: proc (r: var Rand): Op,
                           otherRes: proc (r: var Rand, res: Res): Res,
                           maxTicks = 0, tickCall = default(Op)):
                           tuple[h: History[Op, Res], ops: seq[Spec[Op, Res]]] =
  mixin step, outcomes
  template apply(st: S, call: Op): untyped =
    when hasOutcomes(model, S, Op):
      (let outs = outcomes(model, st, call); outs[rng.rand(outs.len - 1)])
    else:
      step(model, st, call)
  let threads = rng.rand(1..3)
  let total = rng.rand(1..8)
  var queue = newSeq[seq[int]](threads)        # op indices per thread
  var ops: seq[Spec[Op, Res]]
  for i in 0 ..< total:
    ops.add Spec[Op, Res](call: genOp(rng), pending: rng.rand(99) < 10)
    queue[rng.rand(threads - 1)].add i

  type Phase = enum idle, invoked, linearized, stopped
  var phase = newSeq[Phase](threads)
  var cur = newSeq[int](threads)
  var state = init
  var evs: seq[Event[Op, Res]]
  var s = 0
  var ticksLeft = if maxTicks > 0: rng.rand(0..maxTicks) else: 0
  while true:
    var ready: seq[int]
    for t in 0 ..< threads:
      if phase[t] != stopped and (phase[t] != idle or queue[t].len > 0): ready.add t
    if ticksLeft > 0: ready.add -1             # the clock, an extra "thread"
    if ready.len == 0: break
    let t = ready[rng.rand(ready.len - 1)]
    if t == -1:
      dec ticksLeft; inc s
      state = apply(state, tickCall).next
      ops.add Spec[Op, Res](call: tickCall, tick: true, inv: s, ret: s)
      evs.add tickEvent[Op, Res](ops.len, threads, s, tickCall)
      continue
    case phase[t]
    of idle:
      cur[t] = queue[t][0]; queue[t].delete(0)
      inc s; ops[cur[t]].inv = s
      evs.add invokeEvent[Op, Res](cur[t] + 1, t, s, ops[cur[t]].call)
      phase[t] = invoked
    of invoked:
      if ops[cur[t]].pending and rng.rand(1) == 0:
        phase[t] = stopped                     # pending, never takes effect
        continue
      let e = apply(state, ops[cur[t]].call)
      state = e.next; ops[cur[t]].res = e.res
      phase[t] = linearized
    of linearized:
      if ops[cur[t]].pending:
        phase[t] = stopped                     # never returns; thread blocked
      else:
        inc s; ops[cur[t]].ret = s
        evs.add returnEvent[Op, Res](cur[t] + 1, t, s, ops[cur[t]].res)
        phase[t] = idle
    of stopped: discard
  # A pending op that was never reached is dropped (no invoke recorded).
  var kept: seq[Spec[Op, Res]]
  for o in ops:
    if o.inv > 0: kept.add o

  if rng.rand(1) == 1:
    var done: seq[int]
    for i, o in kept:
      if not o.pending and not o.tick: done.add i
    if done.len > 0:
      let j = done[rng.rand(done.len - 1)]
      let bad = otherRes(rng, kept[j].res)
      kept[j].res = bad
      for e in evs.mitems:
        if e.kind == ekReturn and e.seqNo == SeqNo(kept[j].ret): e.res = bad
  (newHistory(evs), kept)
