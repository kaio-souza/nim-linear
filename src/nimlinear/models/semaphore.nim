## `Semaphore` model: counting semaphore with non-blocking `tryAcquire` and
## `release`. See docs/MODELS.md#semaphore.
##
## A blocking `acquire` that never returns stays pending (not a violation);
## test it with `tryAcquire`, or with a timeout reported as `tryAcquire`
## failing. Releasing more permits than `max` is a refused operation
## (`ok = false`), so an implementation that allows it is not linearizable.

import std/[hashes, json, random]
import ../model

type
  SemOpKind* = enum semTryAcquire, semRelease
  SemOp* = object
    kind*: SemOpKind
  SemRes* = object
    ok*: bool          ## tryAcquire: got a permit; release: accepted
  SemState* = object
    permits*: int      ## available now
    max*: int          ## permits when none is held
  SemaphoreModel* = object

func tryAcquire*(): SemOp = SemOp(kind: semTryAcquire)
func release*(): SemOp = SemOp(kind: semRelease)
func initSemState*(max: int): SemState = SemState(permits: max, max: max)

func hash*(s: SemState): Hash = !$(hash(s.permits) !& hash(s.max))

func `$`*(op: SemOp): string =
  case op.kind
  of semTryAcquire: "tryAcquire()"
  of semRelease: "release()"

func `$`*(r: SemRes): string = (if r.ok: "ok" else: "refused")

func step*(m: typedesc[SemaphoreModel], s: SemState, op: SemOp):
    Expected[SemState, SemRes] {.raises: [].} =
  type E = Expected[SemState, SemRes]
  case op.kind
  of semTryAcquire:
    if s.permits > 0: E(next: SemState(permits: s.permits - 1, max: s.max), res: SemRes(ok: true))
    else: E(next: s, res: SemRes(ok: false), why: "no permit available")
  of semRelease:
    if s.permits < s.max: E(next: SemState(permits: s.permits + 1, max: s.max), res: SemRes(ok: true))
    else: E(next: s, res: SemRes(ok: false), why: "all " & $s.max & " permits already free")

proc toPayload*(x: SemOp): JsonNode =
  let k = case x.kind
    of semTryAcquire: "tryAcquire"
    of semRelease: "release"
  %*{"kind": k}

proc fromPayload*(n: JsonNode, t: typedesc[SemOp]): SemOp =
  case n["kind"].getStr
  of "tryAcquire": tryAcquire()
  of "release": release()
  else: raise newException(ValueError, "unknown SemOp: " & $n)

proc toPayload*(x: SemRes): JsonNode = %*{"ok": x.ok}

proc fromPayload*(n: JsonNode, t: typedesc[SemRes]): SemRes = SemRes(ok: n["ok"].getBool)

proc genSemaphoreOp*(rng: var Rand, thread, index: int): SemOp =
  ## Default generator (P3): alternates per thread, starting with tryAcquire,
  ## so each thread releases only after trying to acquire. A release after a
  ## failed tryAcquire is a deliberate over-release, which a correct
  ## semaphore must refuse.
  if index mod 2 == 0: tryAcquire() else: release()
