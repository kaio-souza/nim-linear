## Negative compilation test (D-16): a `step` that can raise does not compile
## with checkLinearizable, which is {.raises: [].}. R8: neither does a `step`
## with side effects (a global), unless -d:nimlinearImpureModel.
import std/[hashes, unittest]
import nimlinear

type
  BadState = object
    v: int
  BadModel = object
  GoodModel = object
  ImpureModel = object
  PlainProcModel = object

var calls = 0

proc step(m: typedesc[BadModel], s: BadState, op: int): Expected[BadState, int] =
  if op < 0: raise newException(ValueError, "negative op")
  Expected[BadState, int](next: s, res: op)

func step(m: typedesc[GoodModel], s: BadState, op: int): Expected[BadState, int] {.raises: [].} =
  Expected[BadState, int](next: s, res: op)

proc step(m: typedesc[ImpureModel], s: BadState, op: int): Expected[BadState, int] {.raises: [].} =
  inc calls                      # side effect: the checker calls step in many orders
  Expected[BadState, int](next: s, res: op)

proc step(m: typedesc[PlainProcModel], s: BadState, op: int): Expected[BadState, int] {.raises: [].} =
  Expected[BadState, int](next: s, res: op)   # a `proc` without side effects is fine

func hash(s: BadState): Hash = hash(s.v)

let h = newHistory(newSeq[Event[int, int]]())

suite "raises contract":
  test "a step that raises does not compile":
    check not compiles(checkLinearizable(h, BadState(), BadModel))
  test "a step without exceptions compiles":
    check compiles(checkLinearizable(h, BadState(), GoodModel))

suite "purity contract (R8)":
  test "a step with side effects does not compile":
    check not compiles(checkLinearizable(h, BadState(), ImpureModel))
  test "a proc step without side effects compiles":
    check compiles(checkLinearizable(h, BadState(), PlainProcModel))
