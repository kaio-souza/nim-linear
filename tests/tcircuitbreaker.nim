## CircuitBreaker model: the bugs listed in docs/MODELS.md#circuitbreaker,
## cool-down with tick (M10), JSON hooks, and agreement with the oracle.
import std/[random, unittest]
import nimlinear
import nimlinear/models/circuitbreaker
import ./oracle/oracle

type Ev = Event[BreakerOp, BreakerRes]

proc op(id, th, inv, ret: int, call: BreakerOp, res: BreakerRes): seq[Ev] =
  @[invokeEvent[BreakerOp, BreakerRes](id, th, inv, call),
    returnEvent[BreakerOp, BreakerRes](id, th, ret, res)]
proc tk(id, sq: int): seq[Ev] = @[tickEvent[BreakerOp, BreakerRes](id, 9, sq, tick())]
proc verify(evs: seq[Ev], init = BreakerState(threshold: 2)): Verdict[BreakerOp, BreakerRes] =
  checkLinearizable(newHistory(evs), init, BreakerModel)

let openCooled = BreakerState(phase: pOpen, cooledDown: true, threshold: 2)

suite "CircuitBreaker: accepted":
  test "opens after threshold failures, rejects while open":
    let v = verify(op(1, 0, 1, 2, report(pkNormal, false), ack()) &
                   op(2, 0, 3, 4, report(pkNormal, false), ack()) &
                   op(3, 0, 5, 6, acquire(), rejected()))
    check v.kind == vkLinearizable

  test "concurrent acquires after cool-down: one probe, one rejected":
    let v = verify(op(1, 0, 1, 4, acquire(), allowed(pkProbe)) &
                   op(2, 1, 2, 3, acquire(), rejected()), openCooled)
    check v.kind == vkLinearizable

  test "probe success closes it":
    let v = verify(op(1, 0, 1, 2, acquire(), allowed(pkProbe)) &
                   op(2, 0, 3, 4, report(pkProbe, true), ack()) &
                   op(3, 0, 5, 6, acquire(), allowed(pkNormal)), openCooled)
    check v.kind == vkLinearizable

suite "CircuitBreaker: rejected bugs":
  test "two probes with no report between them":
    let v = verify(op(1, 0, 1, 4, acquire(), allowed(pkProbe)) &
                   op(2, 1, 2, 3, acquire(), allowed(pkProbe)), openCooled)
    check v.kind == vkNotLinearizable
    check v.witness.alternatives[0].why == "probe in progress"

  test "opens with fewer failures than threshold":
    let v = verify(op(1, 0, 1, 2, report(pkNormal, false), ack()) &
                   op(2, 0, 3, 4, acquire(), rejected()))
    check v.kind == vkNotLinearizable

  test "does not open after threshold failures":
    let v = verify(op(1, 0, 1, 2, report(pkNormal, false), ack()) &
                   op(2, 0, 3, 4, report(pkNormal, false), ack()) &
                   op(3, 0, 5, 6, acquire(), allowed(pkNormal)))
    check v.kind == vkNotLinearizable
    check v.witness.alternatives[0].why == "open"

  test "a late report(pkNormal) closing an open breaker":
    let v = verify(op(1, 0, 1, 2, report(pkNormal, true), ack()) &
                   op(2, 0, 3, 4, acquire(), allowed(pkNormal)),
                   BreakerState(phase: pOpen, threshold: 2))
    check v.kind == vkNotLinearizable

suite "CircuitBreaker: cool-down as tick (M10)":
  test "acquire before the tick is rejected, after it gets the probe":
    let open = BreakerState(phase: pOpen, threshold: 2)
    let v = verify(op(1, 0, 1, 2, acquire(), rejected()) & tk(2, 3) &
                   op(3, 0, 4, 5, acquire(), allowed(pkProbe)), open)
    check v.kind == vkLinearizable

  test "a probe before the cool-down tick is a bug":
    let open = BreakerState(phase: pOpen, threshold: 2)
    let v = verify(op(1, 0, 1, 2, acquire(), allowed(pkProbe)) & tk(2, 3), open)
    check v.kind == vkNotLinearizable

  test "an acquire overlapping the tick may go either way":
    let open = BreakerState(phase: pOpen, threshold: 2)
    for res in [rejected(), allowed(pkProbe)]:
      let evs = @[invokeEvent[BreakerOp, BreakerRes](1, 0, 1, acquire())] & tk(2, 2) &
                @[returnEvent[BreakerOp, BreakerRes](1, 0, 3, res)]
      check verify(evs, open).kind == vkLinearizable

  test "probe failure reopens and needs a new tick":
    let v = verify(op(1, 0, 1, 2, acquire(), allowed(pkProbe)) &
                   op(2, 0, 3, 4, report(pkProbe, false), ack()) &
                   op(3, 0, 5, 6, acquire(), allowed(pkProbe)), openCooled)
    check v.kind == vkNotLinearizable

suite "CircuitBreaker: JSON":
  test "round trip":
    let h = newHistory(op(1, 0, 1, 2, acquire(), allowed(pkProbe)) & tk(2, 3) &
                       op(3, 1, 4, 5, report(pkProbe, false), ack()) &
                       op(4, 1, 6, 7, acquire(), rejected()))
    let s = h.toJsonLines()
    let back = parseJsonLines[BreakerOp, BreakerRes](s)
    check back.toJsonLines() == s
    check back.events == h.events

proc breakerOp(r: var Rand): BreakerOp =
  case r.rand(3)
  of 0, 1: acquire()
  else: report([pkNormal, pkProbe][r.rand(1)], r.rand(1) == 0)

proc breakerOther(r: var Rand, res: BreakerRes): BreakerRes =
  let all = [allowed(pkNormal), allowed(pkProbe), rejected(), ack()]
  while true:
    result = all[r.rand(all.len - 1)]
    if not (result == res): return

suite "CircuitBreaker: oracle":
  test "agrees with the oracle on 10,000 random histories (with ticks)":
    for seed in 0 ..< 10_000:
      var rng = initRand(seed)
      let init = BreakerState(phase: [pClosed, pOpen, pHalfOpen][rng.rand(2)],
                              cooledDown: rng.rand(1) == 0, threshold: rng.rand(1..2))
      let (h, ops) = generate(rng, init, BreakerModel, breakerOp, breakerOther,
                              maxTicks = 2, tickCall = tick())
      let want = if oracleLinearizable(ops, init, BreakerModel): vkLinearizable else: vkNotLinearizable
      let got = checkLinearizable(h, init, BreakerModel)
      if got.kind != want:
        checkpoint("seed=" & $seed & " oracle=" & $want & " checker=" & $got.kind)
      check got.kind == want
