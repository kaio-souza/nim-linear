# Sequential models

A **model** describes what the data structure should do when operations happen one at a time, without concurrency. The checker uses the model to answer: is there an order of these operations that produces exactly the observed results?

If you cannot write the model, the library is not suitable for that object. Writing the model is the main work; the checker is mechanical.

## Contract

A model is a type (used as a `typedesc`) with a transition function, plus `hash` and `==` on the state and `==` on the result:

```nim
type MyModel = object   # marker; the state is MyState

func step(m: typedesc[MyModel], s: MyState, op: MyOp): Expected[MyState, MyRes] {.raises: [].}
func `==`(a, b: MyState): bool
func hash(s: MyState): Hash
func `==`(a, b: MyRes): bool
```

The initial state is not part of the model: it is passed to `checkLinearizable(h, init, MyModel)`, because it usually depends on the test setup (D-17).

`Expected` carries the next state, the expected result and the reason (`why`) when the operation is refused. `why` decides nothing; it only shows up in diagnostics. Example: `why: "queue full: 4 of 4"`.

| Rule | Reason |
|---|---|
| `step` is a `func`, `{.raises: [].}` and has no side effects | the checker calls `step` many times in different orders, and the core does not raise (D-16) |
| the state is a value `object`, with no `ref` | `func` does not forbid `ref` or globals; `ref` hides mutation |
| `hash` and `==` cover **every** state field, including configuration constants | memoization uses `(linearized, state)` as the key; a forgotten field gives a wrong verdict (D-04) |
| `step` is total (answers for every state/operation combination) | an invalid operation must become an error result, not an exception |
| no wall-clock time inside `step` | see [Time](#time) |

The planned `Model` concept (see [API](API.md#model)) is meant to check the contract at compile time; today only the `{.raises: [].}` part is enforced.

## Writing a model, step by step

1. **List the public operations** of the data structure. One line per operation, with arguments and return value.
2. **Define the minimal state** that determines future behavior. If a field changes no result, it does not belong in the state. (Configuration constants may go in; they do not increase the number of states.)
3. **Write `step` for each operation**, as if it were a single atomic call. Each case returns the new state and the result the implementation should return.
4. **Write hand-written cases** before trusting the model: small sequences with a known result (expected `step` for each line).
5. **Compare against the real code** on sequential runs (no threads). The model and the implementation must agree on all of them. If they do not, the error is in the model or in the code, and it must be investigated before any concurrent test. A serial run of the code itself can also serve as a second oracle (D-13).

Step 5 is the most important and the most often skipped. A wrong model produces `vkNotLinearizable` on correct code.

## How much of the specification to put in the model

If the model reimplements all of the object's logic, the oracle duplicates the code under test and inherits its mistakes. Prefer a smaller model that covers the invariant you care about, and configure the object under test so that the parts outside the model do not affect the results (for example, by turning off optional policies). Write down in your model's documentation what was left out.

## Time

Objects whose result depends on the clock (timeouts, TTL, limiters) cannot read the clock in `step`. Two options; pick **one per test**:

1. **Clock fixed for the round (recommended).** The test prepares the object and advances a fake clock **before** starting the threads, and does not advance it during the round. In the model, the effect of time becomes a field of the initial state (for example, `expired: bool`). States created during the round assume the clock did not move. The history needs no time events.
2. **Time as a history operation (M10).** Each clock advance produces a `tick` event in the history (see [History](HISTORY.md#time)), and the model treats `tick` as a transition: `Op` gets a tick variant, and `step` updates the time-dependent fields for it (for example, aging an entry). The result `step` returns for a tick is ignored. More expressive, more expensive for the checker. Use it only if the test needs time to advance between concurrent operations.

## Example models

The models below ship with the library. They serve to test the checker and as a starting point. Implemented today: `Register`, `EventFlag` and `BoundedQueue` (`nimlinear/models/*`). `CircuitBreaker` is planned.

| Model | State | Operations | Use |
|---|---|---|---|
| [`Register`](#register) | `value: int` | `read`, `write`, `cas` | simplest fixture; basis for M2 |
| [`EventFlag`](#eventflag-and-lost-wakeup) | `signaled: bool` | `signal`, `wait` (with timeout) | lost wakeup (M3) |
| [`BoundedQueue`](#boundedqueue) | `items: seq[int]`, `capacity`, `closed` | `enqueue`, `dequeue`, `close` | queue/channel; end-to-end example in [`examples/queue_race.nim`](../examples/queue_race.nim) (M8) |
| [`CircuitBreaker`](#circuitbreaker) | `phase`, `failures`, `probeOut`, `cooledDown`, `threshold` | `acquire`, `report` | example of the [state machine with permits](#state-machines-with-permits) pattern |

None of these models gets special treatment from the checker. They use the same contract as any model of yours; the library does not know what a queue or a breaker is.

### Register

```nim
type
  RegOpKind = enum rRead, rWrite, rCas
  RegOp = object
    case kind: RegOpKind
    of rRead: discard
    of rWrite: value: int
    of rCas: expected, desired: int
  RegRes = object
    value: int    # read: value read; write: 0
    ok: bool      # cas: swapped?; read/write: true
  RegState = object
    value: int
  RegisterModel = object

func step(m: typedesc[RegisterModel], s: RegState, op: RegOp):
    Expected[RegState, RegRes] {.raises: [].} =
  case op.kind
  of rRead:  Expected[RegState, RegRes](next: s, res: RegRes(value: s.value, ok: true))
  of rWrite: Expected[RegState, RegRes](next: RegState(value: op.value), res: RegRes(ok: true))
  of rCas:
    if s.value == op.expected:
      Expected[RegState, RegRes](next: RegState(value: op.desired), res: RegRes(ok: true))
    else:
      Expected[RegState, RegRes](next: s, res: RegRes(ok: false),
        why: "cas failed: current value " & $s.value)
```

### EventFlag and lost wakeup

Reference case: [weave#56](https://github.com/mratsim/weave/issues/56), a lost wakeup on a glibc condition variable. The breaking sequence is: `signal` arrives before `wait` starts sleeping, and `wait` sleeps forever.

This class of bug **does not show up as a linearizability violation** when `wait` never returns. The operation stays pending and the checker accepts it. To make it detectable, the test needs one of two forms:

1. **`wait` with a timeout (recommended).** `wait` is a single operation, with `invoke` before and `return` after; the timeout is just the result (`signaled` or `timedOut`), not a time event. If a `signal` returned before the `wait`'s `invoke` and nobody consumed the signal, `timedOut` has no sequential explanation and the checker rejects it. No `tick` is needed.
2. **Watchdog.** An external guard measures the round's time and reports the history as a failure if there is a pending operation past the deadline. That is not linearizability; it is a liveness guard.

```nim
type
  EventOpKind = enum eSignal, eWait
  EventOp = object
    kind: EventOpKind        # the timeout value is left out: it does not change the expected result
  EventResKind = enum erAck, erSignaled, erTimedOut
  EventRes = object
    kind: EventResKind
  EventState = object
    signaled: bool           # signal sent and not consumed yet
  EventFlagModel = object

func `==`(a, b: EventState): bool = a.signaled == b.signaled
func hash(s: EventState): Hash = hash(s.signaled)
func `==`(a, b: EventRes): bool = a.kind == b.kind

func step(m: typedesc[EventFlagModel], s: EventState, op: EventOp):
    Expected[EventState, EventRes] {.raises: [].} =
  case op.kind
  of eSignal:
    Expected[EventState, EventRes](next: EventState(signaled: true),
                                   res: EventRes(kind: erAck))
  of eWait:
    if s.signaled:
      Expected[EventState, EventRes](next: EventState(signaled: false),
                                     res: EventRes(kind: erSignaled))
    else:
      Expected[EventState, EventRes](next: s, res: EventRes(kind: erTimedOut),
                                     why: "no pending signal")
```

There is no "threads waiting" field: since each `wait` is atomic in the model, the waiting itself is not state.

### BoundedQueue

```nim
type
  QueueOpKind = enum qEnqueue, qDequeue, qClose
  QueueOp = object
    case kind: QueueOpKind
    of qEnqueue: value: int
    else: discard
  QueueResKind = enum qrOk, qrFull, qrClosed, qrValue, qrEmpty
  QueueRes = object
    kind: QueueResKind
    value: int            # only in qrValue
  QueueState = object
    items: seq[int]
    capacity: int         # test constant; goes into hash and ==
    closed: bool
  QueueModel = object

func `==`(a, b: QueueState): bool =
  a.items == b.items and a.capacity == b.capacity and a.closed == b.closed

func hash(s: QueueState): Hash =
  var h: Hash = 0
  h = h !& hash(s.items)        # contents, not just the length
  h = h !& hash(s.capacity)
  h = h !& hash(s.closed)
  !$h

func `==`(a, b: QueueRes): bool =
  a.kind == b.kind and (a.kind != qrValue or a.value == b.value)   # value only counts in qrValue

func step(m: typedesc[QueueModel], s: QueueState, op: QueueOp):
    Expected[QueueState, QueueRes] {.raises: [].} =
  type E = Expected[QueueState, QueueRes]
  case op.kind
  of qEnqueue:
    if s.closed:
      E(next: s, res: QueueRes(kind: qrClosed), why: "queue closed")
    elif s.items.len >= s.capacity:
      E(next: s, res: QueueRes(kind: qrFull),
        why: "queue full: " & $s.items.len & " of " & $s.capacity)
    else:
      var n = s
      n.items.add op.value
      E(next: n, res: QueueRes(kind: qrOk))
  of qDequeue:
    if s.items.len == 0:
      if s.closed: E(next: s, res: QueueRes(kind: qrClosed), why: "empty and closed")
      else: E(next: s, res: QueueRes(kind: qrEmpty), why: "queue empty")
    else:
      var n = s
      let v = n.items[0]
      n.items.delete(0)
      E(next: n, res: QueueRes(kind: qrValue, value: v))
  of qClose:
    var n = s
    n.closed = true                # idempotent
    E(next: n, res: QueueRes(kind: qrOk))
```

A `seq` in the state is fine for small histories; `hash` must cover the contents, not just the length. Note that the result's `==` ignores `value` outside `qrValue`: fields with no meaning in a given variant branch must not decide equality.

## State machines with permits

A generic pattern, not specific to any object. It applies to any object in which the caller **asks for permission, does work outside the object and then reports the outcome**:

| Object | Ask for permission | Report the outcome |
|---|---|---|
| circuit breaker | `acquire` -> allowed / rejected | `report(ok/failure)` |
| connection pool | `borrow` -> connection / exhausted | `giveBack(conn, healthy?)` |
| semaphore, bulkhead | `tryAcquire` -> ok / full | `release` |
| rate limiter with refund | `take` -> ok / denied | `refund` |
| lease, owned lock | `lock(owner)` -> ok / busy | `unlock(owner)` |

Rules of the pattern:

1. **Do not record the compound call as one operation.** A `call(f)` that asks for permission, runs `f` and reports the outcome is not atomic: other threads act in between. Record **two** operations, each with its own `invoke`/`return`. The user's work (`f`) stays out of the history.
2. **The permit goes into the result and, if the object distinguishes it, into the state.** If `report` only makes sense for whoever received a specific kind of permit (for example, the half-open probe call), the result of `acquire` states the kind, and `report` takes that kind as an argument.
3. **The invariant you care about must be in `step`.** "At most one probe call", "never more than N borrowed": if the model does not refuse, the checker accepts the violation.
4. **Time-driven transitions follow [Time](#time).** With the clock fixed for the round, the effect of time is a field of the initial state. Advancing during the round uses `tick` (M10).
5. **Getting stuck is not a violation.** An object that never gives the permit back or never leaves a state is a liveness problem. Use a timeout in the result or a watchdog, as in [`EventFlag`](#eventflag-and-lost-wakeup).

### CircuitBreaker

An example of the pattern above. Minimal policy: opens after `threshold` consecutive failures; after the cool-down, allows **one** probe call; success closes it, failure reopens it.

```nim
type
  Phase = enum pClosed, pOpen, pHalfOpen
  PermitKind = enum pkNormal, pkProbe
  BreakerOpKind = enum bAcquire, bReport
  BreakerOp = object
    case kind: BreakerOpKind
    of bAcquire: discard
    of bReport:
      permit: PermitKind      # kind received in the matching acquire
      ok: bool
  BreakerResKind = enum brAllowed, brRejected, brAck
  BreakerRes = object
    kind: BreakerResKind
    permit: PermitKind        # only in brAllowed
  BreakerState = object
    phase: Phase
    failures: int             # consecutive failures in pClosed
    probeOut: bool            # probe call in progress
    cooledDown: bool          # cool-down already elapsed (clock fixed for the round)
    threshold: int            # test constant; goes into hash and ==
  BreakerModel = object

# acquire:
#   pClosed                         -> brAllowed(pkNormal)
#   pOpen, not cooledDown           -> brRejected (why: "open")
#   pOpen, cooledDown               -> phase = pHalfOpen, probeOut = true, brAllowed(pkProbe)
#   pHalfOpen, probeOut             -> brRejected (why: "probe in progress")
#   pHalfOpen, not probeOut         -> probeOut = true, brAllowed(pkProbe)
# report(pkNormal, ok):
#   pClosed  -> failures = 0, brAck
#   others   -> brAck, no change (late result from before opening)
# report(pkNormal, failure):
#   pClosed  -> failures += 1; if failures >= threshold: phase = pOpen,
#               failures = 0, cooledDown = false; brAck
#   others   -> brAck, no change
# report(pkProbe, ok):      phase = pClosed, failures = 0, probeOut = false, brAck
# report(pkProbe, failure): phase = pOpen, probeOut = false, cooledDown = false, brAck
```

Left out of the model (write this down in your test's documentation): sliding windows, failure rate as a percentage, more than one probe call, limits per error type. Configure the real breaker so that these policies do not affect the results, or extend the state.

Decisions that belong to **your policy**, not to the library. Adjust `step` if your breaker differs:

- what to do with a `report(pkNormal)` that arrives after the breaker opened (here: ignored);
- whether the open→half-open transition happens in `acquire` (here) or in a timer;
- whether `cooledDown` can become true again during the round: with a fixed clock, it cannot. To test the cool-down expiring during the round, use `tick` (M10).

Bugs this model rejects: two `pkProbe` permits granted with no `report` between them; opening with more or fewer failures than `threshold`; a late `report(pkNormal)` closing a breaker that had already opened.

## Checklist before trusting a new model

- [ ] `step` is a `func` and `{.raises: [].}`, with no `ref` in the state.
- [ ] `hash` and `==` cover every state field, including constants.
- [ ] Hand-written cases pass (step 4).
- [ ] The model agrees with the implementation in sequence, without threads (step 5).
- [ ] No wall-clock time field in the state or in `step`.
- [ ] What was left out of the model is written down in its documentation.
