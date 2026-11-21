## Negative compilation test (D-16): a `step` that can raise does not compile
## with checkLinearizable, which is {.raises: [].}.
import std/[hashes, unittest]
import nimlinear

type
  BadState = object
    v: int
  BadModel = object
  GoodModel = object

proc step(m: typedesc[BadModel], s: BadState, op: int): Expected[BadState, int] =
  if op < 0: raise newException(ValueError, "negative op")
  Expected[BadState, int](next: s, res: op)

func step(m: typedesc[GoodModel], s: BadState, op: int): Expected[BadState, int] {.raises: [].} =
  Expected[BadState, int](next: s, res: op)

func hash(s: BadState): Hash = hash(s.v)

let h = newHistory(newSeq[Event[int, int]]())

suite "raises contract":
  test "a step that raises does not compile":
    check not compiles(checkLinearizable(h, BadState(), BadModel))
  test "a step without exceptions compiles":
    check compiles(checkLinearizable(h, BadState(), GoodModel))
