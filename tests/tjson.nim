import std/[os, unittest, options, strutils]
import nimlinear

# Variant payload, with custom hooks (std/json `to` does not cover case objects).
type
  QKind = enum qEnqueue, qDequeue
  QueueOp = object
    case kind: QKind
    of qEnqueue: value: int
    of qDequeue: discard
  QueueRes = object
    value: Option[int]   # none = "ok" (enqueue); some = dequeued value

proc `==`(a, b: QueueOp): bool =
  a.kind == b.kind and (a.kind == qDequeue or a.value == b.value)

proc toPayload(x: QueueOp): JsonNode =
  case x.kind
  of qEnqueue: %*{"kind": "enqueue", "value": x.value}
  of qDequeue: %*{"kind": "dequeue"}

proc fromPayload(n: JsonNode, t: typedesc[QueueOp]): QueueOp =
  case n["kind"].getStr
  of "enqueue": QueueOp(kind: qEnqueue, value: n["value"].getInt)
  of "dequeue": QueueOp(kind: qDequeue)
  else: raise newException(ValueError, "unknown op")

proc toPayload(x: QueueRes): JsonNode =
  if x.value.isSome: %*{"kind": "value", "value": x.value.get}
  else: %*{"kind": "ok"}

proc fromPayload(n: JsonNode, t: typedesc[QueueRes]): QueueRes =
  case n["kind"].getStr
  of "value": QueueRes(value: some(n["value"].getInt))
  of "ok": QueueRes()
  else: raise newException(ValueError, "unknown result")

# Simple payload, with the default hooks.
type
  RegOp = object
    write: bool
    value: int
  RegRes = object
    value: int

const fixture = currentSourcePath.parentDir / "fixtures" / "queue_overlap.jsonl"

suite "JSON Lines":
  test "round trip preserves bytes (custom hooks)":
    let original = readFile(fixture)
    let h = parseJsonLines[QueueOp, QueueRes](original)
    check h.events.len == 4
    check h.events[0].call == QueueOp(kind: qEnqueue, value: 7)
    check h.events[3].res == QueueRes(value: some(7))
    check h.toJsonLines() == original

  test "round trip (default hooks)":
    let h = newHistory(@[
      invokeEvent[RegOp, RegRes](1, 0, 1, RegOp(write: true, value: 5)),
      invokeEvent[RegOp, RegRes](2, 1, 2, RegOp(write: false)),
      returnEvent[RegOp, RegRes](1, 0, 3, RegRes()),
      returnEvent[RegOp, RegRes](2, 1, 4, RegRes(value: 5))])
    let s = h.toJsonLines()
    check s.splitLines()[1] ==
      """{"kind":"invoke","op":1,"thread":0,"seq":1,"payload":{"write":true,"value":5}}"""
    let back = parseJsonLines[RegOp, RegRes](s)
    check back.events == h.events
    check back.toJsonLines() == s

  test "empty":
    check parseJsonLines[RegOp, RegRes]("").events.len == 0

  test "malformed JSON raises ValueError":
    for bad in ["{", "[1]\n", "{\"kind\":\"invoke\",\"op\":1,\"thread\":0,\"seq\":1}\n",
                "{\"kind\":\"x\",\"op\":1,\"thread\":0,\"seq\":1,\"payload\":{}}\n",
                "{\"kind\":\"invoke\",\"op\":\"1\",\"thread\":0,\"seq\":1,\"payload\":{}}\n",
                "{\"kind\":\"invoke\",\"op\":1,\"thread\":0,\"seq\":1,\"payload\":{\"write\":1}}\n",
                "\n{\"kind\":\"invoke\",\"op\":1,\"thread\":0,\"seq\":1,\"payload\":{}}\n"]:
      expect ValueError:
        discard parseJsonLines[RegOp, RegRes](bad)

  test "invalid history raises ArgumentError":
    let dup = """{"kind":"return","op":1,"thread":0,"seq":1,"payload":{"value":0}}""" & "\n"
    expect ArgumentError:
      discard parseJsonLines[RegOp, RegRes](dup)

suite "JSON Lines: format version (M15)":
  let body = "{\"kind\":\"invoke\",\"op\":1,\"thread\":0,\"seq\":1,\"payload\":{\"write\":false,\"value\":0}}\n"

  test "the version line is written first":
    let h = parseJsonLines[RegOp, RegRes](body)
    check h.toJsonLines() == "{\"nimlinear\":1}\n" & body

  test "files without the version line still parse":
    check parseJsonLines[RegOp, RegRes](body).events.len == 1

  test "an unknown version is rejected with a clear message":
    try:
      discard parseJsonLines[RegOp, RegRes]("{\"nimlinear\":2}\n" & body)
      check false
    except ValueError as e:
      check "unsupported format version 2" in e.msg

  test "the version line only on the first line":
    expect ValueError:
      discard parseJsonLines[RegOp, RegRes](body & "{\"nimlinear\":1}\n")
