## `EventFlag` model: signal, wait (with timeout). See docs/MODELS.md#eventflag-and-lost-wakeup.
##
## A `wait` that times out while an unconsumed signal is pending has no
## sequential explanation, which is how a lost wakeup becomes visible to the
## checker. A `wait` that never returns stays pending and is not a violation.

import std/[hashes, json]
import ../model

type
  EventOpKind* = enum eSignal, eWait
  EventOp* = object
    kind*: EventOpKind      ## the timeout value is left out: it does not change the expected result
  EventResKind* = enum erAck, erSignaled, erTimedOut
  EventRes* = object
    kind*: EventResKind
  EventState* = object
    signaled*: bool         ## signal sent and not consumed yet
  EventFlagModel* = object

func signal*(): EventOp = EventOp(kind: eSignal)
func wait*(): EventOp = EventOp(kind: eWait)
func ack*(): EventRes = EventRes(kind: erAck)
func signaled*(): EventRes = EventRes(kind: erSignaled)
func timedOut*(): EventRes = EventRes(kind: erTimedOut)

func hash*(s: EventState): Hash = hash(s.signaled)

func `$`*(op: EventOp): string =
  case op.kind
  of eSignal: "signal()"
  of eWait: "wait()"

func `$`*(r: EventRes): string =
  case r.kind
  of erAck: "ack"
  of erSignaled: "signaled"
  of erTimedOut: "timedOut"

func step*(m: typedesc[EventFlagModel], s: EventState, op: EventOp):
    Expected[EventState, EventRes] {.raises: [].} =
  case op.kind
  of eSignal:
    Expected[EventState, EventRes](next: EventState(signaled: true), res: ack())
  of eWait:
    if s.signaled:
      Expected[EventState, EventRes](next: EventState(signaled: false), res: signaled())
    else:
      Expected[EventState, EventRes](next: s, res: timedOut(), why: "no pending signal")

proc toPayload*(x: EventOp): JsonNode =
  case x.kind
  of eSignal: %*{"kind": "signal"}
  of eWait: %*{"kind": "wait"}

proc fromPayload*(n: JsonNode, t: typedesc[EventOp]): EventOp =
  case n["kind"].getStr
  of "signal": signal()
  of "wait": wait()
  else: raise newException(ValueError, "unknown EventOp: " & $n)

proc toPayload*(x: EventRes): JsonNode = %*{"kind": $x}

proc fromPayload*(n: JsonNode, t: typedesc[EventRes]): EventRes =
  case n["kind"].getStr
  of "ack": ack()
  of "signaled": signaled()
  of "timedOut": timedOut()
  else: raise newException(ValueError, "unknown EventRes: " & $n)
