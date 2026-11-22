## Benchmark suite (M23). See docs/MEASUREMENTS.md#benchmarks.
##
##   nim c -r -d:release --mm:orc tests/measure/bench.nim            # table
##   nim c -r -d:release --mm:orc tests/measure/bench.nim --export:DIR
##                         # also writes every history as JSON Lines (for
##                         # tests/measure/porcupine)
##   nim c -r -d:release --mm:orc tests/measure/bench.nim --check     # CI
##
## Shapes:
##   A  register, n writes all overlapping, then a read of a value never
##      written (worst case: ~2^n * n configurations)
##   B  queue, n enqueues all overlapping, then n dequeues, the last wrong
##      (worst case: one configuration per ordered prefix)
##   C  register, 4 threads x k ops, overlap 4, linearizable (should be linear)
##   D  map with 3 keys, 4 overlapping writes per key, then a read per key;
##      the last key's read is wrong, so the unpartitioned search combines
##      the choices of every key; checkLinearizable versus checkPartitioned
##   E  like C, but every 10th op never returns (pending). Known limit: an
##      unlinearized pending op stays available forever, so the search state
##      grows with the number of pending ops (about quadratic overall).
## --check fails (exit 1) on a large regression, using only ratios measured
## in the same run (absolute times vary up to 2x between runs on one
## machine): C must scale at most 3x and E at most 4.5x when the history
## doubles, and partitioning must make D at least 5x faster.

import std/[hashes, monotimes, os, random, strutils, times]
import nimlinear
import nimlinear/models/[register, boundedqueue]

var exportDir = ""
var checkMode = false
for a in commandLineParams():
  if a.startsWith("--export:"): exportDir = a["--export:".len .. ^1]
  elif a == "--check": checkMode = true

# Test-only map model for D: 32 keys, partition by key.
type
  KvOp* = object
    key*, value*: int
    write*: bool
  KvRes* = object
    value*: int
  KvState = object
    vals: array[4, int]
  KvModel = object
func hash(s: KvState): Hash = hash(s.vals)
func step(m: typedesc[KvModel], s: KvState, op: KvOp): Expected[KvState, KvRes] {.raises: [].} =
  if op.write:
    var n = s
    n.vals[op.key] = op.value
    Expected[KvState, KvRes](next: n, res: KvRes())
  else:
    Expected[KvState, KvRes](next: s, res: KvRes(value: s.vals[op.key]))
func partition(m: typedesc[KvModel], op: KvOp): int {.raises: [].} = op.key

var failures: seq[string]

proc run[S, Op, Res](name, file: string, h: History[Op, Res], init: S, M: typedesc,
                     partitioned: static bool = false): float =
  let t0 = getMonoTime()
  when partitioned:
    let v = checkPartitioned(h, init, M, budget = 50_000_000)
  else:
    let v = checkLinearizable(h, init, M, budget = 50_000_000)
  result = (getMonoTime() - t0).inMicroseconds.float / 1000
  echo "  ", name.alignLeft(54), ($v.kind)[2 .. ^1].alignLeft(17), result.formatFloat(ffDecimal, 1).align(9), " ms"
  if exportDir.len > 0:
    createDir(exportDir)
    writeFile(exportDir / file & ".jsonl", h.toJsonLines())

proc shapeA(n: int): History[RegOp, RegRes] =
  var evs: seq[Event[RegOp, RegRes]]
  var s = 0
  for i in 1..n: inc s; evs.add invokeEvent[RegOp, RegRes](i, i, s, write(i))
  for i in 1..n: inc s; evs.add returnEvent[RegOp, RegRes](i, i, s, RegRes(ok: true))
  inc s; evs.add invokeEvent[RegOp, RegRes](n+1, 0, s, read())
  inc s; evs.add returnEvent[RegOp, RegRes](n+1, 0, s, RegRes(value: -1, ok: true))
  newHistory(evs)

proc shapeB(n: int): History[QueueOp, QueueRes] =
  var evs: seq[Event[QueueOp, QueueRes]]
  var s = 0
  for i in 1..n: inc s; evs.add invokeEvent[QueueOp, QueueRes](i, i, s, enqueue(i))
  for i in 1..n: inc s; evs.add returnEvent[QueueOp, QueueRes](i, i, s, okRes())
  for i in 1..n:
    let v = if i == n: 999 else: i
    inc s; evs.add invokeEvent[QueueOp, QueueRes](100+i, 0, s, dequeue())
    inc s; evs.add returnEvent[QueueOp, QueueRes](100+i, 0, s, valueRes(v))
  newHistory(evs)

