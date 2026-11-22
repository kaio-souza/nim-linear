## Linearizability checker (M2–M4, M10, M11, M14, M20–M22): graph search
## memoizing (linearized, state) configurations, D-11. Deterministic (D-20).
##
## Internals (M22): operations are indexed in increasing invoke `seq`. The
## linearized set is kept as a global bitset for tests, and as the canonical
## key `(f, window)` for memoization: every index below `f` is linearized,
## index `f` is not, and bit `j` of `window` says whether index `f + 1 + j` is.
## With bounded overlap the window stays a word or two, so each step costs
## O(overlap), not O(n).

import std/[algorithm, hashes, monotimes, sets, tables, times]
import ./history

type
  VerdictKind* = enum vkLinearizable, vkNotLinearizable, vkInconclusive

  Alternative*[Res] = object
    candidate*: OpId     ## operation tried as the next linearization point
    expected*: Res       ## result the model expected (first outcome, M14)
    observed*: Res       ## result recorded in the history
    why*: string         ## reason from the model

  Witness*[Op, Res] = object
    prefix*: seq[OpId]                    ## longest linearized prefix found
    stuck*: OpId                          ## first operation that does not fit
    stuckCall*: Op
    stuckRes*: Res
    alternatives*: seq[Alternative[Res]]  ## candidates tried at the failure point

  Verdict*[Op, Res] = object
    case kind*: VerdictKind
    of vkLinearizable:
      order*: seq[OpId]
    of vkNotLinearizable:
      witness*: Witness[Op, Res]
    of vkInconclusive:
      statesExplored*: int
      budget*: int
      timedOut*: bool    ## true: stopped by `timeout` (M20), not by `budget`

  OpInfo[Op, Res] = object
    id: OpId
    invSeq, retSeq: int    # internal times; retSeq = high(int) for a pending op
    pending: bool
    tick: bool             # instantaneous (M10): result not compared
    call: Op
    res: Res

  Config[S] = object
    f: int
    window: seq[uint64]
    state: S

  Frame[S, Res] = object
    state: S
    f: int                 # every index < f is linearized
    window: seq[uint64]    # bit j: index f + 1 + j linearized; no trailing zero words
    minRet: int            # lowest retSeq among completed, unlinearized ops
    minRetPos: int         # position of that op in `byRet`
    cand: int              # next candidate index to try
    cur: int               # candidate whose outcomes are being tried (-1: none)
    nexts: seq[S]          # next states still to try for `cur`
    alts: seq[Alternative[Res]]

proc hash[S](c: Config[S]): Hash =
  mixin hash
  var h: Hash = hash(c.f)
  for w in c.window: h = h !& hash(w)
  h = h !& hash(c.state)
  !$h

proc `==`[S](a, b: Config[S]): bool =
  mixin `==`
  a.f == b.f and a.window == b.window and a.state == b.state

