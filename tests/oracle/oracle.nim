## Brute-force oracle and random history generator for M6.
## See CONTRIBUTING.md#brute-force-oracle-m6.
##
## The oracle is a plain Wing & Gong DFS with no memoization. The generator
## simulates 1..3 threads with a random scheduler: at each step it picks a
## thread and advances it (invoke, linearization point, or return). Results
## come from the model applied at the linearization point, so the history is
## linearizable; with 50% chance one completed result is then swapped for
## another possible value. Each operation has a 10% chance of never returning.

import std/[random, sets, tables]
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

# --- P8: checks of the verdict's content, not only its kind -----------------

proc validPrefix*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                              order: seq[OpId], complete: bool): string =
  ## "" if `order` is a valid linearization prefix of `h`: each operation at
  ## most once, real time respected (every completed operation that returned
  ## before another was invoked comes first), and some choice of outcomes
  ## gives every completed, non-tick operation its observed result. With
  ## `complete`, every completed operation (and tick) must be in it.
  ## Otherwise the reason.
  mixin step, outcomes, `==`
  type Info = object
    inv, ret: int
    pending, tick: bool
    call: Op
    res: Res
  var info = initTable[OpId, Info]()
  for e in h.events:
    case e.kind
    of ekInvoke: info[e.op] = Info(inv: int(e.seqNo), ret: high(int), pending: true, call: e.call)
    of ekTick: info[e.op] = Info(inv: int(e.seqNo), ret: int(e.seqNo), tick: true, call: e.call)
    of ekReturn:
      info[e.op].ret = int(e.seqNo); info[e.op].pending = false; info[e.op].res = e.res
  var placed = initHashSet[OpId]()
  for id in order:
    if id notin info: return "unknown op " & $id
    if id in placed: return "op " & $id & " twice"
    for other, x in tables.pairs(info):
      if other != id and other notin placed and not x.pending and x.ret < info[id].inv:
        return "op " & $id & " placed before op " & $other & ", which returned before it was invoked"
    placed.incl id
  if complete:
    for id, x in tables.pairs(info):
      if not x.pending and id notin placed: return "completed op " & $id & " missing"
  # Results: search over the outcome choices along the fixed order.
  proc fits(i: int, st: S): bool =
    if i == order.len: return true
    let x = info[order[i]]
    when hasOutcomes(model, S, Op):
      let outs = outcomes(model, st, x.call)
    else:
      let outs = @[step(model, st, x.call)]
    for e in outs:
      if x.pending or x.tick or e.res == x.res:
        if fits(i + 1, e.next): return true
    false
  if not fits(0, init): return "results do not match the model along the order"
  ""

proc verdictContentError*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                                      v: Verdict[Op, Res]): string =
  ## "" if the content of `v` is consistent with `h`; otherwise the reason.
  case v.kind
  of vkLinearizable:
    validPrefix(h, init, model, v.order, complete = true)
  of vkNotLinearizable:
    let w = v.witness
    let p = validPrefix(h, init, model, w.prefix, complete = false)
    if p.len > 0: return "witness prefix: " & p
    if w.alternatives.len > 0:
      if w.stuck in w.prefix: return "stuck op " & $w.stuck & " is in the prefix"
      var found = false
      for a in w.alternatives:
        if a.candidate == w.stuck: found = true
      if not found: return "stuck op " & $w.stuck & " is not among the alternatives"
    ""
  of vkInconclusive: ""

proc sameVerdict*[Op, Res](a, b: Verdict[Op, Res]): bool =
  ## Field-by-field equality (D-20 determinism).
  mixin `==`
  if a.kind != b.kind: return false
  case a.kind
  of vkLinearizable: a.order == b.order
  of vkNotLinearizable:
    let x = a.witness
    let y = b.witness
    if x.prefix != y.prefix or x.stuck != y.stuck or x.stuckEverFit != y.stuckEverFit or
       not (x.stuckCall == y.stuckCall) or not (x.stuckRes == y.stuckRes) or
       x.alternatives.len != y.alternatives.len: return false
    for i in 0 ..< x.alternatives.len:
      let p = x.alternatives[i]
      let q = y.alternatives[i]
      if p.candidate != q.candidate or not (p.expected == q.expected) or
         not (p.observed == q.observed) or p.why != q.why: return false
    true
  of vkInconclusive: a.statesExplored == b.statesExplored and a.timedOut == b.timedOut
