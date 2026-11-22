## M5: stable verdict report (D-14, D-20).
import std/[os, strutils, unittest]
import nimlinear
import nimlinear/models/register

const
  goldenDir = currentSourcePath.parentDir / "golden"
  updateGolden = defined(nimlinearUpdateGolden)

proc golden(path, content: string) =
  let p = goldenDir / path
  if updateGolden:
    createDir(goldenDir)
    writeFile(p, content)
  check readFile(p) == content

type Ev = Event[RegOp, RegRes]

proc op(id, th, inv, ret: int, call: RegOp, res: RegRes): seq[Ev] =
  @[invokeEvent[RegOp, RegRes](id, th, inv, call), returnEvent[RegOp, RegRes](id, th, ret, res)]
func ok(v = 0): RegRes = RegRes(value: v, ok: true)

suite "report":
  test "linearizable snapshot":
    let v = checkLinearizable(newHistory(
      op(1, 0, 1, 4, write(1), ok()) & op(2, 1, 2, 3, read(), ok(1))),
      RegState(), RegisterModel)
    golden("register_linearizable.txt", v.report)

  test "not linearizable snapshot":
    let v = checkLinearizable(newHistory(
      op(1, 0, 1, 2, write(1), ok()) & op(2, 0, 3, 4, read(), ok(0))),
      RegState(), RegisterModel)
    golden("register_not_linearizable.txt", v.report)

  test "inconclusive snapshot":
    var evs: seq[Ev]
    for t in 0 ..< 4:
      evs.add op(t + 1, t, t + 1, 100 + t, write(t), ok())
    evs.add op(9, 0, 200, 201, read(), ok(42))
    let v = checkLinearizable(newHistory(evs), RegState(), RegisterModel, budget = 3)
    golden("register_inconclusive.txt", v.report)

  test "not linearizable snapshot with why":
    let v = checkLinearizable(newHistory(
      op(1, 0, 1, 4, cas(0, 1), ok()) & op(2, 1, 2, 3, cas(0, 2), ok())),
      RegState(), RegisterModel)
    check v.kind == vkNotLinearizable
    check "why: cas failed: current value 1" in v.report
    golden("register_cas_conflict.txt", v.report)

  test "report is deterministic across runs":
    let h = newHistory(op(1, 0, 1, 5, write(1), ok()) & op(2, 1, 2, 6, write(2), ok()) &
                       op(3, 2, 7, 8, read(), ok(2)))
    let r = checkLinearizable(h, RegState(), RegisterModel).report
    for _ in 0 ..< 5:
      check checkLinearizable(h, RegState(), RegisterModel).report == r

suite "timeline (M18)":
  test "not linearizable, with a pending op and a tick: snapshot":
    let evs = op(1, 0, 1, 4, write(1), ok()) & op(2, 1, 2, 3, read(), ok(0)) &
              @[tickEvent[RegOp, RegRes](9, 2, 5, read())] &
              @[invokeEvent[RegOp, RegRes](3, 1, 6, write(5))] &
              op(4, 0, 7, 8, read(), ok(7))
    let h = newHistory(evs)
    let v = checkLinearizable(h, RegState(), RegisterModel)
    golden("register_timeline.txt", report(v, h))

  test "linearizable: roles are positions in the order":
    let h = newHistory(op(1, 0, 1, 4, write(1), ok()) & op(2, 1, 2, 3, read(), ok(1)))
    let t = timeline(h, checkLinearizable(h, RegState(), RegisterModel))
    check "op 1 (thread 0, seq 1-4): write(1) -> (value: 0, ok: true)  [#1]" in t
    check "op 2 (thread 1, seq 2-3): read() -> (value: 1, ok: true)  [#2]" in t

  test "large histories skip the drawing":
    var evs: seq[Ev]
    for i in 1 .. 250: evs.add op(i, 0, 2 * i - 1, 2 * i, write(i), ok())
    let h = newHistory(evs)
    let t = timeline(h, checkLinearizable(h, RegState(), RegisterModel))
    check "drawing omitted" in t
    check "op 250 " in t

  test "HTML is standalone":
    let h = newHistory(op(1, 0, 1, 2, write(1), ok()) & op(2, 0, 3, 4, read(), ok(0)))
    let html = timelineHtml(h, checkLinearizable(h, RegState(), RegisterModel))
    check html.startsWith("<!doctype html>")
    check "<svg" in html
    check "http://" notin html.replace("http://www.w3.org/2000/svg", "")
    check "STUCK" in html
