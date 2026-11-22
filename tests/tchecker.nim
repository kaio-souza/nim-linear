import std/[os, times, unittest]
import nimlinear
import nimlinear/models/register

type Ev = Event[RegOp, RegRes]

# Shortcut: operation = (op, thread, invoke seq, return seq, call, result).
proc op(id, th, inv, ret: int, call: RegOp, res: RegRes): seq[Ev] =
  @[invokeEvent[RegOp, RegRes](id, th, inv, call), returnEvent[RegOp, RegRes](id, th, ret, res)]
func ok(v = 0): RegRes = RegRes(value: v, ok: true)
func failed(): RegRes = RegRes(ok: false)

proc verify(evs: seq[Ev], init = 0): Verdict[RegOp, RegRes] =
  checkLinearizable(newHistory(evs), RegState(value: init), RegisterModel)

proc ids(xs: seq[OpId]): seq[int] =
  for x in xs: result.add int(x)

suite "checker: linearizable":
  test "empty history":
    let v = verify(@[])
    check v.kind == vkLinearizable
    check v.order.len == 0

  test "sequential":
    let v = verify(op(1, 0, 1, 2, write(1), ok()) & op(2, 0, 3, 4, read(), ok(1)))
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2]

  test "read concurrent with write sees the old value":
    let v = verify(op(1, 0, 1, 4, write(1), ok()) & op(2, 1, 2, 3, read(), ok(0)))
    check v.kind == vkLinearizable
    check ids(v.order) == @[2, 1]

  test "read concurrent with write sees the new value":
    let v = verify(op(1, 0, 1, 4, write(1), ok()) & op(2, 1, 2, 3, read(), ok(1)))
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2]

  test "deterministic order: candidates by invoke seq (D-20)":
    # Two concurrent writes followed by a read that sees 2: write(2) must be
    # the last write, so only the order [1, 2, 3] works.
    let evs = op(1, 0, 1, 5, write(1), ok()) & op(2, 1, 2, 6, write(2), ok()) &
              op(3, 2, 7, 8, read(), ok(2))
    let v = verify(evs)
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2, 3]
    # Two concurrent reads of the same value: several orders work; the one
    # chosen always puts the lowest invoke seq first.
    let v2 = verify(op(1, 0, 1, 4, read(), ok()) & op(2, 1, 2, 3, read(), ok()))
    check ids(v2.order) == @[1, 2]
    for _ in 0 ..< 3:
      check ids(verify(evs).order) == @[1, 2, 3]

  test "concurrent cas, one wins":
    let v = verify(op(1, 0, 1, 4, cas(0, 1), ok()) & op(2, 1, 2, 3, cas(0, 2), failed()))
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2]

  test "a pending op may have been applied":
    let evs = @[invokeEvent[RegOp, RegRes](1, 0, 1, write(5))] & op(2, 1, 2, 3, read(), ok(5))
    let v = verify(evs)
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2]

  test "a pending op may not have been applied":
    let evs = @[invokeEvent[RegOp, RegRes](1, 0, 1, write(5))] & op(2, 1, 2, 3, read(), ok(0))
    let v = verify(evs)
    check v.kind == vkLinearizable
    check ids(v.order) == @[2]

suite "checker: not linearizable":
  test "stale read after the write returned":
    let v = verify(op(1, 0, 1, 2, write(1), ok()) & op(2, 0, 3, 4, read(), ok(0)))
    check v.kind == vkNotLinearizable
    check ids(v.witness.prefix) == @[1]
    check int(v.witness.stuck) == 2
    check v.witness.alternatives.len == 1
    check v.witness.alternatives[0].expected == ok(1)
    check v.witness.alternatives[0].observed == ok(0)

  test "two cas succeed with the same expected value":
    let v = verify(op(1, 0, 1, 4, cas(0, 1), ok()) & op(2, 1, 2, 3, cas(0, 2), ok()))
    check v.kind == vkNotLinearizable
    check ids(v.witness.prefix) == @[1]
    check int(v.witness.stuck) == 2
    check v.witness.alternatives[0].why == "cas failed: current value 1"

  test "value nobody wrote":
    let v = verify(op(1, 0, 1, 4, write(1), ok()) & op(2, 1, 2, 3, read(), ok(7)))
    check v.kind == vkNotLinearizable
    check v.witness.prefix.len == 1   # [1]; a depth tie keeps the first one
    check ids(v.witness.prefix) == @[1]

  test "JSON fixture: stale read":
    const path = currentSourcePath.parentDir / "fixtures" / "register_stale_read.jsonl"
    let h = parseJsonLines[RegOp, RegRes](readFile(path))
    let v = checkLinearizable(h, RegState(value: 0), RegisterModel)
    check v.kind == vkNotLinearizable
    check ids(v.witness.prefix) == @[1, 2]
    check int(v.witness.stuck) == 3
    check v.witness.stuckCall == read()
    check v.witness.stuckRes == ok(0)

suite "checker: budget":
  test "a low budget gives vkInconclusive":
    var evs: seq[Ev]
    for t in 0 ..< 4:
      evs.add op(t + 1, t, t + 1, 100 + t, write(t), ok())
    evs.add op(9, 0, 200, 201, read(), ok(42))
    let h = newHistory(evs)
    let v = checkLinearizable(h, RegState(), RegisterModel, budget = 3)
    check v.kind == vkInconclusive
    check v.budget == 3
    check v.statesExplored == 3
    check checkLinearizable(h, RegState(), RegisterModel).kind == vkNotLinearizable

suite "checker: timeout (M20)":
  test "an expired timeout gives vkInconclusive with timedOut":
    # Deterministic: a 1 ns timeout has always expired by the first check,
    # which happens at 256 visited states. The history (20 fully overlapping
    # writes, then an impossible read) has far more than 256 states.
    var evs: seq[Ev]
    for i in 1 .. 20:
      evs.add invokeEvent[RegOp, RegRes](i, i, i, write(i))
    for i in 1 .. 20:
      evs.add returnEvent[RegOp, RegRes](i, i, 20 + i, ok())
    evs.add op(21, 0, 41, 42, read(), ok(-1))
    let v = checkLinearizable(newHistory(evs), RegState(), RegisterModel,
                              budget = high(int), timeout = initDuration(nanoseconds = 1))
    check v.kind == vkInconclusive
    check v.timedOut
    check v.statesExplored == 256

  test "no timeout by default; budget exhaustion is not a timeout":
    var evs: seq[Ev]
    for t in 0 ..< 4:
      evs.add op(t + 1, t, t + 1, 100 + t, write(t), ok())
    evs.add op(9, 0, 200, 201, read(), ok(42))
    let v = checkLinearizable(newHistory(evs), RegState(), RegisterModel, budget = 3)
    check v.kind == vkInconclusive
    check not v.timedOut

suite "checker: review fixes":
  test "budget below 1 is treated as 1: statesExplored never exceeds it":
    let v = checkLinearizable(newHistory(op(1, 0, 1, 2, write(1), ok()) & op(2, 0, 3, 4, read(), ok(1))),
                              RegState(), RegisterModel, budget = 0)
    check v.kind == vkInconclusive
    check v.statesExplored <= v.budget
    check v.budget == 1
