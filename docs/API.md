# API

> This page describes the API of version 0.1.0. Every later change to it is listed in `CHANGELOG.md`, marked **breaking** when names or signatures change.

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

A `History` is built only by `newHistory` (validated) or `subHistory` (a subset of a valid history), so every `History` value is valid.

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

# Documentation only: there is no `Model` type to import. A model is any
# type for which these calls compile (checked when checkLinearizable is
# instantiated):
#   step(M, S, Op): Expected[S, Res]               pure func, {.raises: [].}
#   (or outcomes(M, S, Op): seq[Expected[S, Res]], M14)
#   hash(S): Hash; `==`(S, S): bool; `==`(Res, Res): bool
```

There is no `Model` concept: the contract is enforced by the calls `checkLinearizable` makes, at compile time. A missing `hash`/`==` or a `step` that can raise is a compilation error at the call site (`tests/tcompile_raises.nim` locks the second one in).

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
    stuckEverFit*: bool                 # stuckRes matched the model in some explored configuration;
                                        # false: no order explains it (R16)

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
- **`order` of `checkPartitioned` (R13) is not a global order.** It is the concatenation of each part's `order`, parts in increasing key order (D-20). Within a part it respects real time; across parts it does not (an operation of key 2 can appear after a later operation of key 1). Every tick belongs to every part, so a tick appears once **per part**. A global order exists (linearizability is local), but `checkPartitioned` does not build one; to get it, run `checkLinearizable` on the history.
- **Pending operations in `order`:** a pending operation the search treated as applied appears in `order`; one treated as not applied is left out.
- **`Witness`:** `prefix` is the longest prefix found (ties: the first in the order above); `stuck` is the first candidate (lowest `invoke` `seq`) at that point; `alternatives` is ordered by the candidate's `invoke` `seq`. Pending operations are never `stuck`, because they can always be treated as not applied (also with `outcomes`: a pending operation with no outcome is simply not applied). A tick can be `stuck` only with `outcomes` returning nothing for it. If no candidate could be blamed, `stuck` is `OpId(0)`.

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

- `threads`: number of logical threads that will record. `thread` in `begin` is an index in `0 ..< threads` (it becomes the event's `ThreadId`). Each index must be used by one sequential caller at a time.
- `begin` takes the `invoke` `seq` **before** returning; call it before the real operation. `finish` takes the `return` `seq`; call it afterwards. See [event order](HISTORY.md#event-order).
- `begin`/`finish` do not raise, to keep the hot path light. Errors (index out of range, `finish` twice, `finish` without `begin`) show up as `ArgumentError` in `snapshot`.
- An index is a **logical** thread: `finish` may run on another OS thread than `begin` (an async task that resumed elsewhere). What is not allowed is two calls on the same index at the same time; each buffer has an atomic busy flag, and the second caller records misuse instead of writing (so it cannot corrupt the buffer).
- `record` = `begin`, then `body` (must give a `Res`), then `finish` with that result, which it returns. If `body` raises, `finish` is not called and the operation stays pending. See [History](HISTORY.md#concurrent-recording-recorder).
- `tick` records an instantaneous event with one `seq`. Call it right **after** advancing the fake clock, from the thread that advanced it. A bad `thread` index shows up as `ArgumentError` in `snapshot`, like the other misuses.
- `snapshot` may only be called after every thread has finished (`joinThreads`). It does not clear the buffers; for the next round, create another recorder.
- Threads receive a `ptr Recorder` (`addr rec`); the recorder must outlive them. Full example in the [Guide](GUIDE.md#step-3-small-rounds-with-runrounds).

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

For ticks, the condition also requires that a tick acts on each key independently (for example, aging every entry of a TTL map). The library does not check the partition's validity condition at run time by default. Compile with `-d:nimlinearVerifyPartition` to have `checkPartitioned` also run `checkLinearizable` on the whole history and raise `AssertionDefect` if the two definitive verdicts disagree (expensive; meant for validating a new `partition` on small histories, like the oracle). Whoever writes the model is responsible for it. If the partition is invalid, the verdict may be wrong, and the library cannot detect that.

### `newHistory`

```nim
proc newHistory*[Op, Res](events: seq[Event[Op, Res]]): History[Op, Res] {.raises: [ArgumentError].}
```

Checks the invariants described above and sorts by `seq`.

```nim
proc subHistory*[Op, Res](h: History[Op, Res], keep: HashSet[OpId]): History[Op, Res]
```

The operations of `h` whose id is in `keep`, with all their events. Removing whole operations keeps every invariant, so the result is valid by construction. `shrink` and `checkPartitioned` use it.

### `shrink` (M16)

```nim
proc shrink*[S, Op, Res](h: History[Op, Res], init: S, model: typedesc,
    budget = 1_000_000, partitioned = false,
    timeout = DurationZero): History[Op, Res] {.raises: [].}