proc shapeC(k: int, pendingEvery = 0): History[RegOp, RegRes] =
  ## 4 threads; per round all invoke, then all return in thread order, results
  ## from linearizing in thread order. With pendingEvery > 0, every
  ## pendingEvery-th op is a write that never returns (its thread then
  ## stops being used: a fresh thread id takes its place).
  var rng = initRand(1)
  var evs: seq[Event[RegOp, RegRes]]
  var s, val, id, count = 0
  var tids = [0, 1, 2, 3]
  var nextTid = 4
  for round in 0 ..< k:
    var ids: array[4, int]
    var calls: array[4, RegOp]
    var pend: array[4, bool]
    for t in 0..3:
      inc id; inc count; ids[t] = id; inc s
      pend[t] = pendingEvery > 0 and count mod pendingEvery == 0
      calls[t] = if pend[t] or rng.rand(1) == 1: write(rng.rand(0..3)) else: read()
      evs.add invokeEvent[RegOp, RegRes](id, tids[t], s, calls[t])
    for t in 0..3:
      if pend[t]:
        tids[t] = nextTid; inc nextTid     # applied or not: here, not applied
        continue
      var res = RegRes(ok: true)
      if calls[t].kind == rRead: res.value = val
      else: val = calls[t].value
      inc s; evs.add returnEvent[RegOp, RegRes](ids[t], tids[t], s, res)
  newHistory(evs)

proc shapeD(keys, writes: int): History[KvOp, KvRes] =
  var evs: seq[Event[KvOp, KvRes]]
  var s, id = 0
  for key in 0 ..< keys:
    let first = id + 1
    for w in 1..writes:
      inc id; inc s
      evs.add invokeEvent[KvOp, KvRes](id, id, s, KvOp(key: key, value: w, write: true))
    for x in first .. id:
      inc s; evs.add returnEvent[KvOp, KvRes](x, x, s, KvRes())
  for key in 0 ..< keys:
    inc id; inc s
    evs.add invokeEvent[KvOp, KvRes](id, id, s, KvOp(key: key))
    let v = if key == keys - 1: 99 else: writes
    inc s; evs.add returnEvent[KvOp, KvRes](id, id, s, KvRes(value: v))
  newHistory(evs)

echo "A. register: n writes all overlapping + read of a value never written"
var a: seq[float]
for n in [8, 12, 14, 16]:
  a.add run("n = " & $n, "register_A" & $n, shapeA(n), RegState(), RegisterModel)
echo "B. queue: n enqueues all overlapping + n dequeues, last one wrong"
var b: seq[float]
for n in [6, 8, 9]:
  b.add run("n = " & $n, "queue_B" & $n, shapeB(n), QueueState(capacity: 100), QueueModel)
echo "C. register: 4 threads x k ops, linearizable"
var c: seq[float]
for k in [2500, 5000, 10000]:
  c.add run("k = " & $k & " (" & $(4 * k) & " ops)", "register_C" & $k, shapeC(k), RegState(), RegisterModel)
echo "D. map: 3 keys x (4 overlapping writes), then a read per key, last one wrong"
let d = shapeD(3, 4)
let dWhole = run("checkLinearizable", "kv_D", d, KvState(), KvModel)
let dPart = run("checkPartitioned", "kv_D", d, KvState(), KvModel, partitioned = true)
echo "E. register: like C, every 10th op pending"
var e: seq[float]
for k in [250, 500, 1000]:
  e.add run("k = " & $k & " (" & $(4 * k) & " ops)", "register_E" & $k, shapeC(k, 10), RegState(), RegisterModel)

if checkMode:
  template need(cond: bool, msg: string) =
    if not cond: failures.add msg
  need(c[2] < max(3 * c[1], 5.0), "C does not scale linearly: " & $c)
  need(e[2] < max(4.5 * e[1], 5.0), "E grows faster than expected: " & $e)
  need(dPart * 5 < dWhole, "checkPartitioned not 5x faster than checkLinearizable on D")
  if failures.len > 0:
    echo "\nREGRESSION:"
    for f in failures: echo "  ", f
    quit 1
  echo "\ncheck: ok"
