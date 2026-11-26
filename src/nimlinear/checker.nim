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
    stuckEverFit*: bool  ## the stuck operation's observed result matched the model
                         ## in some explored configuration (false: no order explains it)

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

  Window = object
    ## P9.1: the key's window. Word 0 is inline, so no heap allocation while
    ## the overlap stays under 65 operations; words 1.. are in `extra`
    ## (nil when `nw <= 1`), shared between copies and never mutated in
    ## place (copy on write in `childKey`). With `f` packed next to `nw`, a
    ## key is 24 bytes, the same as the former `(int, seq)` but with no
    ## allocation. Canonical: `nw` words, the last one nonzero.
    f: int32               # set only in a Config's key (memo), else unused
    nw: int32
    w0: uint64
    extra: ref seq[uint64]

  Config[S] = object
    window: Window         # P9.1: `f` lives in `window.f`, packed with `nw`
    state: S               # (the HashSet already stores each key's hash)

  Frame[S, Res] = object
    state: S
    f: int                 # every index < f is linearized
    window: Window         # bit j: index f + 1 + j linearized
    minRet: int            # lowest retSeq among completed, unlinearized ops
    minRetPos: int         # position of that op in `byRet`
    cand: int              # next candidate index to try
    cur: int               # candidate whose outcomes are being tried (-1: none)
    nexts: seq[S]          # next states still to try for `cur`
    alts: seq[Alternative[Res]]

template word(w: Window, k: int): uint64 =
  (if k == 0: w.w0 else: w.extra[][k - 1])


proc `==`*(a, b: Window): bool {.inline.} =
  ## Internal, exported for the same reason as `hash`. Compares `extra` by
  ## value (the default `==` would compare the refs).
  if a.f != b.f or a.nw != b.nw or a.w0 != b.w0: return false
  for k in 1 ..< a.nw:
    if a.extra[][k - 1] != b.extra[][k - 1]: return false
  true

proc toWords(w: Window): seq[uint64] =
  for k in 0 ..< w.nw: result.add w.word(k)

proc keyHash[S](f: int, w: Window, state: S): Hash {.inline.} =
  mixin hash
  var h: Hash = hash(f)
  for k in 0 ..< w.nw: h = h !& hash(w.word(k))
  h = h !& hash(state)
  !$h

proc hash*(w: Window): Hash {.inline.} =
  ## Internal (exported only so that the HashSet of `checkCore` finds it at
  ## the instantiation site; `Window` itself is private).
  var h: Hash = hash(w.f)
  for k in 0 ..< w.nw: h = h !& hash(w.word(k))
  !$h

proc hash*[S](c: Config[S]): Hash {.inline.} = keyHash(int(c.window.f), c.window, c.state)

proc `==`*[S](a, b: Config[S]): bool =
  mixin `==`
  a.window == b.window and a.state == b.state