```

Greedy, deterministic minimization of a `vkNotLinearizable` history: tries to drop whole threads, then single operations, and keeps a removal only if the history still fails **stuck on the same operation with the same expected result**, and with the same `stuckEverFit` (R16: dropping the only `enqueue(3)` must not turn a `dequeue() -> 3` in the wrong order into one no order explains). Returns `h` unchanged if it does not fail. The guard exists because removing an operation can create a failure that was not in the original (drop the only `write(1)` and a `read() -> 1` becomes unexplainable); it rejects most such removals but is a heuristic, not a proof (D-24). Inconclusive checks count as "not failing".

Cost: up to O(n²) checks for n operations, each with the full `budget`. `timeout` (zero = none) bounds the whole call: when it runs out, `shrink` returns the smallest history found so far (it still fails the same way). Each check gets what is left of the timeout. With a timeout the result depends on the machine; without one it is deterministic.

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
  timeout*: Duration             # per check; zero = none
  partitioned*: bool             # use checkPartitioned (model needs `partition`)
  shrink* = true                 # shrink the failing history
  shrinkTimeout*: Duration       # overall limit for shrink and replay; zero = none
  replayShrink*: bool            # also shrink by re-running the real code (D-27)
  schedule*: bool                # every round under the PCT scheduler (D-29); needs -d:nimlinearPerturb
  depth* = 3                     # PCT depth when schedule
  steps*: int                    # PCT steps when schedule; 0 = calibrate on round 1
  explore*: bool                 # enumerate the schedules of each round (D-32); needs -d:nimlinearPerturb
  preemptions* = 2               # explore: most preemptions per schedule
  maxSchedules* = 10_000         # explore: cap per round
  saveDir*: string               # "" = getTempDir()
  name* = "nimlinear"            # file name prefix

type RoundInfo* = object
  round*: int                    # 1-based
  seed*: int                     # roundSeed(cfg.seed, round)

proc runRounds*[I, Obj, Op, Res, SP](cfg: RoundsConfig, init: I, model: typedesc,
    setup: SP,                   # proc (obj: var Obj) or proc (obj: var Obj, info: RoundInfo)
    genOp: proc (rng: var Rand, thread, index: int): Op {.nimcall.},
    exec: proc (obj: ptr Obj, op: Op): Res {.nimcall, gcsafe.},
    teardown: proc (obj: var Obj) {.nimcall.} = nil,
    hooks = ThreadHooks(),
    quiescent: proc (obj: var Obj): string {.nimcall.} = nil): RoundsResult[Op, Res]
proc runRound*[...](cfg, round, setup, genOp, exec, teardown = nil, hooks): History[Op, Res]
proc runScenario*[...](cfg, round, ops: seq[seq[Op]], setup, exec, teardown = nil, hooks): History[Op, Res]
proc roundSeed*(seed, round: int): int
proc describe*[Op, Res](r: RoundsResult[Op, Res]): string
```

`runRounds`/`runRound` raise `ValueError` for `threads < 1`, `opsPerThread < 0` or `rounds < 0` (`validate`). Per round: a fresh `Obj` from `setup`; `opsPerThread` operations per thread from `genOp`, drawn on the main thread from a generator seeded with `roundSeed(seed, round)` (same seed, same operations; `index` helps make values unique); threads run `exec` through `Recorder.record`; `teardown`; check.

