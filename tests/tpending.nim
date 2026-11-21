## M3: pending operations (D-08) and the EventFlag lost-wakeup fixture.
import std/[os, unittest]
import nimlinear
import nimlinear/models/eventflag

type Ev = Event[EventOp, EventRes]

proc op(id, th, inv, ret: int, call: EventOp, res: EventRes): seq[Ev] =
  @[invokeEvent[EventOp, EventRes](id, th, inv, call),
    returnEvent[EventOp, EventRes](id, th, ret, res)]
proc pending(id, th, inv: int, call: EventOp): seq[Ev] =
  @[invokeEvent[EventOp, EventRes](id, th, inv, call)]

proc verify(evs: seq[Ev]): Verdict[EventOp, EventRes] =
  checkLinearizable(newHistory(evs), EventState(), EventFlagModel)

proc ids(xs: seq[OpId]): seq[int] =
  for x in xs: result.add int(x)

suite "EventFlag: lost wakeup":
  test "fixture: wait times out after a completed signal":
    const path = currentSourcePath.parentDir / "fixtures" / "eventflag_lost_wakeup.jsonl"
    let h = parseJsonLines[EventOp, EventRes](readFile(path))
    let v = checkLinearizable(h, EventState(), EventFlagModel)
    check v.kind == vkNotLinearizable
    check ids(v.witness.prefix) == @[1]
    check int(v.witness.stuck) == 2
    check v.witness.alternatives.len == 1
    check v.witness.alternatives[0].expected == signaled()
    check v.witness.alternatives[0].observed == timedOut()
    check h.toJsonLines() == readFile(path)

  test "wait that never returns is pending, not a violation":
    let v = verify(op(1, 0, 1, 2, signal(), ack()) & pending(2, 1, 3, wait()))
    check v.kind == vkLinearizable

  test "wait concurrent with signal may time out":
    let v = verify(op(1, 0, 1, 4, signal(), ack()) & op(2, 1, 2, 3, wait(), timedOut()))
    check v.kind == vkLinearizable
    check ids(v.order) == @[2, 1]

  test "one signal, two waiters: only one may be signaled":
    let ok = verify(op(1, 0, 1, 2, signal(), ack()) &
                    op(2, 1, 3, 6, wait(), signaled()) & op(3, 2, 4, 5, wait(), timedOut()))
    check ok.kind == vkLinearizable
    let bad = verify(op(1, 0, 1, 2, signal(), ack()) &
                     op(2, 1, 3, 6, wait(), signaled()) & op(3, 2, 4, 5, wait(), signaled()))
    check bad.kind == vkNotLinearizable

suite "pending operations: both possibilities (D-08)":
  test "pending signal treated as applied":
    let v = verify(pending(1, 0, 1, signal()) & op(2, 1, 2, 3, wait(), signaled()))
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2]

  test "pending signal treated as not applied":
    let v = verify(pending(1, 0, 1, signal()) & op(2, 1, 2, 3, wait(), timedOut()))
    check v.kind == vkLinearizable
    check ids(v.order) == @[2]

  test "pending op invoked after a return cannot explain it":
    # The signal is invoked only after the wait returned, so it cannot be
    # linearized before it: the wait's `signaled` has no explanation.
    let v = verify(op(1, 1, 1, 2, wait(), signaled()) & pending(2, 0, 3, signal()))
    check v.kind == vkNotLinearizable
    check int(v.witness.stuck) == 1

  test "a pending wait may consume the signal":
    let v = verify(op(1, 0, 1, 2, signal(), ack()) & pending(2, 1, 3, wait()) &
                   op(3, 2, 4, 5, wait(), timedOut()))
    # The pending wait (op 2) consumes the signal first; then op 3 times out.
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2, 3]
