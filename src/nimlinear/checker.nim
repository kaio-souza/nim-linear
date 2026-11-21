## Linearizability checker (M2–M4): graph search memoizing
## (linearized, state) configurations, D-11. Deterministic (D-20).

import std/[hashes, sets]
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

proc checkLinearizable*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                                    budget = 1_000_000): Verdict[Op, Res] {.raises: [].} =
  ## Looks for a sequential order that respects real time and in which the
  ## model produces the observed results. See docs/API.md#checklinearizable.
  mixin step, `==`, hash

  # Operations in increasing invoke seq (h.events is already sorted).
  var ops: seq[OpInfo[Op, Res]]
  for e in h.events:
    if e.kind == ekInvoke:
      ops.add OpInfo[Op, Res](id: e.op, invSeq: int(e.seqNo), retSeq: high(int),
                              pending: true, call: e.call)
  for e in h.events:
    if e.kind == ekReturn:
      for o in ops.mitems:
        if o.id == e.op:
          o.retSeq = int(e.seqNo); o.pending = false; o.res = e.res
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
  var explored = 1
  var path: seq[int]
  var stack = @[Frame[S, Res](state: init, cand: 0, minRet: minRetOf(bits))]
  var bestLen = -1
  var best: Witness[Op, Res]

  while true:
    if completedLeft == 0:
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
    if not ops[i].pending and not (e.res == ops[i].res):
      stack[top].alts.add Alternative[Res](candidate: ops[i].id, expected: e.res,
                                           observed: ops[i].res, why: e.why)
      continue

    bits.setBit(i)
    let cfg = Config[S](bits: bits, state: e.next)
    if cfg in visited:
      bits.clearBit(i)
      continue
    if explored >= budget:
      return Verdict[Op, Res](kind: vkInconclusive, statesExplored: explored, budget: budget)
    visited.incl cfg
    inc explored
    path.add i
    if not ops[i].pending: dec completedLeft
    stack.add Frame[S, Res](state: e.next, cand: 0, minRet: minRetOf(bits))

  Verdict[Op, Res](kind: vkNotLinearizable, witness: best)