- `init` is the model's initial state, or `proc (round: int): S` to start each round from a different state (prepare the same state in `setup`).
- `setup` may take a second argument, `RoundInfo`: its `seed` is the per-round seed to give a `Scheduler` (`initScheduler(threads, info.seed)`), so each round gets its own PCT priorities.
- `roundSeed` mixes `(seed, round)` without overflow; different pairs give different seeds except by rare hash collision. `(seed, round)` is the only guaranteed identity of a round.
- `partitioned = true` checks with `checkPartitioned` (and shrinks with it); it raises `ValueError` if the model has no `partition`. `timeout` is passed to each check and, like in the checker, makes the verdict machine-dependent.
- `roundTimeout` (watchdog): a round still running after it, typically blocked outside the switch points (I/O, a `std/locks` lock, a join, a sleep), cannot be stopped, so `runRounds` writes `<name>-seed<s>-round<r>.hung.txt` (seed, per-round seed, operations per thread and, under `schedule`/`explore`, the last 50 switch points) to `saveDir`, prints where to stderr and ends the process with exit code 124. The `.inprogress` file (P13) stays too. Zero (default) = no watchdog. It makes the run machine-dependent, like `timeout`. Test: `tests/tprogress.nim`.
- `quiescent` (P15, optional): called once per round on the object after every thread finished and before `teardown`. A non-empty message (or a `CatchableError` it raises) fails the round even when the history is linearizable; the message is in `RoundsResult.invariant` and in `describe`. Use it for what results do not show: a reference count back to its initial value, no memory left allocated, an internal length that matches the contents. It sees only the end of the round, not a transient violation, and its value is that of the invariant written.
- An exception (`CatchableError`) raised by `exec` fails the round: the operation stays pending, that thread runs no more operations, `ThreadHooks.leave` and `teardown` still run, and `RoundsResult.error` holds `thread, operation index, call, exception name and message`. `runRound` raises `ExecError` instead. A `Defect` is not caught.
- It stops at the first round that fails (`exec` raised, or not `vkLinearizable`), shrinks the history (unless inconclusive or `shrink = false`; bounded by `shrinkTimeout`), and saves it as `<saveDir>/<name>-seed<seed>-round<r>.jsonl`; if that file exists, `-2`, `-3`... is appended, so an earlier file is never overwritten. If saving fails, `savedTo` is `""` and `saveError` says why.

**Built-in scheduler (D-29).** With `schedule = true` (compile with `-d:nimlinearPerturb`), every round runs under a PCT `Scheduler` seeded with `RoundInfo.seed`: installed after `setup`, removed before `teardown`, threads registered for you (passing `ThreadHooks` too raises `ValueError`). `steps = 0` calibrates: round 1's operations run once and the switch points counted (`Scheduler.stepsTaken`) become `steps`, returned in `RoundsResult.steps` and shown by `describe`. To replay a round with `runScenario`, pass that `steps`.

**Bounded exhaustive exploration (D-32).** With `explore = true` (compile with `-d:nimlinearPerturb`; not together with `schedule`), each round's operations run under **every** schedule over the controlled switch points (`perturb()`, `SchedLock`, `SchedCond.wait`, and the `nimlinear/intercept` operations), depth-first with replay, as long as a schedule has at most `preemptions` preemptions (stopping a thread that could have gone on). Each schedule is checked; the first failing one stops the run.

- `RoundsResult.explored` counts the schedules run; `complete` is true when every round ran all its schedules within the bound (false when `maxSchedules` cut a round, or on failure); `schedule` is the thread chosen at each decision of the failing schedule. The same config gives the same schedules in the same order, so a failure repeats exactly.
- "Exhaustive" is relative to the switch points and to `preemptions`: plain fields, code between two points and relaxed memory stay outside. A bug that needs more preemptions than the bound is not reached (`preemptions = 0` runs only serial schedules).
- The code under test must be deterministic given the schedule. If a forced choice is not runnable on replay, the run stops with `error` set ("not deterministic") instead of claiming coverage.
- `reduce = true` (sleep sets): skips schedules that only reorder independent steps. A step is the code from one switch point to the next; its footprint is the object of the intercepted operation it starts with (address, read or write), plus every `release`, `signal`/`broadcast` and recorded invoke/return in it (the history is shared, so steps at operation boundaries never commute). A `perturb()` or a `wait` has no known object and conflicts with everything. Needs `-d:nimlinearInterceptLoads` (otherwise loads are accesses the reduction cannot see; `ValueError`), and assumes shared plain fields are accessed only under a lock or through `Shared[T]`. Measured on `nim-lang/threading` `Chan`: same verdicts and same failing schedules; 3 threads × 2 operations went from 3 861 to 3 376 schedules (bug) and 37 992 to 34 479 (control), 2 threads × 3 operations did not change. Sleep sets alone prune little when most steps touch the history or the same fields; full DPOR would prune more and is not implemented. `noteAccess(obj, write)` (`nimlinear/schedule`) adds an access the scheduler cannot see to the running step. Test: `tests/treduce.nim`.
- The count grows fast with threads, operations and switch points; keep scenarios small (2–3 threads, 2–3 operations each) and use PCT (`schedule`) for larger ones. `replayShrink` is skipped under `explore`.
- In `nimlinear/schedule`: `initScheduler(..., explore = true, forced = choices)` runs choice `i` at decision `i` and the default (the current thread if it can go on, else the lowest index) after them; `decisions(s)` returns each `Decision` (`options` in exploration order, `chosen`, `current`), `diverged(s)` says a forced choice was not runnable. Test: `tests/texplore.nim`.

