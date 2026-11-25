## `Stack` model: push, pop (LIFO), optionally bounded. See docs/MODELS.md#stack.

import std/[hashes, json, random]
import ../model

type
  StackOpKind* = enum sPush, sPop
  StackOp* = object
    kind*: StackOpKind
    value*: int        ## push only; 0 otherwise
  StackResKind* = enum srOk, srFull, srValue, srEmpty
  StackRes* = object
    kind*: StackResKind
    value*: int        ## srValue only; 0 otherwise
  StackState* = object
    items*: seq[int]   ## bottom first
    capacity*: int     ## 0 = unbounded
  StackModel* = object

func push*(v: int): StackOp = StackOp(kind: sPush, value: v)
func pop*(): StackOp = StackOp(kind: sPop)
func pushed*(): StackRes = StackRes(kind: srOk)
func full*(): StackRes = StackRes(kind: srFull)
func popped*(v: int): StackRes = StackRes(kind: srValue, value: v)
func empty*(): StackRes = StackRes(kind: srEmpty)

func hash*(s: StackState): Hash = !$(hash(s.items) !& hash(s.capacity))

func `$`*(op: StackOp): string =
  case op.kind
  of sPush: "push(" & $op.value & ")"
  of sPop: "pop()"

func `$`*(r: StackRes): string =
  case r.kind
  of srOk: "ok"
  of srFull: "full"
  of srValue: "value(" & $r.value & ")"
  of srEmpty: "empty"

func step*(m: typedesc[StackModel], s: StackState, op: StackOp):
    Expected[StackState, StackRes] {.raises: [].} =
  type E = Expected[StackState, StackRes]
  case op.kind
  of sPush:
    if s.capacity > 0 and s.items.len >= s.capacity:
      E(next: s, res: full(), why: "stack full: " & $s.items.len & " of " & $s.capacity)
    else:
      var n = s
      n.items.add op.value
      E(next: n, res: pushed())
  of sPop:
    if s.items.len == 0:
      E(next: s, res: empty(), why: "stack empty")
    else:
      var n = s
      let v = n.items.pop()
      E(next: n, res: popped(v), why: "top is " & $v)

proc toPayload*(x: StackOp): JsonNode =
  case x.kind
  of sPush: %*{"kind": "push", "value": x.value}
  of sPop: %*{"kind": "pop"}

proc fromPayload*(n: JsonNode, t: typedesc[StackOp]): StackOp =
  case n["kind"].getStr
  of "push": push(n["value"].getInt)
  of "pop": pop()
  else: raise newException(ValueError, "unknown StackOp: " & $n)

proc toPayload*(x: StackRes): JsonNode =
  case x.kind
  of srOk: %*{"kind": "ok"}
  of srFull: %*{"kind": "full"}
  of srValue: %*{"kind": "value", "value": x.value}
  of srEmpty: %*{"kind": "empty"}

proc fromPayload*(n: JsonNode, t: typedesc[StackRes]): StackRes =
  case n["kind"].getStr
  of "ok": pushed()
  of "full": full()
  of "value": popped(n["value"].getInt)
  of "empty": empty()
  else: raise newException(ValueError, "unknown StackRes: " & $n)

proc genStackOp*(rng: var Rand, thread, index: int): StackOp =
  ## Default generator (P3): push 50% (values unique per thread and index), pop 50%.
  if rng.rand(1) == 0: push(thread * 1000 + index + 1) else: pop()
