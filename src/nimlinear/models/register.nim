## `Register` model: read, write, cas. See docs/MODELS.md#register.

import std/[hashes, json, random]
import ../model

type
  RegOpKind* = enum rRead, rWrite, rCas
  RegOp* = object
    case kind*: RegOpKind
    of rRead: discard
    of rWrite: value*: int
    of rCas: expected*, desired*: int
  RegRes* = object
    value*: int    ## read: value read; write/cas: 0
    ok*: bool      ## cas: swapped?; read/write: true
  RegState* = object
    value*: int
  RegisterModel* = object

func read*(): RegOp = RegOp(kind: rRead)
func write*(v: int): RegOp = RegOp(kind: rWrite, value: v)
func cas*(expected, desired: int): RegOp = RegOp(kind: rCas, expected: expected, desired: desired)

func `==`*(a, b: RegOp): bool =
  if a.kind != b.kind: return false
  case a.kind
  of rRead: true
  of rWrite: a.value == b.value
  of rCas: a.expected == b.expected and a.desired == b.desired

func `$`*(op: RegOp): string =
  case op.kind
  of rRead: "read()"
  of rWrite: "write(" & $op.value & ")"
  of rCas: "cas(" & $op.expected & ", " & $op.desired & ")"

func hash*(s: RegState): Hash = hash(s.value)

func step*(m: typedesc[RegisterModel], s: RegState, op: RegOp):
    Expected[RegState, RegRes] {.raises: [].} =
  case op.kind
  of rRead: Expected[RegState, RegRes](next: s, res: RegRes(value: s.value, ok: true))
  of rWrite: Expected[RegState, RegRes](next: RegState(value: op.value), res: RegRes(ok: true))
  of rCas:
    if s.value == op.expected:
      Expected[RegState, RegRes](next: RegState(value: op.desired), res: RegRes(ok: true))
    else:
      Expected[RegState, RegRes](next: s, res: RegRes(ok: false),
        why: "cas failed: current value " & $s.value)

proc toPayload*(x: RegOp): JsonNode =
  case x.kind
  of rRead: %*{"kind": "read"}
  of rWrite: %*{"kind": "write", "value": x.value}
  of rCas: %*{"kind": "cas", "expected": x.expected, "desired": x.desired}

proc fromPayload*(n: JsonNode, t: typedesc[RegOp]): RegOp =
  case n["kind"].getStr
  of "read": read()
  of "write": write(n["value"].getInt)
  of "cas": cas(n["expected"].getInt, n["desired"].getInt)
  else: raise newException(ValueError, "unknown RegOp: " & $n)

proc randomRegisterOp*(rng: var Rand, thread, index: int, values = 3): RegOp =
  ## Default generator (P3): read 40%, write 40% (values unique per thread
  ## and index), cas 20%. A cas expects either a value in `0 ..< values`
  ## or one this thread wrote earlier, so some cas can succeed.
  case rng.rand(4)
  of 0, 1: read()
  of 2, 3: write(thread * 1000 + index + 1)
  else:
    let exp = if index > 0 and rng.rand(1) == 0: thread * 1000 + rng.rand(index - 1) + 1
              else: rng.rand(values - 1)
    cas(exp, thread * 1000 + index + 1)

proc genRegisterOp*(rng: var Rand, thread, index: int): RegOp =
  ## `randomRegisterOp` in the signature `runRounds` expects.
  randomRegisterOp(rng, thread, index)
