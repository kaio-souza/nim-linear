## M6: the brute-force oracle agrees with the checker on 10,000 random
## histories per model (Register and BoundedQueue). Fixed seeds; the failing
## seed is printed. See CONTRIBUTING.md#brute-force-oracle-m6.
import std/[random, unittest]
import nimlinear
import nimlinear/models/[register, boundedqueue]
import ./oracle/oracle

const histories = 10_000

proc regOp(r: var Rand): RegOp =
  case r.rand(2)
  of 0: read()
  of 1: write(r.rand(0..2))
  else: cas(r.rand(0..2), r.rand(0..2))

proc regOther(r: var Rand, res: RegRes): RegRes =
  # another possible value: different read value or flipped ok
  result = res
  if r.rand(1) == 0: result.value = (res.value + 1 + r.rand(1)) mod 3
  else: result.ok = not res.ok

proc queueOp(r: var Rand): QueueOp =
  case r.rand(9)
  of 0..4: enqueue(r.rand(0..2))
  of 5..8: dequeue()
  else: close()

proc queueOther(r: var Rand, res: QueueRes): QueueRes =
  let all = @[okRes(), fullRes(), closedRes(), emptyRes(),
              valueRes(0), valueRes(1), valueRes(2)]
  while true:
    result = all[r.rand(all.len - 1)]
    if not (result == res): return

template agree(seed: int, h, ops, init, M: untyped) =
  let want = oracleLinearizable(ops, init, M)
  let got = checkLinearizable(h, init, M, budget = 500_000)
  let expected = if want: vkLinearizable else: vkNotLinearizable
  if got.kind != expected:
    checkpoint("seed=" & $seed & " oracle=" & $expected & " checker=" & $got.kind)
  check got.kind == expected

suite "oracle M6":
  test "Register: agrees with checker on 10,000 random histories":
    for seed in 0 ..< histories:
      var rng = initRand(seed)
      let (h, ops) = generate(rng, RegState(), RegisterModel, regOp, regOther)
      agree(seed, h, ops, RegState(), RegisterModel)

  test "BoundedQueue: agrees with checker on 10,000 random histories":
    for seed in 0 ..< histories:
      var rng = initRand(seed)
      let init = QueueState(capacity: rng.rand(1..2))
      let (h, ops) = generate(rng, init, QueueModel, queueOp, queueOther)
      agree(seed, h, ops, init, QueueModel)

  test "generator produces both verdicts":
    var lin, notLin = 0
    for seed in 0 ..< 1000:
      var rng = initRand(seed)
      let (_, ops) = generate(rng, RegState(), RegisterModel, regOp, regOther)
      if oracleLinearizable(ops, RegState(), RegisterModel): inc lin else: inc notLin
    check lin > 200
    check notLin > 200