template isSet(bits: seq[uint64], i: int): bool = (bits[i shr 6] and (1'u64 shl (i and 63))) != 0
template setBit(bits: var seq[uint64], i: int) = bits[i shr 6] = bits[i shr 6] or (1'u64 shl (i and 63))
template clearBit(bits: var seq[uint64], i: int) = bits[i shr 6] = bits[i shr 6] and not (1'u64 shl (i and 63))

proc childKey(f: var int, window: var seq[uint64], i: int) =
  ## Adds index `i` (not yet linearized, `i >= f`) to the key `(f, window)`.
  if i > f:
    let b = i - f - 1
    while window.len <= b shr 6: window.add 0'u64
    window[b shr 6] = window[b shr 6] or (1'u64 shl (b and 63))
    return
  # i == f: the new first unlinearized index skips the run of ones at bit 0.
  var t = 0
  while t shr 6 < window.len and (window[t shr 6] and (1'u64 shl (t and 63))) != 0: inc t
  f += t + 1
  let sh = t + 1                   # drop the run and the zero bit after it
  let words = sh shr 6
  let bitsSh = sh and 63
  var res = newSeq[uint64](max(0, window.len - words))
  for k in 0 ..< res.len:
    var w = window[k + words] shr bitsSh
    if bitsSh != 0 and k + words + 1 < window.len:
      w = w or (window[k + words + 1] shl (64 - bitsSh))
    res[k] = w
  while res.len > 0 and res[^1] == 0: res.setLen res.len - 1
  window = res

template hasOutcomes*(model: typedesc, S, Op: typedesc): bool {.dirty.} =
  ## True when the model defines the nondeterministic contract (M14).
  compiles(outcomes(model, default(S), default(Op)))

proc checkCore[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                           budget: int, deadline: MonoTime, useDeadline: bool,
                           explored: var int, timedOut: var bool): Verdict[Op, Res] {.raises: [].} =
  mixin step, outcomes, `==`, hash
  timedOut = false
  let budget = max(budget, 1)    # the initial configuration always counts

  # Internal times are 2*seq; a tick occupies [2*seq, 2*seq + 1], so it is a
  # candidate exactly when nothing that returned earlier is still unlinearized.
  var ops: seq[OpInfo[Op, Res]]
  var indexOf = initTable[OpId, int]()
  for e in h.events:
    case e.kind
    of ekInvoke:
      indexOf[e.op] = ops.len
      ops.add OpInfo[Op, Res](id: e.op, invSeq: 2 * int(e.seqNo), retSeq: high(int),
                              pending: true, call: e.call)
    of ekTick:
      indexOf[e.op] = ops.len
      ops.add OpInfo[Op, Res](id: e.op, invSeq: 2 * int(e.seqNo), retSeq: 2 * int(e.seqNo) + 1,
                              tick: true, call: e.call)
    of ekReturn:
      let i = indexOf.getOrDefault(e.op, -1)
      if i >= 0:
        ops[i].retSeq = 2 * int(e.seqNo); ops[i].pending = false; ops[i].res = e.res
  let n = ops.len

  # Completed ops (and ticks) in increasing retSeq, for an incremental minRet.
  var byRet: seq[int]
  for i in 0 ..< n:
    if not ops[i].pending: byRet.add i
  byRet.sort(proc (a, b: int): int = cmp(ops[a].retSeq, ops[b].retSeq))

  var bits = newSeq[uint64]((n + 63) div 64)
  var completedLeft = byRet.len

  proc nextMin(bits: seq[uint64], fromPos: int): (int, int) =
    var p = fromPos
    while p < byRet.len and bits.isSet(byRet[p]): inc p
    if p < byRet.len: (ops[byRet[p]].retSeq, p) else: (high(int), p)

  var visited = initHashSet[Config[S]]()
  visited.incl Config[S](f: 0, state: init)
  explored = 1
  var path: seq[int]
  var stack: seq[Frame[S, Res]]
  var depth = 0                 # frames in use; stack keeps capacity (reused)
  template pushFrame(st: S, ff: int, ex: seq[uint64], mr, mrp: int) =
    if depth == stack.len: stack.add Frame[S, Res]()
    stack[depth].state = st
    stack[depth].f = ff
    stack[depth].window = ex
    stack[depth].minRet = mr
    stack[depth].minRetPos = mrp
    stack[depth].cand = ff
    stack[depth].cur = -1
    stack[depth].nexts.setLen 0
    stack[depth].alts.setLen 0
    inc depth
  block:
    let (mr, mrp) = nextMin(bits, 0)
    pushFrame(init, 0, @[], mr, mrp)
  var bestLen = -1
  var best: Witness[Op, Res]

  when defined(nimlinearMeasure):
    let baseMem = getOccupiedMem()
    var peakMem = baseMem
    template sampleMem() =
      if (explored and 1023) == 0:
        let m = getOccupiedMem()
        if m > peakMem: peakMem = m
    template report() =
      debugEcho "nimlinearMeasure peakDelta=", max(peakMem, getOccupiedMem()) - baseMem, " explored=", explored
  else:
    template report() = discard

  while true:
    if completedLeft == 0:
      report()
      var order: seq[OpId]
      for i in path: order.add ops[i].id
      return Verdict[Op, Res](kind: vkLinearizable, order: order)
    if depth == 0: break

    let top = depth - 1
    # Pick the next state to try: from the current candidate's outcomes, or
    # from the next candidate.
    if stack[top].nexts.len == 0:
      var i = stack[top].cand
      while i < n and bits.isSet(i) and ops[i].invSeq < stack[top].minRet: inc i
      if i >= n or ops[i].invSeq >= stack[top].minRet:
        # No candidates left: this configuration fails.
        if path.len > bestLen:
          bestLen = path.len
          best.prefix.setLen 0
          for j in path: best.prefix.add ops[j].id
          best.alternatives = stack[top].alts
          # Reset first: a stale stuck from a shallower failure must not leak.
          best.stuck = OpId(0); best.stuckCall = default(Op); best.stuckRes = default(Res)
          if best.alternatives.len > 0:
            let s = indexOf.getOrDefault(best.alternatives[0].candidate, -1)
            if s >= 0:
              best.stuck = ops[s].id; best.stuckCall = ops[s].call; best.stuckRes = ops[s].res
        dec depth
        if path.len > 0:
          let j = path.pop
          bits.clearBit(j)
          if not ops[j].pending: inc completedLeft
        continue
      stack[top].cand = i + 1
      stack[top].cur = i
      let check = not ops[i].pending and not ops[i].tick
      when hasOutcomes(model, S, Op):
        let outs = outcomes(model, stack[top].state, ops[i].call)
        for e in outs:
          if not check or e.res == ops[i].res: stack[top].nexts.add e.next
        if stack[top].nexts.len == 0:
          # A pending op with no outcome simply was not applied: not a
          # failure, so never an alternative (and never stuck).
          if ops[i].pending: continue
          var alt = Alternative[Res](candidate: ops[i].id, observed: ops[i].res)
          if outs.len > 0:
            alt.expected = outs[0].res; alt.why = outs[0].why
          else:
            alt.why = "no outcome"
          stack[top].alts.add alt
          continue
      else:
        when not compiles(step(model, stack[top].state, ops[i].call)):
          {.error: "the model needs `step` or `outcomes` (docs/MODELS.md#contract); " &
                   "if it defines `outcomes`, that definition does not compile".}
        let e = step(model, stack[top].state, ops[i].call)
        if check and not (e.res == ops[i].res):
          stack[top].alts.add Alternative[Res](candidate: ops[i].id, expected: e.res,
                                               observed: ops[i].res, why: e.why)
          continue
        stack[top].nexts.add e.next
      # Outcomes are tried in the model's order (D-20); pop from the back.
      stack[top].nexts.reverse()

    let i = stack[top].cur
    let next = stack[top].nexts.pop()

    # Child key after linearizing i.
    var f = stack[top].f
    var window = stack[top].window
    childKey(f, window, i)

    let cfg = Config[S](f: f, window: window, state: next)
    if cfg in visited:
      continue
    if explored >= budget:
      report()
      return Verdict[Op, Res](kind: vkInconclusive, statesExplored: explored, budget: budget)
    if useDeadline and (explored and 255) == 0 and not (getMonoTime() < deadline):
      report()
      timedOut = true
      return Verdict[Op, Res](kind: vkInconclusive, statesExplored: explored, budget: budget,
                              timedOut: true)
    visited.incl cfg
    inc explored
    when defined(nimlinearMeasure):
      sampleMem()
    bits.setBit(i)
    path.add i
    var mr = stack[top].minRet
    var mrp = stack[top].minRetPos
    if not ops[i].pending:
      dec completedLeft
      if ops[i].retSeq == mr:
        (mr, mrp) = nextMin(bits, mrp)
    pushFrame(next, f, window, mr, mrp)

  report()
  Verdict[Op, Res](kind: vkNotLinearizable, witness: best)

proc deadlineOf(timeout: Duration): (MonoTime, bool) =
  if timeout > DurationZero: (getMonoTime() + timeout, true) else: (MonoTime(), false)

proc checkLinearizable*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                                    budget = 1_000_000,
                                    timeout = DurationZero): Verdict[Op, Res] {.raises: [].} =
  ## Looks for a sequential order that respects real time and in which the
  ## model produces the observed results. See docs/API.md#checklinearizable.
  ## `budget` below 1 is treated as 1. `timeout` (M20): zero means none;
  ## checked every 256 visited states, so it can be exceeded by up to 256
  ## steps; when reached, `vkInconclusive` with `timedOut = true`. A timeout
  ## makes the verdict depend on the machine.
  var explored = 0
  var timedOut = false
  let (deadline, use) = deadlineOf(timeout)
  checkCore(h, init, model, budget, deadline, use, explored, timedOut)

proc checkPartitioned*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                                   budget = 1_000_000,
                                   timeout = DurationZero): Verdict[Op, Res] {.raises: [].} =
  ## Splits the history by `partition(model, op)` and checks each part, in
  ## increasing key order (D-12, D-20). The key may be any type with `hash`,
  ## `==` and `<` (M21). Ticks (M10) go into every part. `budget` applies per
  ## part; `timeout` to the whole call. See docs/API.md#checkpartitioned.
  mixin partition, `<`, `==`, hash
  type K = typeof(partition(model, default(Op)))
  var parts = initTable[K, HashSet[OpId]]()
  var ticks = initHashSet[OpId]()
  var invSeq = initTable[OpId, int]()
  for e in h.events:
    case e.kind
    of ekInvoke:
      invSeq[e.op] = int(e.seqNo)
      parts.mgetOrPut(partition(model, e.call), initHashSet[OpId]()).incl e.op
    of ekTick:
      invSeq[e.op] = int(e.seqNo)
      ticks.incl e.op
    of ekReturn: discard
  var keys: seq[K]
  for k in parts.keys: keys.add k
  keys.sort(proc (a, b: K): int = (if a < b: -1 elif b < a: 1 else: 0))
  if keys.len == 0 and ticks.len > 0:
    return checkLinearizable(h, init, model, budget, timeout)

  when defined(nimlinearVerifyPartition):
    # Safety net for new models: the partitioned verdict must agree with the
    # unpartitioned one. Expensive; for small histories while validating a
    # `partition` (D-12). A disagreement means the partition is not valid.
    template verified(v: Verdict[Op, Res]): Verdict[Op, Res] =
      # Same deadline as the partitioned check (what is left of `timeout`),
      # so the cross-check does not double the time limit.
      var wn = 0
      var wt = false
      let whole = checkCore(h, init, model, budget, deadline, use, wn, wt)
      if v.kind != vkInconclusive and whole.kind != vkInconclusive and v.kind != whole.kind:
        raiseAssert "nimlinearVerifyPartition: checkPartitioned says " & $v.kind &
                    " but checkLinearizable says " & $whole.kind &
                    "; the model's `partition` is not valid for this history (D-12)"
      v
  else:
    template verified(v: Verdict[Op, Res]): Verdict[Op, Res] = v

  let (deadline, use) = deadlineOf(timeout)
  var order: seq[OpId]
  var explored = 0
  var inconclusive = false
  var anyTimedOut = false
  var failed = false
  var witness: Witness[Op, Res]
  var witnessSeq = high(int)
  for k in keys:
    let part = h.subHistory(parts.getOrDefault(k) + ticks)
    var n = 0
    var tOut = false
    let v = checkCore(part, init, model, budget, deadline, use, n, tOut)
    explored += n
    case v.kind
    of vkLinearizable:
      order.add v.order
    of vkInconclusive:
      inconclusive = true
      if tOut:
        anyTimedOut = true
        break                # the deadline is shared: later parts would time out too
    of vkNotLinearizable:
      let sq = invSeq.getOrDefault(v.witness.stuck, high(int))
      if not failed or sq < witnessSeq:
        witness = v.witness
        witnessSeq = sq
      failed = true
  if failed:
    verified(Verdict[Op, Res](kind: vkNotLinearizable, witness: witness))
  elif inconclusive:
    Verdict[Op, Res](kind: vkInconclusive, statesExplored: explored, budget: max(budget, 1),
                     timedOut: anyTimedOut)
  else:
    verified(Verdict[Op, Res](kind: vkLinearizable, order: order))