template isSet(bits: seq[uint64], i: int): bool = (bits[i shr 6] and (1'u64 shl (i and 63))) != 0
template setBit(bits: var seq[uint64], i: int) = bits[i shr 6] = bits[i shr 6] or (1'u64 shl (i and 63))
template clearBit(bits: var seq[uint64], i: int) = bits[i shr 6] = bits[i shr 6] and not (1'u64 shl (i and 63))

proc childKey(f: var int, window: var Window, i: int) =
  ## Adds index `i` (not yet linearized, `i >= f`) to the key `(f, window)`.
  if i > f:
    let b = i - f - 1
    let k = b shr 6
    let bit = 1'u64 shl (b and 63)
    if k == 0:
      window.w0 = window.w0 or bit
      if window.nw == 0: window.nw = 1
      return
    var e: ref seq[uint64]          # copy on write: `extra` may be shared
    new(e)
    if window.extra != nil: e[] = window.extra[]
    if e[].len < k: e[].setLen k
    e[][k - 1] = e[][k - 1] or bit
    window.extra = e
    window.nw = int32(max(int(window.nw), k + 1))
    return
  # i == f: the new first unlinearized index skips the run of ones at bit 0.
  var t = 0
  while t shr 6 < window.nw and (window.word(t shr 6) and (1'u64 shl (t and 63))) != 0: inc t
  f += t + 1
  let sh = t + 1                   # drop the run and the zero bit after it
  let words = sh shr 6
  let bitsSh = sh and 63
  var n = max(0, int(window.nw) - words)
  var ws: seq[uint64]
  if n > 1: ws.setLen n - 1
  var w0 = 0'u64
  for k in 0 ..< n:
    var w = window.word(k + words) shr bitsSh
    if bitsSh != 0 and k + words + 1 < window.nw:
      w = w or (window.word(k + words + 1) shl (64 - bitsSh))
    if k == 0: w0 = w else: ws[k - 1] = w
  while n > 0 and (if n == 1: w0 else: ws[n - 2]) == 0: dec n
  var res = Window(nw: int32(n), w0: w0)
  if n > 1:
    ws.setLen n - 1
    new(res.extra)
    res.extra[] = move ws
  window = res

template hasOutcomes*(model: typedesc, S, Op: typedesc): bool {.dirty.} =
  ## True when the model defines the nondeterministic contract (M14).
  compiles(outcomes(model, default(S), default(Op)))

# R8: `step` and `outcomes` are called through these `func`s, so a model that
# reads or writes a global, does I/O or calls a proc with side effects does not
# compile ("'pureStep' can have side effects"). Mutation through a `ref` or
# `ptr` inside the state is not caught (only with --experimental:strictFuncs).
# Escape hatch: -d:nimlinearImpureModel (the checker's results are then only
# as deterministic as the model).
when defined(nimlinearImpureModel):
  template pureStep(model, s, op: untyped): untyped = step(model, s, op)
  template pureOutcomes(model, s, op: untyped): untyped = outcomes(model, s, op)
else:
  func pureStep[S, Op](model: typedesc, s: S, op: Op): auto =
    mixin step
    step(model, s, op)
  func pureOutcomes[S, Op](model: typedesc, s: S, op: Op): auto =
    mixin outcomes
    outcomes(model, s, op)

proc buildOps[Op, Res](h: History[Op, Res]):
    (seq[OpInfo[Op, Res]], Table[OpId, int], seq[int]) {.raises: [].} =
  ## Preprocessing (P8: split from the search). Operations indexed in
  ## increasing invoke/tick `seq`; `indexOf` maps an `OpId` to its index;
  ## `byRet` lists the completed operations and ticks in increasing return
  ## time, for an incremental minRet. Internal times are 2*seq; a tick
  ## occupies [2*seq, 2*seq + 1], so it is a candidate exactly when nothing
  ## that returned earlier is still unlinearized. `History` guarantees every
  ## return has an earlier invoke (`newHistory`), so none is skipped.
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
  var byRet: seq[int]
  for i in 0 ..< ops.len:
    if not ops[i].pending: byRet.add i
  byRet.sort(proc (a, b: int): int = cmp(ops[a].retSeq, ops[b].retSeq))
  (ops, indexOf, byRet)

proc recordFailure[Op, Res](best: var Witness[Op, Res], path: seq[int],
                            ops: seq[OpInfo[Op, Res]], indexOf: Table[OpId, int],
                            alts: seq[Alternative[Res]]) {.raises: [].} =
  ## P8: the deepest failure so far becomes the witness: the linearized
  ## prefix, the candidates tried there, and the first of them as `stuck`.
  ## (`stuckEverFit` is set once the search ends.)
  best.prefix.setLen 0
  for j in path: best.prefix.add ops[j].id
  best.alternatives = alts
  # Reset first: a stale stuck from a shallower failure must not leak.
  best.stuck = OpId(0); best.stuckCall = default(Op); best.stuckRes = default(Res)
  if alts.len > 0:
    let s = indexOf.getOrDefault(alts[0].candidate, -1)
    if s >= 0:
      best.stuck = ops[s].id; best.stuckCall = ops[s].call; best.stuckRes = ops[s].res

proc checkCore[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
                           budget: int, deadline: MonoTime, useDeadline: bool,
                           explored: var int, timedOut: var bool): Verdict[Op, Res] {.raises: [].} =
  mixin step, outcomes, `==`, hash
  timedOut = false
  let budget = max(budget, 1)    # the initial configuration always counts

  let (ops, indexOf, byRet) = buildOps(h)
  let n = ops.len

  var bits = newSeq[uint64]((n + 63) div 64)
  var fit = newSeq[bool](n)     # observed result matched the model somewhere
  var completedLeft = byRet.len

  proc nextMin(bits: seq[uint64], fromPos: int): (int, int) =
    var p = fromPos
    while p < byRet.len and bits.isSet(byRet[p]): inc p
    if p < byRet.len: (ops[byRet[p]].retSeq, p) else: (high(int), p)

  var visited = initHashSet[Config[S]]()
  visited.incl Config[S](state: init)
  explored = 1
  var path: seq[int]
  var stack: seq[Frame[S, Res]]
  var depth = 0                 # frames in use; stack keeps capacity (reused)
  template pushFrame(st: S, ff: int, ex: Window, mr, mrp: int) =
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
    pushFrame(init, 0, Window(), mr, mrp)
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
          recordFailure(best, path, ops, indexOf, stack[top].alts)
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
        let outs = pureOutcomes(model, stack[top].state, ops[i].call)
        for e in outs:
          if not check or e.res == ops[i].res: stack[top].nexts.add e.next
        if stack[top].nexts.len > 0: fit[i] = true
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
        let e = pureStep(model, stack[top].state, ops[i].call)
        if check and not (e.res == ops[i].res):
          stack[top].alts.add Alternative[Res](candidate: ops[i].id, expected: e.res,
                                               observed: ops[i].res, why: e.why)
          continue
        fit[i] = true
        stack[top].nexts.add e.next
      # Outcomes are tried in the model's order (D-20); pop from the back.
      stack[top].nexts.reverse()

    let i = stack[top].cur
    let next = stack[top].nexts.pop()

    # Child key after linearizing i.
    var f = stack[top].f
    var window = stack[top].window
    childKey(f, window, i)

    # P9.1: one lookup; the budget and timeout checks below run only for a
    # new configuration, as before (a config added just before returning
    # inconclusive changes nothing).
    var key = window
    key.f = int32(f)
    if visited.containsOrIncl(Config[S](window: key, state: next)):
      continue
    if explored >= budget:
      report()
      return Verdict[Op, Res](kind: vkInconclusive, statesExplored: explored, budget: budget)
    if useDeadline and (explored and 255) == 0 and not (getMonoTime() < deadline):
      report()
      timedOut = true
      return Verdict[Op, Res](kind: vkInconclusive, statesExplored: explored, budget: budget,
                              timedOut: true)
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
    when defined(nimlinearDebug):
      # P8: the compact key and the incremental minRet agree with the bitset.
      var ef = 0
      while ef < n and bits.isSet(ef): inc ef
      doAssert ef == f, "nimlinearDebug: f " & $f & " but first unlinearized index is " & $ef
      var ew: seq[uint64]
      for j in ef + 1 ..< n:
        if bits.isSet(j):
          let b = j - ef - 1
          while ew.len <= b shr 6: ew.add 0'u64
          ew[b shr 6] = ew[b shr 6] or (1'u64 shl (b and 63))
      doAssert ew == window.toWords, "nimlinearDebug: window does not match the bitset"
      var em = high(int)
      for j in 0 ..< n:
        if not ops[j].pending and not bits.isSet(j) and ops[j].retSeq < em: em = ops[j].retSeq
      doAssert em == mr, "nimlinearDebug: minRet " & $mr & " but true minimum is " & $em

  report()
  let si = indexOf.getOrDefault(best.stuck, -1)
  best.stuckEverFit = si >= 0 and fit[si]
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
  ## On `vkLinearizable`, `order` is the concatenation of the parts' orders
  ## (keys ascending), not a global real-time order; ticks appear once per part.
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