**Replay shrink (D-27).** With `replayShrink = true`, after the history-only shrink, `runRounds` shrinks the failing round's **scenario** (its operations per thread) by running the real code again:

- `runScenario(cfg, round, ops, ...)` runs one round from explicit operation lists (`ops[t]` on thread `t`, `ops.len == threads`); `setup` gets the same `RoundInfo` as that round of `runRounds`.
- First the failing scenario runs again; if the new history differs from the recorded one (byte for byte in JSON), replay is skipped and `replay` says the round is not deterministic. In practice that means: use it under `nimlinear/schedule`.
- Then whole threads, then single operations are removed greedily (those the history-only shrink dropped first). A removal is kept only if the real execution still fails with the same stuck operation (same thread, call and expected result, D-24).
- On success, `scenario` is the reduced scenario, and `history`/`verdict` are a **real execution** of it; `runScenario(cfg, rounds, scenario, ...)` reproduces it. Bounded by `shrinkTimeout`; each attempt is a full round.
- Removing an operation shifts the scheduler's change points, so the bug can move and a removal be rejected for that reason: the result is reproducible, not minimal. The history-only `shrink` usually gives a smaller history; `original` keeps the recorded one.

`RoundsResult` has `passed`, `rounds`, `seed`, `error`, `verdict`, `history` (shrunk), `original`, `scenario`, `replay`, `savedTo`, `saveError` and `previousRun` (P13: the contents of a `<saveDir>/<name>-seed<s>.inprogress` file left by a run that died; `runRounds` rewrites that file before each round and removes it at the end unless `trackProgress = false`; `progressPath(cfg)` gives its path), `trace`/`traceDropped`/`traceSavedTo` (under `schedule`, the switch points of the failing round, P12: `describe` shows the last 30, and the whole trace is saved as `<name>-seed<s>-round<r>.trace.txt`; `formatTrace(trace, dropped, last)` prints it; it is the trace of the recorded round, not of the shrunk history), `originalSavedTo` (the recorded history, saved as `<name>-seed<s>-round<r>.original.jsonl` next to the shrunk one when they differ); `describe` prints all of it with the timeline. `ThreadHooks(enter, leave)` run at the start and end of each thread, for `nimlinear/schedule`; `leave` runs even if `exec` raised.

`warnings` lists signs that a run tested less than it seems, and `describe` prints them as `warning:` lines, on pass and on failure:
- the run used the OS scheduler only (no `schedule`, no `explore`, no `-d:nimlinearPerturb` or `-d:nimlinearStrict`);
- `schedule` calibrated round 1 to zero switch points (the code under test is not intercepted in this build);
- `explore` passed with a single schedule per round.

`originalVerdict` is the verdict of `original`. When the shrunk history has 3 operations or fewer and the recorded one has more, `describe` also prints the recorded history's timeline, because a tiny shrunk history can look impossible without its context. A failing schedule longer than 60 decisions is printed as its last 60 (the whole one stays in `schedule`). Test: `tests/tstrict.nim`, `tests/tusability.nim`. Example: [`examples/queue_race.nim`](../examples/queue_race.nim).

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
- One scheduler at a time: `initScheduler` raises `ValueError` while another one is installed.
- Same seed, same threads, same code: same interleaving, so the `Recorder` history is the same byte for byte.
- **Rule:** between `enter` and `leave`, a thread must not block in the OS waiting for another registered thread (no joins, no blocking reads, no `perturb()` while holding a plain `Lock` others take). Otherwise the round hangs. Locks of the object under test should be `SchedLock`.
- Switches happen only at `perturb()`, `enter`, `leave`, `SchedLock.acquire` and `SchedCond.wait`. Code between two points runs atomically under the scheduler: a bug whose window has no point is not explored.
- `SchedLock` (M19): a lock that cooperates with the scheduler. Under an active scheduler, `acquire` is a switch point and, if the lock is held, the thread waits by yielding (it is not picked again until the lock is free). Without a scheduler it is an ordinary `Lock`. Use it for the locks of the object under test; then `perturb()` inside critical sections is safe. If every unfinished thread waits on a held `SchedLock`, the code under test deadlocked: the scheduler sets `deadlocked = true` and wakes one waiter so the round ends.

