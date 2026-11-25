## `Map` model: get, put, delete on integer keys, with `partition` by key.
## See docs/MODELS.md#map.
##
## `put` and `delete` return the previous entry (`found`, `value`), like most
## concurrent maps; `get` returns the current one. Keys are independent, so
## `checkPartitioned` (and `RoundsConfig.partitioned`) check one key at a
## time: much faster for histories over several keys.

import std/[algorithm, hashes, json, random]
import ../model

type
  MapOpKind* = enum mGet, mPut, mDelete
  MapOp* = object
    kind*: MapOpKind
    key*: int
    value*: int        ## put only; 0 otherwise
  MapRes* = object
    found*: bool       ## the key had an entry (before put/delete)
    value*: int        ## its value; 0 if not found
  MapState* = object
    entries*: seq[(int, int)]  ## (key, value), sorted by key, no duplicate keys
  MapModel* = object

func get*(key: int): MapOp = MapOp(kind: mGet, key: key)
func put*(key, value: int): MapOp = MapOp(kind: mPut, key: key, value: value)
func delete*(key: int): MapOp = MapOp(kind: mDelete, key: key)
func found*(value: int): MapRes = MapRes(found: true, value: value)
func missing*(): MapRes = MapRes(found: false)

func initMapState*(entries: openArray[(int, int)] = []): MapState =
  ## Initial state from (key, value) pairs; a later pair wins for a repeated key.
  for (k, v) in entries:
    var i = 0
    while i < result.entries.len and result.entries[i][0] != k: inc i
    if i < result.entries.len: result.entries[i][1] = v
    else: result.entries.add (k, v)
  result.entries.sort(proc (a, b: (int, int)): int = cmp(a[0], b[0]))

func lookup(s: MapState, key: int): int =
  ## Index of `key` in `entries`, or -1.
  for i, e in s.entries:
    if e[0] == key: return i
  -1

func hash*(s: MapState): Hash = hash(s.entries)

func `$`*(op: MapOp): string =
  case op.kind
  of mGet: "get(" & $op.key & ")"
  of mPut: "put(" & $op.key & ", " & $op.value & ")"
  of mDelete: "delete(" & $op.key & ")"

func `$`*(r: MapRes): string =
  if r.found: "found(" & $r.value & ")" else: "missing"

func step*(m: typedesc[MapModel], s: MapState, op: MapOp):
    Expected[MapState, MapRes] {.raises: [].} =
  type E = Expected[MapState, MapRes]
  let i = s.lookup(op.key)
  let prev = if i >= 0: found(s.entries[i][1]) else: missing()
  case op.kind
  of mGet:
    E(next: s, res: prev, why: (if i < 0: "no entry for key " & $op.key else: ""))
  of mPut:
    var n = s
    if i >= 0:
      n.entries[i][1] = op.value
    else:
      var j = 0
      while j < n.entries.len and n.entries[j][0] < op.key: inc j
      n.entries.insert((op.key, op.value), j)
    E(next: n, res: prev)
  of mDelete:
    var n = s
    if i >= 0: n.entries.delete(i)
    E(next: n, res: prev)

func partition*(m: typedesc[MapModel], op: MapOp): int {.raises: [].} = op.key

proc toPayload*(x: MapOp): JsonNode =
  case x.kind
  of mGet: %*{"kind": "get", "key": x.key}
  of mPut: %*{"kind": "put", "key": x.key, "value": x.value}
  of mDelete: %*{"kind": "delete", "key": x.key}

proc fromPayload*(n: JsonNode, t: typedesc[MapOp]): MapOp =
  case n["kind"].getStr
  of "get": get(n["key"].getInt)
  of "put": put(n["key"].getInt, n["value"].getInt)
  of "delete": delete(n["key"].getInt)
  else: raise newException(ValueError, "unknown MapOp: " & $n)

proc toPayload*(x: MapRes): JsonNode =
  if x.found: %*{"found": true, "value": x.value} else: %*{"found": false}

proc fromPayload*(n: JsonNode, t: typedesc[MapRes]): MapRes =
  if n["found"].getBool: found(n["value"].getInt) else: missing()

proc randomMapOp*(rng: var Rand, thread, index: int, keys = 3): MapOp =
  ## Default generator (P3): a key in `0 ..< keys`; get 40%, put 40%,
  ## delete 20%. Put values are unique per thread and index.
  let k = rng.rand(keys - 1)
  case rng.rand(4)
  of 0, 1: get(k)
  of 2, 3: put(k, thread * 1000 + index + 1)
  else: delete(k)

proc genMapOp*(rng: var Rand, thread, index: int): MapOp =
  ## `randomMapOp` with 3 keys, in the signature `runRounds` expects.
  randomMapOp(rng, thread, index)
