## `CircuitBreaker` model: acquire, report, tick. See docs/MODELS.md#circuitbreaker.
##
## Minimal policy: opens after `threshold` consecutive failures; after the
## cool-down, allows one probe call; success closes it, failure reopens it.
## Example of the "state machine with permits" pattern: the caller's work
## between `acquire` and `report` stays out of the history.
##
## Time: either fix the clock for the round (`cooledDown` in the initial
## state) or record `tick()` (M10) when the cool-down elapses during the round.

import std/[hashes, json]
import ../model

type
  Phase* = enum pClosed, pOpen, pHalfOpen
  PermitKind* = enum pkNormal, pkProbe
  BreakerOpKind* = enum bAcquire, bReport, bTick
  BreakerOp* = object
    case kind*: BreakerOpKind
    of bAcquire, bTick: discard
    of bReport:
      permit*: PermitKind      ## kind received in the matching acquire
      ok*: bool
  BreakerResKind* = enum brAllowed, brRejected, brAck
  BreakerRes* = object
    kind*: BreakerResKind
    permit*: PermitKind        ## only meaningful in brAllowed
  BreakerState* = object
    phase*: Phase
    failures*: int             ## consecutive failures in pClosed
    probeOut*: bool            ## probe call in progress
    cooledDown*: bool          ## cool-down already elapsed
    threshold*: int            ## test constant
  BreakerModel* = object

func acquire*(): BreakerOp = BreakerOp(kind: bAcquire)
func report*(permit: PermitKind, ok: bool): BreakerOp =
  BreakerOp(kind: bReport, permit: permit, ok: ok)
func tick*(): BreakerOp = BreakerOp(kind: bTick)
  ## The cool-down elapsed (recorded as an ekTick event, M10).

func allowed*(p: PermitKind): BreakerRes = BreakerRes(kind: brAllowed, permit: p)
func rejected*(): BreakerRes = BreakerRes(kind: brRejected)
func ack*(): BreakerRes = BreakerRes(kind: brAck)

func `==`*(a, b: BreakerOp): bool =
  if a.kind != b.kind: return false
  case a.kind
  of bAcquire, bTick: true
  of bReport: a.permit == b.permit and a.ok == b.ok

func `==`*(a, b: BreakerRes): bool =
  a.kind == b.kind and (a.kind != brAllowed or a.permit == b.permit)

func hash*(s: BreakerState): Hash =
  var h: Hash = 0
  h = h !& hash(s.phase)
  h = h !& hash(s.failures)
  h = h !& hash(s.probeOut)
  h = h !& hash(s.cooledDown)
  h = h !& hash(s.threshold)
  !$h

func `$`*(op: BreakerOp): string =
  case op.kind
  of bAcquire: "acquire()"
  of bTick: "tick()"
  of bReport: "report(" & $op.permit & ", " & (if op.ok: "ok" else: "failure") & ")"

func `$`*(r: BreakerRes): string =
  case r.kind
  of brAllowed: "allowed(" & $r.permit & ")"
  of brRejected: "rejected"
  of brAck: "ack"

func step*(m: typedesc[BreakerModel], s: BreakerState, op: BreakerOp):
    Expected[BreakerState, BreakerRes] {.raises: [].} =
  type E = Expected[BreakerState, BreakerRes]
  var n = s
  case op.kind
  of bAcquire:
    case s.phase
    of pClosed: E(next: s, res: allowed(pkNormal))
    of pOpen:
      if not s.cooledDown:
        E(next: s, res: rejected(), why: "open")
      else:
        n.phase = pHalfOpen
        n.probeOut = true
        E(next: n, res: allowed(pkProbe))
    of pHalfOpen:
      if s.probeOut:
        E(next: s, res: rejected(), why: "probe in progress")
      else:
        n.probeOut = true
        E(next: n, res: allowed(pkProbe))
  of bReport:
    case op.permit
    of pkNormal:
      if s.phase != pClosed:
        E(next: s, res: ack())             # late result from before opening
      elif op.ok:
        n.failures = 0
        E(next: n, res: ack())
      else:
        inc n.failures
        if n.failures >= s.threshold:
          n.phase = pOpen
          n.failures = 0
          n.cooledDown = false
        E(next: n, res: ack())
    of pkProbe:
      if op.ok:
        n.phase = pClosed
        n.failures = 0
      else:
        n.phase = pOpen
        n.cooledDown = false
      n.probeOut = false
      E(next: n, res: ack())
  of bTick:
    n.cooledDown = true
    E(next: n, res: ack())

proc toPayload*(x: BreakerOp): JsonNode =
  case x.kind
  of bAcquire: %*{"kind": "acquire"}
  of bTick: %*{"kind": "tick"}
  of bReport: %*{"kind": "report", "permit": $x.permit, "ok": x.ok}

proc fromPayload*(n: JsonNode, t: typedesc[BreakerOp]): BreakerOp =
  case n["kind"].getStr
  of "acquire": acquire()
  of "tick": tick()
  of "report":
    let p = case n["permit"].getStr
      of "pkNormal": pkNormal
      of "pkProbe": pkProbe
      else: raise newException(ValueError, "unknown permit: " & $n)
    report(p, n["ok"].getBool)
  else: raise newException(ValueError, "unknown BreakerOp: " & $n)

proc toPayload*(x: BreakerRes): JsonNode =
  case x.kind
  of brAllowed: %*{"kind": "allowed", "permit": $x.permit}
  of brRejected: %*{"kind": "rejected"}
  of brAck: %*{"kind": "ack"}

proc fromPayload*(n: JsonNode, t: typedesc[BreakerRes]): BreakerRes =
  case n["kind"].getStr
  of "allowed":
    case n["permit"].getStr
    of "pkNormal": allowed(pkNormal)
    of "pkProbe": allowed(pkProbe)
    else: raise newException(ValueError, "unknown permit: " & $n)
  of "rejected": rejected()
  of "ack": ack()
  else: raise newException(ValueError, "unknown BreakerRes: " & $n)
