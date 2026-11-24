## M16: shrink keeps the failure, never grows, and is deterministic.
import std/[os, times, unittest]
import nimlinear
import nimlinear/models/register

type Ev = Event[RegOp, RegRes]
proc op(id, th, inv, ret: int, call: RegOp, res: RegRes): seq[Ev] =
  @[invokeEvent[RegOp, RegRes](id, th, inv, call), returnEvent[RegOp, RegRes](id, th, ret, res)]
func ok(v = 0): RegRes = RegRes(value: v, ok: true)
proc ids(h: History[RegOp, RegRes]): seq[int] =
  for e in h.events:
    if e.kind == ekInvoke: result.add int(e.op)

suite "shrink":
  test "keeps only what the failure needs":
    # Noise on threads 1 and 2; the bug is write(1) then a stale read(0).
    let evs = op(1, 0, 1, 2, write(1), ok()) &
              op(2, 1, 3, 4, read(), ok(1)) &
              op(3, 2, 5, 6, write(3), ok()) &
              op(4, 2, 7, 8, read(), ok(3)) &
              op(5, 0, 9, 10, read(), ok(1)) &
              op(6, 1, 11, 12, read(), ok(0))      # stale: nobody wrote 0 after 3
    let h = newHistory(evs)
    check checkLinearizable(h, RegState(), RegisterModel).kind == vkNotLinearizable
    let s = shrink(h, RegState(), RegisterModel)
    check checkLinearizable(s, RegState(), RegisterModel).kind == vkNotLinearizable
    check s.events.len < h.events.len
    # The first violation: read() -> 1 (op 5) after write(3) returned. Not just
    # "a read of 1 with nothing written": write(3) must stay, so the model
    # still expects 3 from op 5.
    let w = checkLinearizable(s, RegState(), RegisterModel).witness
    check w.stuck == OpId(5)
    check w.alternatives[^1].expected == ok(3)
    check ids(s) == @[3, 5]
    check shrink(h, RegState(), RegisterModel).toJsonLines == s.toJsonLines
    # R12: a generous timeout gives the same result; an expired one returns
    # a history that still fails, no larger than the input.
    check shrink(h, RegState(), RegisterModel, timeout = initDuration(seconds = 30)).toJsonLines == s.toJsonLines
    let t = shrink(h, RegState(), RegisterModel, timeout = initDuration(nanoseconds = 1))
    check t.events.len <= h.events.len
    check checkLinearizable(t, RegState(), RegisterModel).kind == vkNotLinearizable

  test "a linearizable history is returned unchanged":
    let h = newHistory(op(1, 0, 1, 2, write(1), ok()) & op(2, 0, 3, 4, read(), ok(1)))
    check shrink(h, RegState(), RegisterModel).events == h.events

  test "fixture: stale read":
    const path = currentSourcePath.parentDir / "fixtures" / "register_stale_read.jsonl"
    let h = parseJsonLines[RegOp, RegRes](readFile(path))
    let s = shrink(h, RegState(), RegisterModel)
    check s.events.len <= h.events.len
    check checkLinearizable(s, RegState(), RegisterModel).kind == vkNotLinearizable