```nim
type SchedLock* = object
proc initSchedLock*(l: var SchedLock)
proc deinitSchedLock*(l: var SchedLock)
proc acquire*(l: var SchedLock) {.raises: [].}
proc release*(l: var SchedLock) {.raises: [].}
template withLock*(l: var SchedLock, body: untyped)
```

- `SchedCond`: a condition variable used with a `SchedLock`. Under an active scheduler, `wait` releases the lock, marks the thread as waiting (it is not picked again until `signal` or `broadcast` wakes it) and takes the lock again; it is a switch point. `signal` wakes the waiting thread with the lowest index (deterministic); `signal` and `broadcast` are not switch points. Without a scheduler it is an ordinary `Cond`. From an unregistered thread under a scheduler, `wait` returns at once (a spurious wakeup; callers re-check in a loop). If every unfinished thread waits, `deadlocked` is set and the highest-priority waiter wakes spuriously; a lost wakeup in the code under test then loops in its wait loop, as it would hang without the scheduler.

```nim
type SchedCond* = object
proc initSchedCond*(c: var SchedCond)
proc deinitSchedCond*(c: var SchedCond)
proc wait*(c: var SchedCond, l: var SchedLock) {.raises: [].}
proc signal*(c: var SchedCond) {.raises: [].}
proc broadcast*(c: var SchedCond) {.raises: [].}
```

- **Stuck rounds (P14):** `initScheduler(..., abortOnStuck = true, stepLimit = n)` aborts a round that cannot end: when every unfinished thread waits on a `SchedLock` or a `SchedCond` (deadlock, including a lost wakeup), or past `n` switch points (livelock, or a spin-wait that never sees its condition). Every registered thread then raises `RoundAborted` (a `Defect`, so it needs the default `--panics:off`) at its next switch point, and `abortReason(s)` says why. `runRounds` turns it on under `schedule` and `explore` (`RoundsConfig.stepLimit`, default 1 000 000; 0 = no limit) and catches it: the round fails with `error` = "round aborted by the scheduler: ..." and its seed (or schedule). Without `abortOnStuck` the old behavior stays: `deadlocked` is set and a waiter wakes spuriously. A thread blocked outside the switch points (I/O, a `std/locks` lock, a join) is not seen: it still hangs. Test: `tests/tliveness.nim`.
- **Trace (P12):** the scheduler records every switch point of the round as a `SwitchPoint` (`step`, `thread`, `kind` such as `"perturb"`, `"load"`, `"store"`, `"acquire"`, `"wait"`, and the `file`/`line` of the call in the code under test). `trace(s)` returns it, `traceDropped(s)` counts points beyond `traceCap` (100 000). `perturb()`, the `nimlinear/intercept` wrappers, `acquire`, `tryAcquire`, `withLock` and `wait` are templates so the location is the caller's; an operation called through a helper proc of the code under test reports the helper's line. The trace belongs to the scheduler only; the checker and the history format do not carry it (D-30).
- Example: [`examples/queue_pct.nim`](../examples/queue_pct.nim); `SchedLock` test: `tests/tschedule.nim`; `SchedCond` test: `tests/tschedcond.nim`.

### `nimlinear/intercept` (P6)

Switch points on atomics and locks without `perturb()` in the code under test (D-26). A drop-in replacement for `std/atomics` and `std/locks`; the code under test switches its import in one place, behind a define of its own:

```nim
when defined(nimlinearIntercept): import nimlinear/intercept
else: import std/[atomics, locks]
```

Compile the test with `-d:nimlinearIntercept -d:nimlinearStrict` and run rounds under a `Scheduler` (as for `perturb()`). Production builds never import nimlinear.

- **`-d:nimlinearStrict`** is the recommended test define. Inside nimlinear it counts as both `-d:nimlinearPerturb` and `-d:nimlinearInterceptLoads`, so writes, read-modify-writes, loads, locks and conditions are all switch points. The finer defines below still work alone. With loads intercepted, a spin-wait loop cannot run under `schedule` or `explore` (the round ends at `stepLimit` with a message saying so); test such code with random perturbation.

