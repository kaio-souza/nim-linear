## Linearizability checker (M2–M4, M10, M11): graph search memoizing
## (linearized, state) configurations, D-11. Deterministic (D-20).

import std/[algorithm, hashes, sets, tables]
import ./history

type
  VerdictKind* = enum vkLinearizable, vkNotLinearizable, vkInconclusive

  Alternative*[Res] = object
    candidate*: OpId     ## operation tried as the next linearization point
    expected*: Res       ## result the model expected
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

  OpInfo[Op, Res] = object
    id: OpId
    invSeq, retSeq: int    # retSeq = high(int) for a pending op
    pending: bool
    tick: bool             # instantaneous (M10): invSeq == retSeq, result not compared
    call: Op
    res: Res

  Config[S] = object
    bits: seq[uint64]
    state: S

  Frame[S, Res] = object
    state: S
    cand: int              # next candidate to try (index into ops)
    minRet: int            # lowest retSeq among completed, unlinearized ops
    alts: seq[Alternative[Res]]

proc hash[S](c: Config[S]): Hash =
  mixin hash
  var h: Hash = 0
  for w in c.bits: h = h !& hash(w)
  h = h !& hash(c.state)
  !$h

proc `==`[S](a, b: Config[S]): bool =
  mixin `==`
  a.bits == b.bits and a.state == b.state

