## M4 memory measurement (CONTRIBUTING.md#memory-measurement-m4).
## nim c -r -d:release --mm:orc -d:nimlinearMeasure tests/measure/measure.nim
## Worst case for the search: Register histories with `threads` threads and
## `opsPerThread` ops each, all invoked before any returns (one big overlap),
## writes of distinct values plus reads of values that some order could explain,
## and a final read of a value never written, so the history is not
## linearizable and the checker must exhaust the reachable states.
import std/[monotimes, times, strutils]
import nimlinear
import nimlinear/models/register

proc build(threads, opsPerThread: int): History[RegOp, RegRes] =
  # Staggered threads: all threads invoke op 0, then each thread in turn
  # returns op k and invokes op k+1. Ops of different threads overlap across
  # neighbouring rounds. Every op is a write of a distinct value; the final
  # read returns a value never written, so the checker must exhaust the
  # reachable (linearized set, last value) configurations.
  var evs: seq[Event[RegOp, RegRes]]
  var s = 0
  proc opId(t, k: int): int = k * threads + t + 1
  for t in 0 ..< threads:
    inc s
    evs.add invokeEvent[RegOp, RegRes](opId(t, 0), t, s, write(opId(t, 0)))
  for k in 0 ..< opsPerThread:
    for t in 0 ..< threads:
      inc s
      evs.add returnEvent[RegOp, RegRes](opId(t, k), t, s, RegRes(ok: true))
      if k + 1 < opsPerThread:
        inc s
        evs.add invokeEvent[RegOp, RegRes](opId(t, k + 1), t, s, write(opId(t, k + 1)))
  let last = threads * opsPerThread + 1
  inc s
  evs.add invokeEvent[RegOp, RegRes](last, 0, s, read())
  inc s
  evs.add returnEvent[RegOp, RegRes](last, 0, s, RegRes(value: -1, ok: true))
  newHistory(evs)

for (t, o) in [(2, 4), (3, 5), (4, 8)]:
  let h = build(t, o)
  let t0 = getMonoTime()
  let v = checkLinearizable(h, RegState(), RegisterModel, budget = 10_000_000)
  let ms = (getMonoTime() - t0).inMicroseconds.float / 1000
  echo t, " threads x ", o, " ops (+1 final read): ", v.kind, " time=", ms.formatFloat(ffDecimal, 2), "ms"
