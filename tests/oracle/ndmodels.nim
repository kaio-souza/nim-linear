## Test-only nondeterministic models for M14 (the `outcomes` contract).
##
## - `BagModel`: `put(v)` adds an item; `take()` may return ANY item (or
##   `empty`). Each possible item is one outcome.
## - `WeakRegModel`: a register whose `cas` may fail spuriously even when the
##   expected value matches (like a weak compare-exchange).

import std/[algorithm, hashes]
import nimlinear

type
  BagKind* = enum bPut, bTake
  BagOp* = object
    kind*: BagKind
    value*: int
  BagRes* = object
    value*: int        ## take: item taken, or -1 when empty; put: 0
  BagState* = object
    items*: seq[int]   ## kept sorted, so equal bags compare equal
  BagModel* = object

func put*(v: int): BagOp = BagOp(kind: bPut, value: v)
func take*(): BagOp = BagOp(kind: bTake)
func hash*(s: BagState): Hash = hash(s.items)

func outcomes*(m: typedesc[BagModel], s: BagState, op: BagOp):
    seq[Expected[BagState, BagRes]] {.raises: [].} =
  case op.kind
  of bPut:
    var n = s
    n.items.insert(op.value, n.items.lowerBound(op.value))
    result = @[Expected[BagState, BagRes](next: n, res: BagRes())]
  of bTake:
    if s.items.len == 0:
      return @[Expected[BagState, BagRes](next: s, res: BagRes(value: -1), why: "bag empty")]
    for k, v in s.items:
      if k > 0 and s.items[k - 1] == v: continue     # same item twice: one outcome
      var n = s
      n.items.delete(k)
      result.add Expected[BagState, BagRes](next: n, res: BagRes(value: v))

type
  WKind* = enum wRead, wWrite, wCas
  WOp* = object
    kind*: WKind
    a*, b*: int        ## write: a; cas: expected a, desired b
  WRes* = object
    value*: int
    ok*: bool
  WState* = object
    value*: int
  WeakRegModel* = object

func wread*(): WOp = WOp(kind: wRead)
func wwrite*(v: int): WOp = WOp(kind: wWrite, a: v)
func wcas*(e, d: int): WOp = WOp(kind: wCas, a: e, b: d)
func hash*(s: WState): Hash = hash(s.value)

func outcomes*(m: typedesc[WeakRegModel], s: WState, op: WOp):
    seq[Expected[WState, WRes]] {.raises: [].} =
  type E = Expected[WState, WRes]
  case op.kind
  of wRead: @[E(next: s, res: WRes(value: s.value, ok: true))]
  of wWrite: @[E(next: WState(value: op.a), res: WRes(ok: true))]
  of wCas:
    if s.value == op.a:
      @[E(next: WState(value: op.b), res: WRes(ok: true)),
        E(next: s, res: WRes(ok: false), why: "spurious failure")]
    else:
      @[E(next: s, res: WRes(ok: false), why: "cas failed: current value " & $s.value)]
