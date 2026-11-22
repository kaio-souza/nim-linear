import std/unittest
import nimlinear

type
  RegOp = object
    write: bool
    value: int
  RegRes = object
    value: int

proc inv(op, th, sq: int, v = 0): Event[RegOp, RegRes] =
  invokeEvent[RegOp, RegRes](op, th, sq, RegOp(write: true, value: v))
proc ret(op, th, sq: int, v = 0): Event[RegOp, RegRes] =
  returnEvent[RegOp, RegRes](op, th, sq, RegRes(value: v))

template rejects(evs: seq[Event[RegOp, RegRes]]) =
  expect ArgumentError:
    discard newHistory(evs)

suite "newHistory":
  test "empty history is valid":
    check newHistory(newSeq[Event[RegOp, RegRes]]()).events.len == 0

  test "sorts by seq regardless of input order":
    let h = newHistory(@[ret(1, 0, 3), inv(2, 1, 2), inv(1, 0, 1), ret(2, 1, 4)])
    var seqs: seq[int]
    for e in h.events: seqs.add int(e.seqNo)
    check seqs == @[1, 2, 3, 4]

  test "pending op is accepted":
    check newHistory(@[inv(1, 0, 1), inv(2, 1, 2), ret(2, 1, 3)]).events.len == 3

  test "repeated seq":
    rejects @[inv(1, 0, 1), inv(2, 1, 1)]
  test "two invokes for the same op":
    rejects @[inv(1, 0, 1), ret(1, 0, 2), inv(1, 0, 3)]
  test "two returns for the same op":
    rejects @[inv(1, 0, 1), ret(1, 0, 2), ret(1, 0, 3)]
  test "return without invoke":
    rejects @[ret(1, 0, 1)]
  test "return before invoke":
    rejects @[ret(1, 0, 1), inv(1, 0, 2)]
  test "return on a different thread":
    rejects @[inv(1, 0, 1), ret(1, 1, 2)]
  test "two open operations on the same thread":
    rejects @[inv(1, 0, 1), inv(2, 0, 2)]
  test "a pending op blocks its thread":
    rejects @[inv(1, 0, 1), inv(2, 0, 5), ret(2, 0, 6)]

suite "History is read-only (M24)":
  test "events cannot be assigned or mutated from outside":
    var h = newHistory[int, int](@[invokeEvent[int, int](1, 0, 1, 5)])
    check h.events.len == 1
    check not compiles(h.events = @[])
    check not compiles(h.events.add invokeEvent[int, int](2, 1, 2, 6))
    check not compiles(History[int, int](evs: @[]))
