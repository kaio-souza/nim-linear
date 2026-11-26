## P8: histories whose memo window spans several 64-bit words. Pending
## operations hold `f` back, so later operations land far into the window.
## Compiled with -d:nimlinearDebug (twidewindow.nims): at every step the
## checker asserts that `(f, window)` and `minRet` match the full bitset.
import std/unittest
import nimlinear
import nimlinear/models/register
import ./oracle/oracle

type Ev = Event[RegOp, RegRes]
func ok(v = 0): RegRes = RegRes(value: v, ok: true)

proc wide(pending, pairs: int, lastRead: int): History[RegOp, RegRes] =
  ## `pending` writes of 1000+k that never return, then one thread doing
  ## `pairs` sequential write(i) / read() -> i, then a final read -> lastRead.
  var evs: seq[Ev]
  var s = 0
  var id = 0
  for k in 0 ..< pending:
    inc s; inc id
    evs.add invokeEvent[RegOp, RegRes](id, k, s, write(1000 + k))
  let t = pending
  for i in 1 .. pairs:
    inc s; inc id
    evs.add invokeEvent[RegOp, RegRes](id, t, s, write(i))
    inc s
    evs.add returnEvent[RegOp, RegRes](id, t, s, ok())
    inc s; inc id
    evs.add invokeEvent[RegOp, RegRes](id, t, s, read())
    inc s
    evs.add returnEvent[RegOp, RegRes](id, t, s, ok(i))
  inc s; inc id
  evs.add invokeEvent[RegOp, RegRes](id, t, s, read())
  inc s
  evs.add returnEvent[RegOp, RegRes](id, t, s, ok(lastRead))
  newHistory(evs)

suite "wide memo window (P8)":
  for pending in [1, 63, 64, 65, 130]:
    test "pending = " & $pending & ": linearizable, wrong read rejected, pending value accepted":
      let good = wide(pending, 80, 80)
      let v1 = checkLinearizable(good, RegState(), RegisterModel)
      check v1.kind == vkLinearizable
      check verdictContentError(good, RegState(), RegisterModel, v1) == ""

      # Nobody wrote 999. Rejecting it means trying every subset of the
      # pending writes (exponential, D-25), so with many of them the budget
      # runs out first: it must not be accepted, and with few it is rejected.
      let bad = wide(pending, 80, 999)
      let v2 = checkLinearizable(bad, RegState(), RegisterModel, budget = 20_000)
      check v2.kind != vkLinearizable
      if pending == 1: check v2.kind == vkNotLinearizable
      check verdictContentError(bad, RegState(), RegisterModel, v2) == ""

      let late = wide(pending, 80, 1000 + pending - 1)   # a pending write took effect last
      let v3 = checkLinearizable(late, RegState(), RegisterModel)
      check v3.kind == vkLinearizable
      check verdictContentError(late, RegState(), RegisterModel, v3) == ""
