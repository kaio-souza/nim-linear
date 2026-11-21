# API

> Draft. Names and signatures may change until the first release. After it, every change on this page goes into `CHANGELOG.md`, under `## Unreleased` (see [Release policy](../README.md#release-policy)).

## Overview

```
recorder  ──►  History  ──►  checkLinearizable(history, init, Model, budget)  ──►  Verdict
(records)     (events)      (graph search + memoization)                         (3 verdicts)
```

## Main types

### `OpId`, `ThreadId`, `SeqNo`

`distinct` so identifiers are not mixed up. The sequence number is called `SeqNo` (field `seqNo`) so it is not confused with the language's `seq` type (D-19); in prose and in JSON it is still called `seq`.

```nim
type
  OpId* = distinct int      # identifies an operation (invoke + return)
  ThreadId* = distinct int  # originating thread
  SeqNo* = distinct int     # global sequence number of the event (from Atomic[int], D-03)
```

### `Event`

Each call produces two events: `invoke` (before the call) and `return` (after it). An operation with an `invoke` and no `return` is **pending** (see [History](HISTORY.md#pending-operations)).

```nim
type
  EventKind* = enum ekInvoke, ekReturn

  Event*[Op, Res] = object
    op*: OpId
    thread*: ThreadId
    seqNo*: SeqNo                 # called `seq` in prose and in JSON (D-19)
    case kind*: EventKind
    of ekInvoke: call*: Op        # what was requested
    of ekReturn: res*: Res        # what came back
```

### `History`

```nim
type History*[Op, Res] = object
  events*: seq[Event[Op, Res]]    # ordered by seq
```

Invariants, checked by `newHistory` (a history that violates any of them is rejected with `ArgumentError` at construction, not at check time):

1. `seq` is unique across the whole history;
2. each `OpId` has exactly one `invoke` and at most one `return`;
3. `invoke.seq < return.seq`, and both have the same `thread`;
4. a thread does not invoke a new operation while it has another one without a `return` (each thread is sequential).

`newHistory` sorts the events by `seq`; input order does not matter.

### `ArgumentError`

Nim has no `ArgumentError` in `system`; the library defines its own:

```nim
type ArgumentError* = object of CatchableError   # does not inherit from ValueError
```

It does not inherit from `ValueError` so that `parseJsonLines` keeps its two errors apart: `ValueError` is malformed JSON, `ArgumentError` is an invalid history.

### Event constructors

Shortcuts to build events by hand (fixtures, tests) without writing the variant object:

```nim
proc invokeEvent*[Op, Res](op, thread, seqNo: int, call: Op): Event[Op, Res]
proc returnEvent*[Op, Res](op, thread, seqNo: int, res: Res): Event[Op, Res]
```

`Event` has its own `==` (Nim's default `==` does not compare objects with a `case`), which requires `==` for `Op` and `Res`.

### `Model`

Description of the sequential specification. Full contract in [Models](MODELS.md#contract).

```nim
type Expected*[S, Res] = object
  next*: S          # state after the operation
  res*: Res         # result the specification expects
  why*: string      # reason, when the result is a refusal (empty otherwise)

type Model*[S, Op, Res] = concept type M
  step(M, S, Op) is Expected[S, Res]   # pure func, {.raises: [].}
  hash(S) is Hash                      # from std/hashes
  `==`(S, S) is bool
  `==`(Res, Res) is bool
```

`Expected` is implemented (M2). The `Model` concept is not yet: today the contract is enforced only by the calls `checkLinearizable` makes.

The model is a **type** (passed as a `typedesc`), not a value. The initial state is passed separately, to `checkLinearizable`, because it usually depends on the test setup (for example, the capacity of a bounded queue).

`why` is used only for diagnostics (D-14). It plays no part in deciding linearizability.

`partition` (D-12) is optional and used only by `checkPartitioned`. When present, it has this signature:

```nim
func partition(m: typedesc[M], op: Op): int {.raises: [].}   # partition key of the operation
```

Operations with the same key go to the same sub-history. The key depends only on the operation (the `invoke`), never on the result, so that pending operations can be partitioned too. `checkPartitioned` does not compile if the model does not define `partition`.

**About `{.raises: [].}`:** a concept does not check effect pragmas. The guarantee comes from `checkLinearizable` being `{.raises: [].}`: since it is generic, the compiler infers the effects of `step` at instantiation and rejects a `step` that can raise. The library's test suite has a negative compilation test (`tests/tcompile_raises.nim`, using `not compiles(...)`) that locks this behavior in.

### `Verdict`

```nim
type
  VerdictKind* = enum vkLinearizable, vkNotLinearizable, vkInconclusive

  Alternative*[Res] = object
    candidate*: OpId     # operation tried as the next linearization point
    expected*: Res       # result the model expected
    observed*: Res       # result recorded in the history
    why*: string         # reason from the model

  Witness*[Op, Res] = object
    prefix*: seq[OpId]                  # longest linearized prefix found
    stuck*: OpId                        # first operation that fits no extension of the prefix
    stuckCall*: Op                      # what was requested in that operation
    stuckRes*: Res                      # what came back in that operation
    alternatives*: seq[Alternative[Res]] # each candidate tried at the failure point (like Knossos :final-paths)

  Verdict*[Op, Res] = object
    case kind*: VerdictKind
    of vkLinearizable:
      order*: seq[OpId]            # sequential order found
    of vkNotLinearizable:
      witness*: Witness[Op, Res]
    of vkInconclusive:
      statesExplored*: int         # states visited until the budget ran out
      budget*: int
```

Human-readable text comes from the `report` proc (below), not from a field.

Filling rules (D-20):

- **`order` is deterministic.** The search tries candidates in increasing `seq` of the `invoke`; `order` is the first linearization found in that order. The same history, model and `init` always give the same `order`.
- **Pending operations in `order`:** a pending operation the search treated as applied appears in `order`; one treated as not applied is left out.
- **`Witness`:** `prefix` is the longest prefix found (ties: the first in the order above); `stuck` is the first candidate (lowest `invoke` `seq`) at that point; `alternatives` is ordered by the candidate's `invoke` `seq`. Pending operations are never `stuck`, because they can always be treated as not applied.

## Procedures

### Recorder

Not implemented yet (M7). Exists only with `--threads:on`. Records `invoke`/`return` from several threads without contention on the hot path: each thread writes to its own buffer and the merge happens in `snapshot` (see [History](HISTORY.md#concurrent-recording-recorder)).

```nim
type Recorder*[Op, Res] = object   # not copyable (=copy disabled); share it by ptr

proc newRecorder*[Op, Res](threads: Positive): Recorder[Op, Res]
proc begin*[Op, Res](r: var Recorder[Op, Res], thread: int, call: Op): OpId {.raises: [].}
proc finish*[Op, Res](r: var Recorder[Op, Res], id: OpId, res: Res) {.raises: [].}
proc snapshot*[Op, Res](r: var Recorder[Op, Res]): History[Op, Res] {.raises: [ArgumentError].}
template record*(r: var Recorder, thread: int, call: untyped, body: untyped): untyped   # planned
```

- `threads`: number of threads that will record. `thread` in `begin` is an index in `0 ..< threads` (it becomes the event's `ThreadId`). Each index must be used by **one** thread only.
- `begin` takes the `invoke` `seq` **before** returning; call it before the real operation. `finish` takes the `return` `seq`; call it afterwards. See [event order](HISTORY.md#event-order).
- `begin`/`finish` do not raise and do not validate usage, to keep the hot path light. Errors (index out of range, `finish` twice, `finish` without `begin`) show up as `ArgumentError` in `snapshot`, which goes through `newHistory`.
- `snapshot` may only be called after every thread has finished (`joinThreads`). It does not clear the buffers; for the next round, create another recorder.
- Threads receive a `ptr Recorder` (`addr rec`); the recorder must outlive them. Full example in the [Guide](GUIDE.md#step-3-small-rounds).

### `checkLinearizable`

```nim
proc checkLinearizable*[S, Op, Res](
    h: History[Op, Res],
    init: S,
    model: typedesc,                # type that satisfies Model[S, Op, Res]
    budget = 1_000_000): Verdict[Op, Res] {.raises: [].}
```

- `init`: model state before the first operation of the history.
- `budget`: maximum number of states visited by the search. See [Budget](#budget).
- The search runs over a **graph**: it keeps the configurations already visited, both those that led to success and those that failed (D-11). A configuration that already failed is not explored again.
- Does not raise. Usage errors (invalid history) are handled in `newHistory`. The model's `step` must be `{.raises: [].}`; otherwise the code does not compile.

### `checkPartitioned` (planned, D-12, M11)

Used only when the model defines `partition` and the specification is P-compositional. The history is split and each part is checked separately, with the same `init`. The overall verdict is `vkLinearizable` only if every part is; `vkInconclusive` if some part is inconclusive and none is `vkNotLinearizable`.

| Field | Rule |
|---|---|
| `budget` | applies **per partition**, not to the total |
| `order` | the orders of each partition concatenated, in increasing key order; it is **not** a global real-time order |
| `witness` | the one from the failed partition whose `stuck` has the lowest `seq` |
| `statesExplored` | sum over every partition checked |
| `budget` (in the verdict) | the per-partition budget received |

```nim
proc checkPartitioned*[S, Op, Res](h: History[Op, Res], init: S,
    model: typedesc, budget = 1_000_000): Verdict[Op, Res] {.raises: [].}
```

The library does not check the partition's validity condition. Whoever writes the model is responsible for it. If the partition is invalid, the verdict may be wrong, and the library cannot detect that.

### `newHistory`

```nim
proc newHistory*[Op, Res](events: seq[Event[Op, Res]]): History[Op, Res] {.raises: [ArgumentError].}
```

Checks the invariants described above and sorts by `seq`.

### `report`

Not implemented yet (M5).

```nim
proc report*[Op, Res](v: Verdict[Op, Res]): string
```

Stable text, meant to be compared against a golden snapshot (`tests/golden/`). Ordered by `seq`, never by hash order. The same history produces the same text on every platform. Requires `$` for `Op` and `Res`.

### JSON: `toJsonLines` and `parseJsonLines`

```nim
proc toJsonLines*[Op, Res](h: History[Op, Res]): string
proc parseJsonLines*[Op, Res](s: string): History[Op, Res] {.raises: [ValueError, ArgumentError].}
```

Each event's `payload` is converted by two hooks the user can override:

```nim
proc toPayload*[T](x: T): JsonNode                     # default: `%`(x) from std/json
proc fromPayload*[T](n: JsonNode, t: typedesc[T]): T   # default: n.to(T)
```

The defaults work for simple objects. For an `object` with a `case` (variant), write both hooks, because `to` from `std/json` does not cover every case. Format in [History](HISTORY.md#saved-format-json). `parseJsonLines` raises `ValueError` for malformed JSON and `ArgumentError` for an invalid history.

## Budget

The search is exponential in the worst case. `budget` limits how many states (`(linearized, state)` pairs) are visited.

| History | Typical states | Suggested budget |
|---|---|---|
| 2 threads × 4 ops | < 1 000 | 100 000 |
| 3 threads × 5 ops | 1 000 – 50 000 | 1 000 000 |
| 4 threads × 8 ops | may exceed 1 000 000 | measure first; consider splitting the history |

These numbers are estimates to be confirmed in M4. Rule of thumb: if `vkInconclusive` shows up in a regression test, **do not raise the budget without measuring**. First shrink the history (fewer threads, fewer operations per round), because the problem is usually scale, not speed.

## Errors

| Situation | Behavior |
|---|---|
| history with a repeated `seq`, `return` before `invoke`, `return` without `invoke` or two open operations on the same thread | `ArgumentError` in `newHistory` (and in `parseJsonLines`, `Recorder.snapshot`) |
| malformed JSON | `ValueError` in `parseJsonLines` |
| `step` that can raise | compilation error: the contract requires `{.raises: [].}` (see [Models](MODELS.md#contract)) |
| budget exhausted | `vkInconclusive`, never `vkLinearizable` or `vkNotLinearizable` |
| empty history | `vkLinearizable` with an empty `order` |

## Compilation

- Works with `--threads:off` (sequential checker, useful to check saved histories). The concurrent recorder exists only with `--threads:on`; without threads, recorder tests use `skip()`.
- Tested with `--mm:orc` and `--mm:arc`, debug and release (CI requirement).
- Support: Nim 2.2.x and 2.4.x (the two current stable lines), on Linux, macOS and Windows.
