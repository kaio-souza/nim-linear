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

A **tick** (M10) is a third kind: an instantaneous operation with a single event and no `return`, linearized exactly at its `seq`. It is meant for clock advances (see [History](HISTORY.md#time)). Its `call` goes through the model's `step` like any operation; the result `step` returns is not compared with anything.

```nim
type
  EventKind* = enum ekInvoke, ekReturn, ekTick

  Event*[Op, Res] = object
    op*: OpId
    thread*: ThreadId
    seqNo*: SeqNo                 # called `seq` in prose and in JSON (D-19)
    case kind*: EventKind
    of ekInvoke, ekTick: call*: Op  # what was requested
    of ekReturn: res*: Res        # what came back
```

### `History`

```nim
type History*[Op, Res] = object   # fields private (M24)

func events*[Op, Res](h: History[Op, Res]): lent seq[Event[Op, Res]]   # ordered by seq, read-only
```

A `History` is built only by `newHistory` (validated) or `newHistoryUnchecked` (see below), so it cannot be assembled by hand and skip validation.

Invariants, checked by `newHistory` (a history that violates any of them is rejected with `ArgumentError` at construction, not at check time):

1. `seq` is unique across the whole history;
2. each `OpId` has exactly one `invoke` and at most one `return`, or exactly one `tick` and no other event;
3. `invoke.seq < return.seq`, and both have the same `thread`;
4. a thread does not invoke a new operation while it has another one without a `return` (each thread is sequential). A tick does not open its thread: it may be recorded by any thread at any time.

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
proc tickEvent*[Op, Res](op, thread, seqNo: int, call: Op): Event[Op, Res]     # M10
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

Instead of `step`, a model may define `outcomes` (M14), for nondeterministic specifications:

```nim
func outcomes(m: typedesc[M], s: S, op: Op): seq[Expected[S, Res]] {.raises: [].}   # every allowed (next, res)
template hasOutcomes*(model: typedesc, S, Op: typedesc): bool                       # true if it compiles
```

Semantics in [Models](MODELS.md#nondeterministic-specifications-outcomes-m14).

The model is a **type** (passed as a `typedesc`), not a value. The initial state is passed separately, to `checkLinearizable`, because it usually depends on the test setup (for example, the capacity of a bounded queue).

`why` is used only for diagnostics (D-14). It plays no part in deciding linearizability.

`partition` (D-12) is optional and used only by `checkPartitioned`. When present, it has this signature:

```nim
func partition(m: typedesc[M], op: Op): K {.raises: [].}   # partition key of the operation
```

`K` is any type with `hash`, `==` and `<` (M21): `int`, `string`, a tuple of them. `<` orders the parts (D-20).

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
      statesExplored*: int         # states visited until the budget (or timeout) stopped the search
      budget*: int
      timedOut*: bool              # true: stopped by `timeout` (M20), not by `budget`
```

Human-readable text comes from the `report` proc (below), not from a field.

Filling rules (D-20):

- **`order` is deterministic.** The search tries candidates in increasing `seq` of the `invoke`; `order` is the first linearization found in that order. The same history, model and `init` always give the same `order`.
- **Pending operations in `order`:** a pending operation the search treated as applied appears in `order`; one treated as not applied is left out.
- **`Witness`:** `prefix` is the longest prefix found (ties: the first in the order above); `stuck` is the first candidate (lowest `invoke` `seq`) at that point; `alternatives` is ordered by the candidate's `invoke` `seq`. Pending operations are never `stuck`, because they can always be treated as not applied.

## Procedures

### Recorder

Implemented (M7). Exists only with `--threads:on`. Records `invoke`/`return` from several threads without locks on the hot path: each thread writes to its own buffer, `seq` numbers come from a shared atomic counter, the thread is encoded in the `OpId`, and `snapshot` merges by `seq` (see [History](HISTORY.md#concurrent-recording-recorder)).

```nim
type Recorder*[Op, Res] = object   # not copyable (=copy disabled); share it by ptr

proc newRecorder*[Op, Res](threads: Positive): Recorder[Op, Res]
proc begin*[Op, Res](r: var Recorder[Op, Res], thread: int, call: Op): OpId {.raises: [].}
proc finish*[Op, Res](r: var Recorder[Op, Res], id: OpId, res: Res) {.raises: [].}
proc tick*[Op, Res](r: var Recorder[Op, Res], thread: int, call: Op): OpId {.raises: [].}   # M10
template record*[Op, Res](r: var Recorder[Op, Res], thread: int, call: Op, body: untyped): Res
proc snapshot*[Op, Res](r: var Recorder[Op, Res]): History[Op, Res] {.raises: [ArgumentError].}
```

- `threads`: number of threads that will record. `thread` in `begin` is an index in `0 ..< threads` (it becomes the event's `ThreadId`). Each index must be used by **one** thread only.
- `begin` takes the `invoke` `seq` **before** returning; call it before the real operation. `finish` takes the `return` `seq`; call it afterwards. See [event order](HISTORY.md#event-order).
- `begin`/`finish` do not raise and do not validate usage, to keep the hot path light. Errors (index out of range, `finish` twice, `finish` without `begin`) show up as `ArgumentError` in `snapshot`, which goes through `newHistory`.
- `record` = `begin`, then `body` (must give a `Res`), then `finish` with that result, which it returns. If `body` raises, `finish` is not called and the operation stays pending. See [History](HISTORY.md#concurrent-recording-recorder).
- `tick` records an instantaneous event with one `seq`. Call it right **after** advancing the fake clock, from the thread that advanced it. A bad `thread` index shows up as `ArgumentError` in `snapshot`, like the other misuses.
- `snapshot` may only be called after every thread has finished (`joinThreads`). It does not clear the buffers; for the next round, create another recorder.
- Threads receive a `ptr Recorder` (`addr rec`); the recorder must outlive them. Full example in the [Guide](GUIDE.md#step-3-small-rounds).

### `checkLinearizable`

```nim
proc checkLinearizable*[S, Op, Res](
    h: History[Op, Res],
    init: S,
    model: typedesc,                # type that satisfies Model[S, Op, Res]
    budget = 1_000_000,
    timeout = DurationZero): Verdict[Op, Res] {.raises: [].}
```

- `init`: model state before the first operation of the history.
- `timeout` (M20, `std/times`): wall-clock limit; zero means none. When reached, the verdict is `vkInconclusive` with `timedOut = true`. Checked every 256 visited states. A timeout makes the verdict depend on the machine; `budget` does not, so prefer it in regression tests.
- `budget`: maximum number of states visited by the search. See [Budget](#budget).
- The search runs over a **graph**: it keeps the configurations already visited, both those that led to success and those that failed (D-11). A configuration that already failed is not explored again.
- Does not raise. Usage errors (invalid history) are handled in `newHistory`. The model's `step` must be `{.raises: [].}`; otherwise the code does not compile.

### `checkPartitioned`

Implemented (M11, D-12). Used only when the model defines `partition` and the specification is P-compositional. The history is split and each part is checked separately, with the same `init`. Ticks (M10) have no key: each one is copied into **every** part, and `partition` is never called for them. The overall verdict is `vkLinearizable` only if every part is; `vkInconclusive` if some part is inconclusive and none is `vkNotLinearizable`.

| Field | Rule |
|---|---|
| `budget` | applies **per partition**, not to the total |
| `order` | the orders of each partition concatenated, in increasing key order; it is **not** a global real-time order. A tick appears once per partition |
| `witness` | the one from the failed partition whose `stuck` has the lowest `seq` |
| `statesExplored` | sum over every partition (all of them are checked, even after a failure) |
| `budget` (in the verdict) | the per-partition budget received |

```nim
proc checkPartitioned*[S, Op, Res](h: History[Op, Res], init: S,
    model: typedesc, budget = 1_000_000, timeout = DurationZero): Verdict[Op, Res] {.raises: [].}
```

`timeout` applies to the whole call (one deadline shared by every part); after a part times out, the remaining parts are not checked.

For ticks, the condition also requires that a tick acts on each key independently (for example, aging every entry of a TTL map). The library does not check the partition's validity condition. Whoever writes the model is responsible for it. If the partition is invalid, the verdict may be wrong, and the library cannot detect that.

### `newHistory`

```nim
proc newHistory*[Op, Res](events: seq[Event[Op, Res]]): History[Op, Res] {.raises: [ArgumentError].}
```

Checks the invariants described above and sorts by `seq`.

```nim
func newHistoryUnchecked*[Op, Res](events: seq[Event[Op, Res]]): History[Op, Res]
```

No validation and no sorting. Only for events taken from a valid history (a subset of its operations, or valid parts merged in `seq` order), as `shrink` and `checkPartitioned` do internally.

### `shrink` (M16)

```nim
proc shrink*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
    budget = 1_000_000, partitioned = false): History[Op, Res] {.raises: [].}
```

Greedy, deterministic minimization of a `vkNotLinearizable` history: tries to drop whole threads, then single operations, and keeps a removal only if the history still fails **stuck on the same operation with the same expected result**. Returns `h` unchanged if it does not fail. The guard exists because removing an operation can create a failure that was not in the original (drop the only `write(1)` and a `read() -> 1` becomes unexplainable); it rejects most such removals but is a heuristic, not a proof (D-24). Inconclusive checks count as "not failing".

### `report`

```nim
proc report*[Op, Res](v: Verdict[Op, Res]): string
```

Stable text, meant to be compared against a golden snapshot (`tests/golden/`). Ordered by `seq`, never by hash order. The same history produces the same text on every platform. Requires `$` for `Op` and `Res`. For `vkInconclusive` stopped by a timeout, it adds `stopped by: timeout`.

### Timeline (M18)

```nim
proc timeline*[Op, Res](h: History[Op, Res], v: Verdict[Op, Res]): string
proc report*[Op, Res](v: Verdict[Op, Res], h: History[Op, Res]): string       # report(v) & timeline(h, v)
proc timelineHtml*[Op, Res](h: History[Op, Res], v: Verdict[Op, Res]): string # standalone page
const timelineLimit* = 400
```

`timeline` draws one row per thread, one column per event in `seq` order: `[` invoke, `]` return, `=` in between, `>` pending, `|` tick (own row). A legend lists every operation with thread, `seq` range, call, result and its role in the verdict: `#k` (position in `order`), `prefix #k`, `STUCK`, or `not applied` (pending left out). Above `timelineLimit` events only the legend is printed. Stable text (golden: `tests/golden/register_timeline.txt`):

```
timeline:
  thread 0  [==]  []
  thread 1   []  [=>
  ticks         |
operations:
  op 1 (thread 0, seq 1-4): write(1) -> (value: 0, ok: true)  [prefix #2]
  op 2 (thread 1, seq 2-3): read() -> (value: 0, ok: true)  [prefix #1]
  op 9 (tick, seq 5): read()  [prefix #3]
  op 3 (thread 1, seq 6-): write(5) -> pending  [prefix #4]
  op 4 (thread 0, seq 7-8): read() -> (value: 7, ok: true)  [STUCK]
```

`timelineHtml` returns a self-contained HTML page (inline SVG, no external resources): operations as colored bars (linearized, stuck, other, pending; ticks as dashed lines), with call and result on hover, and the text report below.

### Round harness (M17)

Exists only with `--threads:on` (module `nimlinear/rounds`, re-exported by `nimlinear`).

```nim
type RoundsConfig* = object
  threads* = 3; rounds* = 100; opsPerThread* = 4; seed* = 1
  budget* = 1_000_000
  shrink* = true                 # shrink the failing history
  saveDir*: string               # "" = getTempDir()
  name* = "nimlinear"            # file name prefix

proc runRounds*[S, Obj, Op, Res](cfg: RoundsConfig, init: S, model: typedesc,
    setup: proc (obj: var Obj) {.nimcall.},
    genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
    teardown: proc (obj: var Obj) {.nimcall.} = nil,
    hooks = ThreadHooks()): RoundsResult[Op, Res]
proc runRound*[...](cfg, round, setup, genOp, exec, teardown = nil, hooks): History[Op, Res]
proc describe*[Op, Res](r: RoundsResult[Op, Res]): string
```

Per round: a fresh `Obj` from `setup`; `opsPerThread` operations per thread from `genOp`, drawn on the main thread from a generator seeded with `(seed, round)` (same seed, same operations; `index` helps make values unique); threads run `exec` through `Recorder.record`; `teardown`; check. It stops at the first round that is not `vkLinearizable`, shrinks the history (unless inconclusive or `shrink = false`), and saves it as `<saveDir>/<name>-seed<seed>-round<r>.jsonl`. `RoundsResult` has `passed`, `rounds`, `seed`, `verdict`, `history` (shrunk), `original` and `savedTo`; `describe` prints all of it with the timeline. `ThreadHooks(enter, leave)` run at the start and end of each thread, for `nimlinear/schedule`. Example: [`examples/queue_race.nim`](../examples/queue_race.nim).

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

The defaults work for simple objects. For an `object` with a `case` (variant), write both hooks, because `to` from `std/json` does not cover every case. Format in [History](HISTORY.md#saved-format-json). `toJsonLines` writes the version line `{"nimlinear":1}` first (`const formatVersion* = 1`, M15). `parseJsonLines` accepts files with or without it, and raises `ValueError` for malformed JSON, an unknown version or a version line that is not the first line, and `ArgumentError` for an invalid history.

## Optional modules

Not imported by `nimlinear`; whoever does not import them pays nothing (D-18).

### `nimlinear/perturb` (M12)

```nim
template perturb*()                                         # perturbation point
proc setPerturbation*(enabled: bool, seed = 0) {.raises: [].}
```

- Without `-d:nimlinearPerturb`, `perturb()` is an empty template and `setPerturbation` does nothing.
- With the flag, each `perturb()` draws from a per-thread generator seeded from `seed`: nothing (50%), a short `cpuRelax` spin (25%) or `sleep(0)` (25%). Enabled by default; `setPerturbation(false)` turns the draw off at run time (useful to compare in one binary). The OS still picks the interleaving, so a seed does not reproduce a run.
- Place points where another thread acting would matter, typically between reading and changing shared state. Example: [`examples/queue_perturb.nim`](../examples/queue_perturb.nim).

### `nimlinear/schedule` (M13)

Requires `--threads:on` and `-d:nimlinearPerturb`.

```nim
type Scheduler* = object          # not copyable; one active at a time

proc initScheduler*(s: var Scheduler, threads: Positive, seed: int, depth = 3, steps = 100)
proc deinitScheduler*(s: var Scheduler)
proc enter*(s: var Scheduler, thread: int) {.raises: [].}   # first call in each thread
proc leave*(s: var Scheduler) {.raises: [].}                 # last call in each thread
```

- Only one registered thread runs at a time; threads switch only at `perturb()`, `enter` and `leave`. While a scheduler is installed, `perturb()` is its switch point instead of a random draw.
- Choice of the next thread: PCT. Each thread gets a random distinct priority; the highest-priority unfinished thread runs; at `depth - 1` steps drawn from `1 .. steps`, the running thread drops below every initial priority.
- Same seed, same threads, same code: same interleaving, so the `Recorder` history is the same byte for byte.
- **Rule:** between `enter` and `leave`, a thread must not block in the OS waiting for another registered thread (no joins, no blocking reads, no `perturb()` while holding a plain `Lock` others take). Otherwise the round hangs. Locks of the object under test should be `SchedLock`.
- Switches happen only at `perturb()`, `enter`, `leave` and `SchedLock.acquire`. Code between two points runs atomically under the scheduler: a bug whose window has no point is not explored.
- `SchedLock` (M19): a lock that cooperates with the scheduler. Under an active scheduler, `acquire` is a switch point and, if the lock is held, the thread waits by yielding (it is not picked again until the lock is free). Without a scheduler it is an ordinary `Lock`. Use it for the locks of the object under test; then `perturb()` inside critical sections is safe. If every unfinished thread waits on a held `SchedLock`, the code under test deadlocked: the scheduler sets `deadlocked = true` and wakes one waiter so the round ends.

```nim
type SchedLock* = object
proc initSchedLock*(l: var SchedLock)
proc deinitSchedLock*(l: var SchedLock)
proc acquire*(l: var SchedLock) {.raises: [].}
proc release*(l: var SchedLock) {.raises: [].}
template withLock*(l: var SchedLock, body: untyped)
```

- Example: [`examples/queue_pct.nim`](../examples/queue_pct.nim); `SchedLock` test: `tests/tschedule.nim`.

## Budget

The search is exponential in the worst case. `budget` limits how many states (`(linearized, state)` pairs) are visited.

| History | Typical states | Suggested budget |
|---|---|---|
| 2 threads × 4 ops | < 1 000 | 100 000 |
| 3 threads × 5 ops | 1 000 – 50 000 | 1 000 000 |
| 4 threads × 8 ops | may exceed 1 000 000 | measure first; consider splitting the history |

These numbers are still estimates; preliminary measurements of one history shape are in [Measurements](MEASUREMENTS.md). Rule of thumb: if `vkInconclusive` shows up in a regression test, **do not raise the budget without measuring**. First shrink the history (fewer threads, fewer operations per round), because the problem is usually scale, not speed.

## Errors

| Situation | Behavior |
|---|---|
| history with a repeated `seq`, `return` before `invoke`, `return` without `invoke`, a `return` for a tick, a reused tick id, or two open operations on the same thread | `ArgumentError` in `newHistory` (and in `parseJsonLines`, `Recorder.snapshot`) |
| malformed JSON | `ValueError` in `parseJsonLines` |
| `step` that can raise | compilation error: the contract requires `{.raises: [].}` (see [Models](MODELS.md#contract)) |
| budget exhausted | `vkInconclusive`, never `vkLinearizable` or `vkNotLinearizable` |
| empty history | `vkLinearizable` with an empty `order` |

## Compilation

- Works with `--threads:off` (sequential checker, useful to check saved histories). The concurrent recorder exists only with `--threads:on`; without threads, recorder tests use `skip()`.
- Tested with `--mm:orc` and `--mm:arc`, debug and release (CI requirement).
- Support: Nim 2.2.x and 2.4.x (the two current stable lines), on Linux, macOS and Windows.
