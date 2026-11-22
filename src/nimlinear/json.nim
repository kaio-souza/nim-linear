## Saved format in JSON Lines (M1, D-05). See docs/HISTORY.md#saved-format-json.

import std/[json, strutils]
import ./history

export json

proc toPayload*[T](x: T): JsonNode =
  ## Default hook; override it for variant objects.
  %x

proc fromPayload*[T](n: JsonNode, t: typedesc[T]): T =
  ## Default hook; override it for variant objects.
  n.to(T)

const formatVersion* = 1
  ## Version of the saved format (M15). Written as the first line,
  ## `{"nimlinear":1}`; a change to the format increments it (D-05).

proc toJsonLines*[Op, Res](h: History[Op, Res]): string =
  ## One event per line, after the `{"nimlinear":1}` version line.
  mixin toPayload
  result = "{\"nimlinear\":" & $formatVersion & "}\n"
  for e in h.events:
    let payload = case e.kind
      of ekInvoke, ekTick: toPayload(e.call)
      of ekReturn: toPayload(e.res)
    result.add "{\"kind\":"
    result.add(case e.kind
      of ekInvoke: "\"invoke\""
      of ekReturn: "\"return\""
      of ekTick: "\"tick\"")
    result.add ",\"op\":" & $e.op
    result.add ",\"thread\":" & $e.thread
    result.add ",\"seq\":" & $e.seqNo
    result.add ",\"payload\":"
    toUgly(result, payload)
    result.add "}\n"

proc intField(n: JsonNode, key: string, line: int): int {.raises: [ValueError].} =
  let f = n.getOrDefault(key)
  if f.isNil or f.kind != JInt:
    raise newException(ValueError, "line " & $line & ": integer field \"" & key & "\" missing or invalid")
  f.getInt

proc parseJsonLines*[Op, Res](s: string): History[Op, Res] {.raises: [ValueError, ArgumentError].} =
  mixin fromPayload
  var events: seq[Event[Op, Res]]
  let lines = s.split('\n')
  for i, raw in lines:
    let lineNo = i + 1
    if raw.len == 0:
      if i == lines.high: break   # trailing \n
      raise newException(ValueError, "line " & $lineNo & ": empty")
    var n: JsonNode
    try:
      n = parseJson(raw)
    except CatchableError as err:
      raise newException(ValueError, "line " & $lineNo & ": malformed JSON: " & err.msg)
    if n.kind != JObject:
      raise newException(ValueError, "line " & $lineNo & ": expected an object")
    let ver = n.getOrDefault("nimlinear")
    if not ver.isNil:
      if i != 0:
        raise newException(ValueError, "line " & $lineNo & ": the version line must be the first line")
      if ver.kind != JInt or ver.getInt != formatVersion:
        raise newException(ValueError, "line 1: unsupported format version " & $ver &
          " (this nimlinear reads version " & $formatVersion & ")")
      continue
    let kindNode = n.getOrDefault("kind")
    let payload = n.getOrDefault("payload")
    if payload.isNil:
      raise newException(ValueError, "line " & $lineNo & ": field \"payload\" missing")
    let op = intField(n, "op", lineNo)
    let thread = intField(n, "thread", lineNo)
    let sq = intField(n, "seq", lineNo)
    let kind = if kindNode.isNil or kindNode.kind != JString: "" else: kindNode.getStr
    try:
      case kind
      of "invoke":
        events.add invokeEvent[Op, Res](op, thread, sq, fromPayload(payload, Op))
      of "return":
        events.add returnEvent[Op, Res](op, thread, sq, fromPayload(payload, Res))
      of "tick":
        events.add tickEvent[Op, Res](op, thread, sq, fromPayload(payload, Op))
      else:
        raise newException(ValueError, "field \"kind\" must be \"invoke\", \"return\" or \"tick\"")
    except CatchableError as err:
      raise newException(ValueError, "line " & $lineNo & ": " & err.msg)
  newHistory(events)
