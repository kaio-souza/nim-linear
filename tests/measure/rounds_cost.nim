## R6/R7 measurements (docs/MEASUREMENTS.md#round-harness-cost):
##   nim c -r -d:release --mm:orc --threads:on tests/measure/rounds_cost.nim
## R6: where the time of a round goes (thread create/join vs check).
## R7: recorder overhead per operation, and its effect on the interleaving,
## measured as the rate of lost updates of a racy counter with and without
## recording (the final value is checked without the checker in both cases).
import std/[atomics, monotimes, random, strformat, times]
import nimlinear

type
  COp = object
    inc: bool
  CRes = object
    value: int
  CState = object
    value: int
  CModel = object
  Counter = object
    v: Atomic[int]

func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
  if op.inc: Expected[CState, CRes](next: CState(value: s.value + 1), res: CRes(value: s.value + 1))
  else: Expected[CState, CRes](next: s, res: CRes(value: s.value))

proc setup(c: var Counter) = discard
proc genOp(r: var Rand, thread, index: int): COp = COp(inc: r.rand(3) > 0)
proc exec(c: ptr Counter, op: COp): CRes {.gcsafe.} =
  if op.inc: CRes(value: c.v.fetchAdd(1) + 1) else: CRes(value: c.v.load)

proc ms(d: Duration): float = d.inNanoseconds.float / 1e6

# ---- R6 ---------------------------------------------------------------
proc empty(x: int) {.thread.} = discard

proc r6(rounds, threads, ops: int) =
  let cfg = RoundsConfig(threads: threads, rounds: rounds, opsPerThread: ops)
  var t0 = getMonoTime()
  var hs: seq[History[COp, CRes]]
  for r in 1 .. rounds: hs.add runRound(cfg, r, setup, genOp, exec)
  let tRound = getMonoTime() - t0
  t0 = getMonoTime()
  for h in hs: doAssert checkLinearizable(h, CState(), CModel).kind == vkLinearizable
  let tCheck = getMonoTime() - t0
  t0 = getMonoTime()
  var ths = newSeq[Thread[int]](threads)
  for r in 1 .. rounds:
    for t in 0 ..< threads: createThread(ths[t], empty, t)
    joinThreads(ths)
  let tThreads = getMonoTime() - t0
  echo &"R6 {threads} threads x {ops} ops, {rounds} rounds: " &
       &"record {tRound.ms/rounds.float*1000:.1f} us/round " &
       &"(empty create+join {tThreads.ms/rounds.float*1000:.1f} us), " &
       &"check {tCheck.ms/rounds.float*1000:.1f} us/round; " &
       &"create+join = {tThreads.ms/(tRound.ms+tCheck.ms)*100:.0f}% of record+check"

# ---- R7 ---------------------------------------------------------------
const opsPerThread = 2000
var start: Atomic[bool]
var shared: Atomic[int]
var rec: Recorder[COp, CRes]

proc racyInc(): CRes =
  let x = shared.load(moRelaxed)
  shared.store(x + 1, moRelaxed)
  CRes(value: x + 1)

proc plainW(t: int) {.thread.} =
  while not start.load: discard
  for _ in 0 ..< opsPerThread: discard racyInc()

proc recW(t: int) {.thread.} =
  while not start.load: discard
  {.cast(gcsafe).}:
    for _ in 0 ..< opsPerThread: discard rec.record(t, COp(inc: true)): racyInc()

proc r7(trials, threads: int) =
  for recorded in [false, true]:
    var lost = 0
    var total = Duration()
    for _ in 1 .. trials:
      shared.store(0); start.store(false)
      if recorded: rec = newRecorder[COp, CRes](threads)
      var ths = newSeq[Thread[int]](threads)
      for t in 0 ..< threads: createThread(ths[t], (if recorded: recW else: plainW), t)
      let t0 = getMonoTime()
      start.store(true)
      joinThreads(ths)
      total += getMonoTime() - t0
      lost += threads * opsPerThread - shared.load
    let n = trials * threads * opsPerThread
    echo &"R7 {(if recorded: \"recorded\" else: \"plain   \")}: {total.ms*1e6/n.float:.1f} ns/op, " &
         &"lost updates {lost.float/n.float*100:.2f}% of increments"

r6(2000, 3, 4)
r6(2000, 8, 4)
r7(50, 3)
