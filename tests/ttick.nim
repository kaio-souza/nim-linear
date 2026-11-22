## M10: time as an event. `ekTick` validation, JSON, checker semantics, and
## Recorder.tick (with --threads:on).
import std/unittest
import nimlinear
import ./oracle/kvttl

type Ev = Event[KvOp, KvRes]

proc op(id, th, inv, ret: int, call: KvOp, res = KvRes()): seq[Ev] =
  @[invokeEvent[KvOp, KvRes](id, th, inv, call), returnEvent[KvOp, KvRes](id, th, ret, res)]
proc tk(id, sq: int): Ev = tickEvent[KvOp, KvRes](id, 9, sq, tick())
func r(v: int): KvRes = KvRes(value: v)
proc ids(xs: seq[OpId]): seq[int] =
  for x in xs: result.add int(x)
proc verify(evs: seq[Ev]): Verdict[KvOp, KvRes] =
  checkLinearizable(newHistory(evs), initKv(), KvModel)

suite "tick: history":
  test "a tick has no return":
    expect ArgumentError:
      discard newHistory(@[tk(1, 1), returnEvent[KvOp, KvRes](1, 9, 2, KvRes())])

  test "a tick id cannot be reused":
    expect ArgumentError:
      discard newHistory(@[tk(1, 1), tk(1, 2)])
    expect ArgumentError:
      discard newHistory(@[tk(1, 1)] & op(1, 0, 2, 3, get(0)))

  test "a tick does not open its thread":
    let h = newHistory(@[tk(1, 1), tk(2, 2)] & op(3, 9, 3, 4, get(0)))
    check h.events.len == 4

  test "JSON round trip":
    let h = newHistory(op(1, 0, 1, 3, put(0, 5)) & @[tk(2, 2)])
    let s = h.toJsonLines()
    check s == """{"nimlinear":1}
{"kind":"invoke","op":1,"thread":0,"seq":1,"payload":{"kind":"kPut","key":0,"value":5}}
{"kind":"tick","op":2,"thread":9,"seq":2,"payload":{"kind":"kTick","key":0,"value":0}}
{"kind":"return","op":1,"thread":0,"seq":3,"payload":{"value":0}}
"""
    check parseJsonLines[KvOp, KvRes](s).toJsonLines() == s

suite "tick: checker":
  test "ticks are linearized at their seq":
    let v = verify(op(1, 0, 1, 2, put(0, 5)) & @[tk(2, 3), tk(3, 4)] & op(4, 0, 5, 6, get(0), r(-1)))
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2, 3, 4]

  test "a read after the entry expired cannot see the value":
    let v = verify(op(1, 0, 1, 2, put(0, 5)) & @[tk(2, 3), tk(3, 4)] & op(4, 0, 5, 6, get(0), r(5)))
    check v.kind == vkNotLinearizable
    check ids(v.witness.prefix) == @[1, 2, 3]
    check int(v.witness.stuck) == 4

  test "a read before any tick cannot see the entry expired":
    let v = verify(op(1, 0, 1, 2, put(0, 5)) & op(2, 0, 3, 4, get(0), r(-1)) & @[tk(3, 5), tk(4, 6)])
    check v.kind == vkNotLinearizable
    check int(v.witness.stuck) == 2

  test "a read overlapping the ticks may see either":
    for want in [5, -1]:
      let v = verify(op(1, 0, 1, 2, put(0, 5)) & @[invokeEvent[KvOp, KvRes](2, 0, 3, get(0)),
                     tk(3, 4), tk(4, 5), returnEvent[KvOp, KvRes](2, 0, 6, r(want))])
      check v.kind == vkLinearizable
    let bad = verify(op(1, 0, 1, 2, put(0, 5)) & @[invokeEvent[KvOp, KvRes](2, 0, 3, get(0)),
                     tk(3, 4), tk(4, 5), returnEvent[KvOp, KvRes](2, 0, 6, r(7))])
    check bad.kind == vkNotLinearizable

  test "a tick's result is not compared":
    # step returns KvRes() for tick; nothing in the history to compare with.
    check verify(@[tk(1, 1)]).kind == vkLinearizable

when compileOption("threads"):
  import nimlinear/recorder

  suite "tick: recorder":
    test "tick takes one seq and keeps ids unique":
      var rec = newRecorder[KvOp, KvRes](threads = 2)
      let a = rec.begin(0, put(0, 1))
      let t = rec.tick(1, tick())
      rec.finish(a, KvRes())
      let t2 = rec.tick(1, tick())
      let h = rec.snapshot()
      check h.events.len == 4
      check h.events[1].kind == ekTick
      check h.events[1].op == t
      check h.events[1].seqNo == SeqNo(2)
      check t != t2 and t != a
      check checkLinearizable(h, initKv(), KvModel).kind == vkLinearizable

    test "tick with an invalid thread is misuse":
      var rec = newRecorder[KvOp, KvRes](threads = 1)
      discard rec.tick(5, tick())
      expect ArgumentError:
        discard rec.snapshot()