template isSet(bits: seq[uint64], i: int): bool = (bits[i shr 6] and (1'u64 shl (i and 63))) != 0
template setBit(bits: var seq[uint64], i: int) = bits[i shr 6] = bits[i shr 6] or (1'u64 shl (i and 63))
template clearBit(bits: var seq[uint64], i: int) = bits[i shr 6] = bits[i shr 6] and not (1'u64 shl (i and 63))

proc checkCore[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                           budget: int, explored: var int): Verdict[Op, Res] {.raises: [].} =
  mixin step, `==`, hash

  # Operations in increasing invoke seq (h.events is already sorted).
  # Internal times are 2*seq; a tick occupies [2*seq, 2*seq + 1], so it is a
  # candidate exactly when nothing that returned earlier is still unlinearized.
  var ops: seq[OpInfo[Op, Res]]
  for e in h.events:
    case e.kind
    of ekInvoke:
      ops.add OpInfo[Op, Res](id: e.op, invSeq: 2 * int(e.seqNo), retSeq: high(int),
                              pending: true, call: e.call)
    of ekTick:
      ops.add OpInfo[Op, Res](id: e.op, invSeq: 2 * int(e.seqNo), retSeq: 2 * int(e.seqNo) + 1,
                              tick: true, call: e.call)
    of ekReturn: discard
  for e in h.events:
    if e.kind == ekReturn:
      for o in ops.mitems:
        if o.id == e.op:
          o.retSeq = 2 * int(e.seqNo); o.pending = false; o.res = e.res
          break
  let n = ops.len

  var bits = newSeq[uint64]((n + 63) div 64)
  var completedLeft = 0
  for o in ops:
    if not o.pending: inc completedLeft

  proc minRetOf(bits: seq[uint64]): int =
    result = high(int)
    for i in 0 ..< n:
      if not bits.isSet(i) and ops[i].retSeq < result: result = ops[i].retSeq

  var visited = initHashSet[Config[S]]()
  visited.incl Config[S](bits: bits, state: init)
  explored = 1
  var path: seq[int]
  var stack = @[Frame[S, Res](state: init, cand: 0, minRet: minRetOf(bits))]
  var bestLen = -1
  var best: Witness[Op, Res]

  when defined(nimlinearMeasure):
    let baseMem = getOccupiedMem()
    var peakMem = baseMem
    template sampleMem() =
      if (explored and 1023) == 0:
        let m = getOccupiedMem()
        if m > peakMem: peakMem = m

  while true:
    if completedLeft == 0:
      when defined(nimlinearMeasure):
        debugEcho "nimlinearMeasure peakDelta=", max(peakMem, getOccupiedMem()) - baseMem, " explored=", explored
      var order: seq[OpId]
      for i in path: order.add ops[i].id
      return Verdict[Op, Res](kind: vkLinearizable, order: order)
    if stack.len == 0: break

    let top = stack.high
    var i = stack[top].cand
    while i < n and (bits.isSet(i)) and ops[i].invSeq < stack[top].minRet: inc i
    if i >= n or ops[i].invSeq >= stack[top].minRet:
      # No candidates left: this configuration fails.
      if path.len > bestLen:
        bestLen = path.len
        best.prefix.setLen 0
        for j in path: best.prefix.add ops[j].id
        best.alternatives = stack[top].alts
        if best.alternatives.len > 0:
          let s = best.alternatives[0].candidate
          for o in ops:
            if o.id == s:
              best.stuck = o.id; best.stuckCall = o.call; best.stuckRes = o.res
              break
      stack.setLen top
      if path.len > 0:
        let j = path.pop
        bits.clearBit(j)
        if not ops[j].pending: inc completedLeft
      continue

    stack[top].cand = i + 1
    let e = step(model, stack[top].state, ops[i].call)
    if not ops[i].pending and not ops[i].tick and not (e.res == ops[i].res):
      stack[top].alts.add Alternative[Res](candidate: ops[i].id, expected: e.res,
                                           observed: ops[i].res, why: e.why)
      continue

    bits.setBit(i)
    let cfg = Config[S](bits: bits, state: e.next)
    if cfg in visited:
      bits.clearBit(i)
      continue
    if explored >= budget:
      when defined(nimlinearMeasure):
        debugEcho "nimlinearMeasure peakDelta=", max(peakMem, getOccupiedMem()) - baseMem, " explored=", explored
      return Verdict[Op, Res](kind: vkInconclusive, statesExplored: explored, budget: budget)
    visited.incl cfg
    inc explored
    when defined(nimlinearMeasure):
      sampleMem()
    path.add i
    if not ops[i].pending: dec completedLeft
    stack.add Frame[S, Res](state: e.next, cand: 0, minRet: minRetOf(bits))

  when defined(nimlinearMeasure):
    debugEcho "nimlinearMeasure peakDelta=", max(peakMem, getOccupiedMem()) - baseMem, " explored=", explored
  Verdict[Op, Res](kind: vkNotLinearizable, witness: best)

proc checkLinearizable*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                                    budget = 1_000_000): Verdict[Op, Res] {.raises: [].} =
  ## Looks for a sequential order that respects real time and in which the
  ## model produces the observed results. See docs/API.md#checklinearizable.
  var explored = 0
  checkCore(h, init, model, budget, explored)

proc checkPartitioned*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                                   budget = 1_000_000): Verdict[Op, Res] {.raises: [].} =
  ## Splits the history by `partition(model, op)` and checks each part with
  ## `checkLinearizable`, in increasing key order (D-12, D-20). Ticks (M10)
  ## go into every part. See docs/API.md#checkpartitioned.
  mixin partition
  var keyOf = initTable[OpId, int]()
  var parts = initTable[int, seq[Event[Op, Res]]]()
  var ticks: seq[Event[Op, Res]]
  var invSeq = initTable[OpId, int]()
  for e in h.events:
    case e.kind
    of ekInvoke:
      let k = partition(model, e.call)
      keyOf[e.op] = k
      invSeq[e.op] = int(e.seqNo)
      parts.mgetOrPut(k, @[]).add e
    of ekReturn:
      parts.mgetOrPut(keyOf.getOrDefault(e.op), @[]).add e
    of ekTick:
      ticks.add e
  var keys: seq[int]
  for k in parts.keys: keys.add k
  keys.sort()
  if keys.len == 0 and ticks.len > 0:
    return checkLinearizable(h, init, model, budget)

  var order: seq[OpId]
  var explored = 0
  var inconclusive = false
  var failed = false
  var witness: Witness[Op, Res]
  var witnessSeq = high(int)
  for k in keys:
    var evs = parts.getOrDefault(k)
    if ticks.len > 0:
      evs.add ticks
      evs.sort(proc (a, b: Event[Op, Res]): int = cmp(int(a.seqNo), int(b.seqNo)))
    var n = 0
    let v = checkCore(History[Op, Res](events: evs), init, model, budget, n)
    explored += n
    case v.kind
    of vkLinearizable:
      order.add v.order
    of vkInconclusive:
      inconclusive = true
    of vkNotLinearizable:
      let sq = invSeq.getOrDefault(v.witness.stuck, high(int))
      if not failed or sq < witnessSeq:
        witness = v.witness
        witnessSeq = sq
      failed = true
  if failed:
    Verdict[Op, Res](kind: vkNotLinearizable, witness: witness)
  elif inconclusive:
    Verdict[Op, Res](kind: vkInconclusive, statesExplored: explored, budget: budget)
  else:
    Verdict[Op, Res](kind: vkLinearizable, order: order)
