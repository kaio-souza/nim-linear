## Time benchmark for checkLinearizable (see docs/MEASUREMENTS.md#benchmarks).
## nim c -r -d:release --mm:orc tests/measure/bench.nim
## A: worst case for the register (2^n subsets x n values).
## B: worst case for the queue (states = ordered prefixes of the enqueues).
## C: long, realistic linearizable history; should scale linearly.
import std/[monotimes, times, strutils, random]
import nimlinear
import nimlinear/models/[register, boundedqueue]

proc timeIt[S, Op, Res](name: string, h: History[Op, Res], init: S, M: typedesc) =
  let t0 = getMonoTime()
  let v = checkLinearizable(h, init, M, budget = 20_000_000)
  let ms = (getMonoTime() - t0).inMicroseconds.float / 1000
  let extra = if v.kind == vkInconclusive: " states=" & $v.statesExplored else: ""
  echo name.alignLeft(48), ($v.kind).alignLeft(18), ms.formatFloat(ffDecimal, 1), " ms", extra

# A: n fully-overlapping writes (all invoked, then all returned) + bad final read.
for n in [8, 12, 14, 16, 18]:
  var evs: seq[Event[RegOp, RegRes]]
  var s = 0
  for i in 1..n: inc s; evs.add invokeEvent[RegOp, RegRes](i, i, s, write(i))
  for i in 1..n: inc s; evs.add returnEvent[RegOp, RegRes](i, i, s, RegRes(ok: true))
  inc s; evs.add invokeEvent[RegOp, RegRes](n+1, 0, s, read())
  inc s; evs.add returnEvent[RegOp, RegRes](n+1, 0, s, RegRes(value: -1, ok: true))
  timeIt("A register: " & $n & " overlapping writes + bad read", newHistory(evs), RegState(), RegisterModel)

# B: n overlapping enqueues of distinct values, then a dequeue sequence in an
# impossible order -> queue state = permutations of the enqueued prefix.
for n in [6, 8, 9, 10]:
  var evs: seq[Event[QueueOp, QueueRes]]
  var s = 0
  for i in 1..n: inc s; evs.add invokeEvent[QueueOp, QueueRes](i, i, s, enqueue(i))
  for i in 1..n: inc s; evs.add returnEvent[QueueOp, QueueRes](i, i, s, okRes())
  for i in 1..n:   # dequeues must return a permutation; last one wrong
    let v = if i == n: 999 else: i
    inc s; evs.add invokeEvent[QueueOp, QueueRes](100+i, 0, s, dequeue())
    inc s; evs.add returnEvent[QueueOp, QueueRes](100+i, 0, s, valueRes(v))
  timeIt("B queue: " & $n & " overlapping enqueues, bad dequeue", newHistory(evs), QueueState(capacity: 100), QueueModel)

# C: long, realistic linearizable history: 4 threads, k ops each, random
# overlaps of width ~4, register read/write consistent with a real execution.
for k in [250, 1000, 2500, 5000]:
  var rng = initRand(1)
  var evs: seq[Event[RegOp, RegRes]]
  var s = 0
  var val = 0
  var id = 0
  for round in 0 ..< k:
    var ids: array[4, int]
    var calls: array[4, RegOp]
    for t in 0..3:
      inc id; ids[t] = id; inc s
      calls[t] = if rng.rand(1) == 0: read() else: write(rng.rand(0..3))
      evs.add invokeEvent[RegOp, RegRes](id, t, s, calls[t])
    for t in 0..3:   # linearize in thread order, return in thread order
      var res = RegRes(ok: true)
      if calls[t].kind == rRead: res.value = val
      else: val = calls[t].value
      inc s; evs.add returnEvent[RegOp, RegRes](ids[t], t, s, res)
  timeIt("C register: 4 threads x " & $k & " ops, linearizable", newHistory(evs), RegState(), RegisterModel)
