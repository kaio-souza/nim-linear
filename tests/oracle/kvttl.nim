## Test-only model for M10/M11: a map with 2 keys, where each entry expires
## after `ttl` ticks. `put` writes and resets the age, `get` returns the value
## or -1 when the entry expired, and `tick` ages every entry.
##
## P-compositional by key (D-12): `put`/`get` touch only their key, and `tick`
## acts on every key independently, so checkPartitioned can split by key and
## copy ticks into each part.

import std/hashes
import nimlinear

const ttl* = 2

type
  KvKind* = enum kPut, kGet, kTick
  KvOp* = object
    kind*: KvKind
    key*, value*: int
  KvRes* = object
    value*: int      ## get: value or -1 if expired; put/tick: 0
  Entry = tuple[value, age: int]
  KvState* = object
    entries*: array[2, Entry]
  KvModel* = object

func put*(k, v: int): KvOp = KvOp(kind: kPut, key: k, value: v)
func get*(k: int): KvOp = KvOp(kind: kGet, key: k)
func tick*(): KvOp = KvOp(kind: kTick)

func initKv*(): KvState =
  for e in result.entries.mitems: e = (0, 0)

func hash*(s: KvState): Hash =
  var h: Hash = 0
  for e in s.entries: h = h !& hash(e.value) !& hash(e.age)
  !$h

func step*(m: typedesc[KvModel], s: KvState, op: KvOp): Expected[KvState, KvRes] {.raises: [].} =
  var n = s
  case op.kind
  of kPut:
    n.entries[op.key] = (op.value, 0)
    Expected[KvState, KvRes](next: n, res: KvRes())
  of kGet:
    let e = s.entries[op.key]
    if e.age >= ttl:
      Expected[KvState, KvRes](next: s, res: KvRes(value: -1), why: "expired")
    else:
      Expected[KvState, KvRes](next: s, res: KvRes(value: e.value))
  of kTick:
    for e in n.entries.mitems: e.age = min(e.age + 1, ttl)
    Expected[KvState, KvRes](next: n, res: KvRes())

func partition*(m: typedesc[KvModel], op: KvOp): int {.raises: [].} = op.key
