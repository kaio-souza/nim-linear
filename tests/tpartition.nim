## M11: checkPartitioned. Hand-written cases plus agreement with
## checkLinearizable and the brute-force oracle on random histories.
import std/[hashes, random, unittest]
import nimlinear
import nimlinear/models/register
import ./oracle/[oracle, kvttl]

type Ev = Event[KvOp, KvRes]

proc op(id, th, inv, ret: int, call: KvOp, res = KvRes()): seq[Ev] =
  @[invokeEvent[KvOp, KvRes](id, th, inv, call), returnEvent[KvOp, KvRes](id, th, ret, res)]
func r(v: int): KvRes = KvRes(value: v)
proc ids(xs: seq[OpId]): seq[int] =
  for x in xs: result.add int(x)

suite "checkPartitioned":
  test "empty history":
    let v = checkPartitioned(newHistory[KvOp, KvRes](@[]), initKv(), KvModel)
    check v.kind == vkLinearizable
    check v.order.len == 0

  test "order: parts concatenated in increasing key order":
    # key 1 ops come first in time, key 0 ops later.
    let evs = op(1, 0, 1, 2, put(1, 5)) & op(2, 0, 3, 4, get(1), r(5)) &
              op(3, 1, 5, 6, put(0, 7)) & op(4, 1, 7, 8, get(0), r(7))
    let v = checkPartitioned(newHistory(evs), initKv(), KvModel)
    check v.kind == vkLinearizable
    check ids(v.order) == @[3, 4, 1, 2]

  test "witness: failed part whose stuck op has the lowest seq":
    let evs = op(1, 0, 1, 2, put(1, 5)) & op(2, 0, 3, 4, get(1), r(0)) &   # stuck seq 3
              op(3, 1, 5, 6, put(0, 7)) & op(4, 1, 7, 8, get(0), r(0))    # stuck seq 7
    let v = checkPartitioned(newHistory(evs), initKv(), KvModel)
    check v.kind == vkNotLinearizable
    check int(v.witness.stuck) == 2
    check ids(v.witness.prefix) == @[1]

  test "inconclusive: budget per part, statesExplored summed":
    var evs: seq[Ev]
    for t in 0 ..< 3:
      evs.add op(t + 1, t, t + 1, 100 + t, put(0, t))
      evs.add op(t + 11, t + 3, t + 10, 110 + t, put(1, t))
    let h = newHistory(evs)
    let v = checkPartitioned(h, initKv(), KvModel, budget = 3)
    check v.kind == vkInconclusive
    check v.budget == 3
    check v.statesExplored == 6
    check checkPartitioned(h, initKv(), KvModel).kind == vkLinearizable

  test "ticks are copied into every part":
    let evs = op(1, 0, 1, 2, put(0, 5)) & op(2, 1, 3, 4, put(1, 6)) &
              @[tickEvent[KvOp, KvRes](9, 2, 5, tick()), tickEvent[KvOp, KvRes](10, 2, 6, tick())] &
              op(3, 0, 7, 8, get(0), r(-1)) & op(4, 1, 9, 10, get(1), r(-1))
    let v = checkPartitioned(newHistory(evs), initKv(), KvModel)
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 9, 10, 3, 2, 9, 10, 4]

  test "does not compile without partition":
    check not compiles(checkPartitioned(newHistory[RegOp, RegRes](@[]), RegState(), RegisterModel))

proc kvOp(rng: var Rand): KvOp =
  if rng.rand(1) == 0: put(rng.rand(0..1), rng.rand(1..2)) else: get(rng.rand(0..1))

proc kvOther(rng: var Rand, res: KvRes): KvRes =
  KvRes(value: [-1, 0, 1, 2][(res.value + 2 + rng.rand(2)) mod 4])

suite "checkPartitioned vs oracle":
  test "agrees with the oracle and checkLinearizable on 10,000 histories (with ticks)":
    var lin, notLin = 0
    for seed in 0 ..< 10_000:
      var rng = initRand(seed)
      let (h, ops) = generate(rng, initKv(), KvModel, kvOp, kvOther,
                              maxTicks = 3, tickCall = tick())
      let want = if oracleLinearizable(ops, initKv(), KvModel): vkLinearizable else: vkNotLinearizable
      let whole = checkLinearizable(h, initKv(), KvModel)
      let split = checkPartitioned(h, initKv(), KvModel)
      if whole.kind != want or split.kind != want:
        checkpoint("seed=" & $seed & " oracle=" & $want & " whole=" & $whole.kind & " split=" & $split.kind)
      check whole.kind == want
      check split.kind == want
      if want == vkLinearizable: inc lin else: inc notLin
    check lin > 1000
    check notLin > 1000

# M21: any key type with hash, == and <.
type
  SOp = object
    key: string
    write: bool
    value: int
  SRes = object
    value: int
  SState = object
    vals: seq[(string, int)]
  SModel = object

func hash(s: SState): Hash = hash(s.vals)
func lookup(s: SState, k: string): int =
  for (kk, v) in s.vals:
    if kk == k: return v
func step(m: typedesc[SModel], s: SState, op: SOp): Expected[SState, SRes] {.raises: [].} =
  if op.write:
    var n = SState()
    for (kk, v) in s.vals:
      if kk != op.key: n.vals.add (kk, v)
    n.vals.add (op.key, op.value)
    Expected[SState, SRes](next: n, res: SRes())
  else:
    Expected[SState, SRes](next: s, res: SRes(value: s.lookup(op.key)))
func partition(m: typedesc[SModel], op: SOp): string {.raises: [].} = op.key

suite "checkPartitioned: generic key (M21)":
  test "string keys, parts in increasing key order":
    type E = Event[SOp, SRes]
    proc o(id, inv, ret: int, call: SOp, res = SRes()): seq[E] =
      @[invokeEvent[SOp, SRes](id, 0, inv, call), returnEvent[SOp, SRes](id, 0, ret, res)]
    let evs = o(1, 1, 2, SOp(key: "zeta", write: true, value: 5)) &
              o(2, 3, 4, SOp(key: "alpha", write: true, value: 7)) &
              o(3, 5, 6, SOp(key: "zeta"), SRes(value: 5)) &
              o(4, 7, 8, SOp(key: "alpha"), SRes(value: 7))
    let v = checkPartitioned(newHistory(evs), SState(), SModel)
    check v.kind == vkLinearizable
    check ids(v.order) == @[2, 4, 1, 3]
    let bad = o(1, 1, 2, SOp(key: "k", write: true, value: 5)) & o(2, 3, 4, SOp(key: "k"), SRes(value: 0))
    check checkPartitioned(newHistory(bad), SState(), SModel).kind == vkNotLinearizable
