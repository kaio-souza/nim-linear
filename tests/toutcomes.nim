## M14: nondeterministic specifications through `outcomes`.
import std/[random, unittest]
import nimlinear
import ./oracle/[oracle, ndmodels]

type BEv = Event[BagOp, BagRes]
proc bop(id, th, inv, ret: int, call: BagOp, res = BagRes()): seq[BEv] =
  @[invokeEvent[BagOp, BagRes](id, th, inv, call), returnEvent[BagOp, BagRes](id, th, ret, res)]
func r(v: int): BagRes = BagRes(value: v)
proc ids(xs: seq[OpId]): seq[int] =
  for x in xs: result.add int(x)
proc bag(evs: seq[BEv]): Verdict[BagOp, BagRes] =
  checkLinearizable(newHistory(evs), BagState(), BagModel)

suite "outcomes: bag":
  test "the model is detected":
    check hasOutcomes(BagModel, BagState, BagOp)

  test "take may return any item, not only the oldest":
    for v in [1, 2]:
      check bag(bop(1, 0, 1, 2, put(1)) & bop(2, 0, 3, 4, put(2)) & bop(3, 0, 5, 6, take(), r(v))).kind == vkLinearizable

  test "an item never put is rejected, with the first outcome as expected":
    let v = bag(bop(1, 0, 1, 2, put(1)) & bop(2, 0, 3, 4, take(), r(7)))
    check v.kind == vkNotLinearizable
    check int(v.witness.stuck) == 2
    check v.witness.alternatives[0].expected == r(1)

  test "an item taken twice is rejected":
    let v = bag(bop(1, 0, 1, 2, put(1)) & bop(2, 0, 3, 4, put(2)) &
                bop(3, 0, 5, 6, take(), r(1)) & bop(4, 0, 7, 8, take(), r(1)))
    check v.kind == vkNotLinearizable

  test "a pending take branches over every item":
    # Pending take removed 1 or 2; the later takes saw the other one and empty.
    for (a, b) in [(2, -1), (1, -1)]:
      let evs = bop(1, 0, 1, 2, put(1)) & bop(2, 0, 3, 4, put(2)) &
                @[invokeEvent[BagOp, BagRes](3, 1, 5, take())] &
                bop(4, 0, 6, 7, take(), r(a)) & bop(5, 0, 8, 9, take(), r(b))
      check bag(evs).kind == vkLinearizable

  test "deterministic order: outcomes in the model's order (D-20)":
    let v = bag(bop(1, 0, 1, 2, put(1)) & bop(2, 0, 3, 4, put(2)) &
                bop(3, 0, 5, 6, take(), r(2)) & bop(4, 0, 7, 8, take(), r(1)))
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2, 3, 4]

type WEv = Event[WOp, WRes]
proc wop(id, th, inv, ret: int, call: WOp, res: WRes): seq[WEv] =
  @[invokeEvent[WOp, WRes](id, th, inv, call), returnEvent[WOp, WRes](id, th, ret, res)]

suite "outcomes: weak CAS":
  test "a spurious failure is accepted":
    let v = checkLinearizable(newHistory(wop(1, 0, 1, 2, wcas(0, 1), WRes(ok: false)) &
                                         wop(2, 0, 3, 4, wread(), WRes(value: 0, ok: true))),
                              WState(), WeakRegModel)
    check v.kind == vkLinearizable

  test "a failure followed by the new value is rejected":
    let v = checkLinearizable(newHistory(wop(1, 0, 1, 2, wcas(0, 1), WRes(ok: false)) &
                                         wop(2, 0, 3, 4, wread(), WRes(value: 1, ok: true))),
                              WState(), WeakRegModel)
    check v.kind == vkNotLinearizable

proc bagOp(r: var Rand): BagOp =
  if r.rand(1) == 0: put(r.rand(0..2)) else: take()
proc bagOther(r: var Rand, res: BagRes): BagRes =
  BagRes(value: [-1, 0, 1, 2][(res.value + 2 + r.rand(2)) mod 4])
proc wOp(r: var Rand): WOp =
  case r.rand(2)
  of 0: wread()
  of 1: wwrite(r.rand(0..2))
  else: wcas(r.rand(0..2), r.rand(0..2))
proc wOther(r: var Rand, res: WRes): WRes =
  result = res
  if r.rand(1) == 0: result.value = (res.value + 1 + r.rand(1)) mod 3
  else: result.ok = not res.ok

template agree(M, init, genOp, other: untyped) =
  var lin, notLin = 0
  for seed in 0 ..< 10_000:
    var rng = initRand(seed)
    let (h, ops) = generate(rng, init, M, genOp, other)
    let want = if oracleLinearizable(ops, init, M): vkLinearizable else: vkNotLinearizable
    let got = checkLinearizable(h, init, M)
    if got.kind != want:
      checkpoint("seed=" & $seed & " oracle=" & $want & " checker=" & $got.kind)
    check got.kind == want
    if want == vkLinearizable: inc lin else: inc notLin
  check lin > 1000 and notLin > 1000

suite "outcomes: oracle":
  test "bag: agrees with the oracle on 10,000 random histories":
    agree(BagModel, BagState(), bagOp, bagOther)
  test "weak CAS: agrees with the oracle on 10,000 random histories":
    agree(WeakRegModel, WState(), wOp, wOther)

suite "outcomes: review fixes":
  test "a pending op with no outcome is never stuck (not applied)":
    # PickyModel: take() on an empty bag has no outcome at all.
    let evs = @[invokeEvent[BagOp, BagRes](1, 1, 1, take())] &
              bop(2, 0, 2, 3, put(1)) & bop(3, 0, 4, 5, take(), r(7))
    let v = checkLinearizable(newHistory(evs), BagState(), PickyModel)
    check v.kind == vkNotLinearizable
    check int(v.witness.stuck) == 3
    for a in v.witness.alternatives: check int(a.candidate) != 1

  test "a tick with no outcome can be stuck, with its own id (not stale)":
    # put(1) fine, then a tick whose call is take() on an empty bag after the
    # item was taken: no outcome. The stuck must be the tick (id 9).
    let evs = bop(1, 0, 1, 2, put(1)) & bop(2, 0, 3, 4, take(), r(1)) &
              @[tickEvent[BagOp, BagRes](9, 5, 5, take())]
    let v = checkLinearizable(newHistory(evs), BagState(), PickyModel)
    check v.kind == vkNotLinearizable
    check int(v.witness.stuck) == 9
    check v.witness.stuckCall == take()