- Without `-d:nimlinearPerturb`: a plain re-export of both modules, no cost.
- With it: a `perturb()` before every atomic write or read-modify-write (`store`, `exchange`, `compareExchange`, `compareExchangeWeak`, `fetchAdd`, `fetchSub`, `fetchAnd`, `fetchOr`, `fetchXor`, `atomicInc`, `atomicDec`, `+=`, `-=`, `testAndSet`, `clear`), and `Lock` is a `SchedLock` (`initLock`, `deinitLock`, `acquire`, `tryAcquire`, `release`, `withLock` keep their names).
- Loads get no point by default; plain (non-atomic) fields are not intercepted, so a race on a plain field shows up only if an intercepted operation sits inside its window.
- `-d:nimlinearInterceptLoads` (opt-in) also puts a point before every atomic `load`. It opens windows between two loads with no write between them (read `head`, read `tail`, decide). Opt-in because loads sit in spin-wait loops: under the PCT scheduler, a high-priority thread spinning on a load can wait forever for a lower-priority one. Use it with random perturbation (no scheduler, `schedule = false`) or on code without spin waits.
- `Cond` is a `SchedCond` (`initCond`, `deinitCond`, `wait`, `signal`, `broadcast` keep their names), so code with condition variables runs under the scheduler. `-d:nimlinearInterceptNoLocks` keeps `Lock` and `Cond` from `std/locks` and intercepts atomics only; a point inside a critical section can then hang a round under the scheduler, so use it with random perturbation.
- Use `RoundsConfig(schedule: true)`: `steps` is calibrated to the real number of switch points of a round (D-29). If you wire the scheduler yourself, `steps` must be close to `Scheduler.stepsTaken` of a typical round, **not larger**: change points beyond the end of the round never fire, and a guess of 200 against a real 11 made an injected bug 18 to 37 times rarer ([Measurements](MEASUREMENTS.md#intercepted-atomics-and-locks-p6)). `depth` 3 to 4.
- **Other atomics modules (P18): `interceptAtomics`.** The drop-in replaces only `std/atomics` and `std/locks`. For a library with its own atomics module (for example `nim-lang/threading`'s `threading/atomics`, where `Atomic[T]` is a `distinct T` and orderings are a `{.pure.}` enum `Ordering`), write a small shim and import it instead of the original:
  ```nim
  # myatomics.nim
  import threading/atomics as ta
  import nimlinear/intercept
  interceptAtomics(ta,
    writes = [store, exchange, compareExchange, compareExchangeWeak, fetchAdd, fetchSub,
              fetchAnd, fetchOr, fetchXor, atomicInc, atomicDec, `+=`, `-=`],
    reads = [load], types = [Ordering])
  ```
  Without `-d:nimlinearPerturb` the macro expands to `export ta` (no cost). With it, each listed proc becomes a template that puts a switch point on its first argument (the atomic location, so `reduce` sees the object) and calls the original with the same arguments; the trace shows the caller's line. `reads` get a point only with `-d:nimlinearInterceptLoads`, as `load` above. List in `types` any `{.pure.}` enum the code uses unqualified: Nim's `export m except ...` hides its values otherwise (`Acquire` would need `Ordering.Acquire`). Only code that imports the shim is intercepted; files of the library that import the original module directly are not. Checked on `threading/atomics` at `nim-lang/threading` 653c8eb (a load-then-store race found, a CAS loop passing; there the module is deprecated and `smartptrs`/`channels` already import `std/atomics`). Test: `tests/tintercept_custom.nim`.
- **`Shared[T]`** for plain fields: declare the field as `Shared[T]` and access it as `x[]` / `x[] = v`. With `-d:nimlinearPerturb` every read and write is a switch point (and an access for `reduce`); without it, `Shared[T]` is a plain object of the same size with inline accessors. Production code that does not import nimlinear can define the same type itself:
  ```nim
  when defined(nimlinearIntercept): import nimlinear/intercept
  else:
    type Shared[T] = object
      v: T
    template `[]`[T](s: Shared[T]): T = s.v
    template `[]=`[T](s: var Shared[T], x: T) = s.v = x
  ```
  Reads of a `Shared` are always switch points (unlike atomic loads), so a spin-wait on a `Shared` field needs `explore` or random perturbation rather than PCT. Test: `tests/tshared.nim`.
- **Plain fields are not intercepted.** A race on a non-atomic field (for example a counter read under one lock and written under another, or read without the lock) is explored only if an intercepted operation or a `perturb()` falls inside its window. Put a `perturb()` between the read and the write of such fields:
  ```nim
  let n = b.consecutive          # plain field
  perturb()                      # the window intercept cannot see
  b.consecutive = n + 1
  ```

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
