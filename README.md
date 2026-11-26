# nimlinear

[![CI](https://github.com/kaio-souza/nim-linear/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/kaio-souza/nim-linear/actions/workflows/ci.yml)

**Linearizability testing for concurrent Nim code.** nimlinear runs your real object from several threads, records every call and its result, and checks that the results could have come from *some* sequential order of those calls. When they could not, it tells you which operation broke the order, shows the interleaving, shrinks the failing case and saves it to a file you can replay.

Stdlib only. Nim 2.2.0 or newer. MIT license.

```
not linearizable
stuck: op 5
call: dequeue()
result: value(100)
alternatives:
  - op 5: expected value(0), observed value(100)
timeline:
  thread 0  [][=][=]
  thread 1     [==]
```

## Features

- **Checker**: decides whether a history of concurrent calls is linearizable against a sequential model (Wing & Gong search with memoization, as in Porcupine). Exact answer, a state budget and an optional timeout, deterministic reports.
- **Round harness**: `runRounds` generates operations from a seed, runs them on your object from real threads, records the history and checks each round. You write four small procedures.
- **Ready-made models**: `Register`, `BoundedQueue`, `Stack`, `Map`, `Semaphore`, `EventFlag`, `CircuitBreaker`, most with a default operation generator.
- **Your own models**: a `step` function, `outcomes` when several results are allowed, or a model built from a sequential implementation (`sequentialModel`).
- **Controlled scheduling**: a seeded PCT scheduler (`schedule: true`) and bounded exhaustive exploration (`explore: true`). Atomics, locks and condition variables are intercepted by changing one import, with no edits to the code under test. The same seed gives the same interleaving.
- **Warnings** when a run tested less than it seems: OS scheduler only, or no switch points reached.
- **Diagnosis**: the longest order the model explains, the operation that does not fit and what the model expected, an ASCII timeline, a standalone HTML timeline, and the trace of switch points with file and line.
- **Minimization**: failing histories are shrunk automatically; `replayShrink` also shrinks the scenario by re-running the real code.
- **Beyond results**: `quiescent` checks invariants after each round (reference counts, leaks), the scheduler reports deadlocks and livelocks, and a watchdog reports hung rounds.
- **Regression files**: histories saved as versioned JSON Lines, checked again without threads.
- **Partitioning**: histories of independent keys (maps, caches) are split and checked per key.
- **Time and async**: fake clocks recorded as `tick` events, and tasks under `asyncdispatch` or Chronos.

## What problem it solves

Stress tests catch crashes and some races. They do not catch two concurrent operations that both "succeed" but together produce a result no sequential execution could produce. In a concurrent queue:

```
thread A: enqueue(7) -> ok
thread B: dequeue()  -> 7
thread C: dequeue()  -> 7      <- the same element delivered twice
```

No sequential order of a queue gives `7` to two `dequeue` calls. nimlinear returns `vkNotLinearizable` and names the operation that cannot be explained.

## When to use it

Use it for objects whose operations should look **atomic**: each call takes effect at one instant between its invocation and its return.

| Good fit | Not a fit |
|---|---|
| queues, stacks, maps, counters, registers, channels | eventual consistency, CRDTs (use convergence tests) |
| locks, semaphores, event flags, reference counts | transactions over several keys (serializability, not this) |
| pools, rate limiters, circuit breakers, caches | a `get` followed by a `put` done by the caller (model it as one operation) |
| lock-free and lock-based code, threads or async tasks | asynchronous APIs whose effect is deferred (model the real effect) |
| | network partitions and failures |

Before writing a test, you must be able to say, for each operation, what the sequential model is and why the operation can be treated as atomic. If you cannot, nimlinear is not the right tool.

## Install

The repository is `nim-linear`; the package and the module are `nimlinear` (nimble does not accept `-` in package names), so you write `import nimlinear`.

Add it as a test-only dependency:

```nim
# your-project.nimble
taskRequires "test", "https://github.com/kaio-souza/nim-linear"
```

or install it directly:

```sh
nimble install https://github.com/kaio-souza/nim-linear
```

Compile tests with `--threads:on` (the recorder and `runRounds` need it). The checker alone works with threads off.

## Quickstart

A register behind a lock, run from 3 threads for 100 short rounds, each round checked against the `Register` model. This is [`examples/quickstart.nim`](examples/quickstart.nim), compiled and run in CI.

<!-- quickstart:begin -->
```nim
# Quickstart: check a shared register under real threads.
# nim c -r --threads:on examples/quickstart.nim
import std/[locks, random]
import nimlinear
import nimlinear/models/register

type Reg = object      # the object under test: a register behind a lock
  lock: Lock
  value: int

proc setup(r: var Reg) = initLock r.lock
proc teardown(r: var Reg) = deinitLock r.lock

proc genOp(rng: var Rand, thread, index: int): RegOp =
  case rng.rand(2)
  of 0: read()
  of 1: write(rng.rand(1..3))
  else: cas(rng.rand(0..3), rng.rand(1..3))

proc exec(r: ptr Reg, op: RegOp): RegRes {.gcsafe.} =
  withLock r.lock:
    result = RegRes(ok: true)
    case op.kind
    of rRead: result.value = r.value
    of rWrite: r.value = op.value
    of rCas:
      if r.value == op.expected: r.value = op.desired
      else: result.ok = false

let res = runRounds(RoundsConfig(threads: 3, rounds: 100, opsPerThread: 4),
                    RegState(value: 0), RegisterModel, setup, genOp, exec, teardown)
echo res.describe           # on failure: shrunk report, timeline, saved file
quit(if res.passed: 0 else: 1)
```
<!-- quickstart:end -->

```sh
nim c -r --threads:on examples/quickstart.nim
```

What happens in each round:

1. `setup` creates a fresh object.
2. `genOp` draws the operations of each thread from a seeded generator, so the same seed gives the same operations.
3. `exec` runs each operation on the real object; every call and result is recorded.
4. The history is checked against `RegisterModel`.
5. On the first round that fails, the history is shrunk and saved as JSON Lines, and `describe` prints the report with a timeline.

## Guide by task

### Test your own object

You write four procedures and pick (or write) a model:

| Procedure | Role |
|---|---|
| `setup(obj)` or `setup(obj, info)` | put the object in a known state for each round (`info.seed` is the per-round seed) |
| `genOp(rng, thread, index)` | return one operation; optional when the model ships a generator |
| `exec(ptr obj, op)` | run it on the real object and return the result |
| `teardown(obj)` | optional cleanup |

Every shipped model except `CircuitBreaker` has a default generator (`genRegisterOp`, `genQueueOp`, `genStackOp`, `genMapOp`, `genSemaphoreOp`, `genEventOp`), so a simple test needs no `genOp`:

```nim
let res = runRounds(RoundsConfig(threads: 3, rounds: 200),
                    initSemState(max = 2), SemaphoreModel, setup, genSemaphoreOp, exec)
```

`RoundsConfig` fields you will use most:

| Field | Default | Meaning |
|---|---|---|
| `threads`, `opsPerThread`, `rounds`, `seed` | 3, 4, 100, 1 | size and identity of the run |
| `budget`, `timeout` | 1 000 000, none | limits of each check |
| `shrink`, `shrinkTimeout`, `replayShrink` | on, none, off | minimization of the failing round |
| `partitioned` | off | check per key (`checkPartitioned`) |
| `schedule`, `depth`, `steps` | off, 3, calibrated | PCT scheduler |
| `explore`, `preemptions`, `maxSchedules`, `reduce` | off, 2, 10 000, off | bounded exhaustive exploration |
| `stepLimit`, `roundTimeout` | 1 000 000, none | livelock limit, watchdog for hung rounds |
| `saveDir`, `name` | temp dir, `"nimlinear"` | where failing histories go |

The adoption steps, with acceptance criteria (including "inject a bug and see the test fail"), are in the [Usage guide](docs/GUIDE.md).

### Write a model

A model is a type with a pure `step` from a state and an operation to the next state and the expected result, plus `hash` (and `==`) on the state:

```nim
type
  CounterOp = object
    inc: bool
  CounterRes = object
    value: int
  CounterState = object
    value: int
  CounterModel = object

func step(m: typedesc[CounterModel], s: CounterState, op: CounterOp):
    Expected[CounterState, CounterRes] {.raises: [].} =
  if op.inc:
    Expected[CounterState, CounterRes](next: CounterState(value: s.value + 1),
                                       res: CounterRes(value: s.value + 1))
  else:
    Expected[CounterState, CounterRes](next: s, res: CounterRes(value: s.value))

func hash(s: CounterState): Hash = hash(s.value)
```

- **Several allowed results** (a weak CAS, a `take` from a bag, a `steal` that may give up): define `outcomes` instead of `step` and list every allowed `(next, result)` pair.
- **A sequential implementation as the spec**: `sequentialModel(QueueSpec, SeqQueue, QueueOp, QueueRes, apply)` builds the model from a plain sequential version of the structure.
- **Independent keys**: define `partition(op)` and set `partitioned: true`; each key is checked alone, which keeps large map histories fast.
- **Results from an open set** (fresh ids, timestamps): keep a small pool of candidates in the state.

All of this, with the rules that keep a model sound, is in [Sequential models](docs/MODELS.md).

### Check a history without threads

The checker works on any history, recorded by nimlinear or built by hand, with threads off:

```nim
import nimlinear
import nimlinear/models/register

let h = newHistory(@[
  invokeEvent[RegOp, RegRes](1, 0, 1, write(1)),
  invokeEvent[RegOp, RegRes](2, 1, 2, read()),
  returnEvent[RegOp, RegRes](1, 0, 3, RegRes(ok: true)),
  returnEvent[RegOp, RegRes](2, 1, 4, RegRes(value: 7, ok: true)),   # 7 was never written
])
let v = checkLinearizable(h, RegState(value: 0), RegisterModel)
assert v.kind == vkNotLinearizable
echo report(v, h)          # report and timeline
```

To record from your own threads instead of `runRounds`, use the `Recorder`: `begin`/`finish` around each call, or the `record` template, then `snapshot` after joining the threads ([API](docs/API.md#recorder)).

### Find races the OS scheduler hides

The default run observes whatever order the OS picks, so a narrow race can stay hidden for thousands of rounds. nimlinear widens what the rounds explore without changing the checker:

1. **Intercept atomics and locks.** Switch one import in the code under test, behind a define of its own, so production builds never import nimlinear:
   ```nim
   when defined(nimlinearIntercept): import nimlinear/intercept
   else: import std/[atomics, locks]
   ```
   Every atomic operation, lock acquire and condition wait becomes a switch point.
2. **Compile the test in strict mode**: `-d:nimlinearIntercept -d:nimlinearStrict`. `nimlinearStrict` turns on the switch points (`-d:nimlinearPerturb`) and intercepts atomic loads too (`-d:nimlinearInterceptLoads`). Without loads, a window between two loads with no write between them (read `head`, then `tail`, then decide) is never interleaved.
3. **Run under the PCT scheduler**: `RoundsConfig(schedule: true)`. Only one thread runs at a time and the scheduler picks where to switch. Its step count is calibrated on round 1, and the same seed replays the same interleaving.
4. **Or explore every schedule** of small rounds: `RoundsConfig(explore: true, preemptions: 2)`. Each round runs under every schedule with at most that many preemptions; `complete` in the result says the bound was covered. Keep rounds small (2 to 3 threads, 2 to 3 operations each).

`RoundsResult.warnings` (also printed by `describe`) tells you when a run tested less than it seems:
- it ran under the OS scheduler only;
- round 1 had no switch points, so the interception did not reach the code under test;
- every explored round had a single schedule.

To widen the net further:

- `Shared[T]` makes a plain (non-atomic) field a switch point on every read and write.
- `interceptAtomics` intercepts a library's own atomics module through a short shim.
- `perturb()` places a switch point by hand anywhere.
- The finer defines stay available: `-d:nimlinearPerturb` alone (writes and locks only), plus `-d:nimlinearInterceptLoads`.

Without a scheduler, the same build makes every switch point a random pause, which also helps. This is the mode for spin-wait loops, which cannot run under `schedule` or `explore`.

### Check what results do not show

- **Invariants after each round**: pass `quiescent = proc (obj: var Obj): string`. A non-empty message fails the round even if the history is linearizable. Use it for reference counts back to zero, nothing left allocated, or an internal length that matches the contents.
- **Deadlocks and livelocks**: under `schedule` or `explore`, a round where every thread waits, or that passes `stepLimit` switch points, fails with the reason.
- **Hung rounds**: `roundTimeout` starts a watchdog that writes a `.hung.txt` report (seed, operations, last switch points) and exits with code 124.
- **Exceptions**: an exception raised by `exec` fails the round, with thread, operation and message in `RoundsResult.error`.

### Reproduce and minimize a failure

When a round fails, `runRounds`:

- saves the shrunk history (`<name>-seed<s>-round<r>.jsonl`), the recorded one (`.original.jsonl`) and, under the scheduler, the trace of switch points with file and line (`.trace.txt`);
- returns everything in `RoundsResult`: `verdict`, `history`, `original`, `scenario`, `trace`, `savedTo`. `describe` prints it all.

Then:

- **Replay the saved file** with `parseJsonLines` and `checkLinearizable`. This works as a regression test with no threads.
- **Re-run the failing round** with `runScenario(cfg, round, scenario, ...)` under the same seed.
- **Shrink by re-running the real code** with `replayShrink: true`. The minimized scenario is a real execution, not only a smaller history.
- **Find a run that died**: if the process crashed, the next run reports it in `previousRun`, from the `.inprogress` file.

### Read the report

```nim
echo report(v)            # verdict, prefix, stuck operation, alternatives
echo timeline(h, v)       # one row per thread: [ invoke, ] return, = running, > pending
writeFile("fail.html", timelineHtml(h, v))   # standalone page, no external resources
```

How to read the report at the top of this page:
- **`prefix`** lists the operations the model explains, in order.
- **`stuck`** is the first operation that fits no continuation of that order.
- **`alternatives`** shows what the model expected from each candidate, against what was observed.
- **The timeline** shows which operations overlapped.

### Async code and time

- **Async tasks** (`asyncdispatch`, Chronos): each task gets its own recorder index, and `begin`/`finish` surround the whole operation, `await`s included ([Async](docs/ASYNC.md), [`examples/async_counter.nim`](examples/async_counter.nim)).
- **Time-dependent objects** (cool-downs, TTLs): drive a fake clock and record each advance with `tick`; the model sees the clock as an operation ([Time](docs/MODELS.md#time)).

## API at a glance

| Module | What you get |
|---|---|
| `nimlinear` | `checkLinearizable`, `checkPartitioned`, `Verdict`, `History`, `newHistory`, `subHistory`, `invokeEvent`/`returnEvent`/`tickEvent`, `shrink`, `report`, `timeline`, `timelineHtml`, `toJsonLines`, `parseJsonLines`; with threads: `Recorder` (`newRecorder`, `begin`, `finish`, `record`, `tick`, `snapshot`), `runRounds`, `runRound`, `runScenario`, `RoundsConfig`, `RoundsResult`, `describe`, `roundSeed` |
| `nimlinear/models/*` | `register`, `boundedqueue`, `stack`, `map`, `semaphore`, `eventflag`, `circuitbreaker`, with their default generators |
| `nimlinear/seqmodel` | `sequentialModel`: a model from a sequential implementation |
| `nimlinear/perturb` | `perturb()`, `setPerturbation` |
| `nimlinear/schedule` | `Scheduler` (PCT and exploration), `SchedLock`, `SchedCond`, `trace`, `formatTrace`, `noteAccess` |
| `nimlinear/intercept` | drop-in `std/atomics` + `std/locks` with switch points (`-d:nimlinearStrict`), `Shared[T]`, `interceptAtomics` |

Full signatures and rules: [API](docs/API.md).

## Examples

All in [`examples/`](examples/), compiled and run in CI. Each race example checks that the correct version passes and the buggy one is rejected.

| File | Shows |
|---|---|
| [`quickstart.nim`](examples/quickstart.nim) | a register behind a lock; the minimal `runRounds` test |
| [`queue_race.nim`](examples/queue_race.nim) | a check-then-act queue that delivers an element twice; the shrunk report |
| [`stack_race.nim`](examples/stack_race.nim) | a stack whose `pop` returns the same value twice; default generator `genStackOp` |
| [`map_race.nim`](examples/map_race.nim) | a map that loses an update; default generator and `partitioned: true` |
| [`semaphore_race.nim`](examples/semaphore_race.nim) | an atomic semaphore that hands out its last permit twice |
| [`async_counter.nim`](examples/async_counter.nim) | async tasks under `asyncdispatch` losing an increment across an `await` |
| [`queue_perturb.nim`](examples/queue_perturb.nim) | `perturb()` points find a narrow race in fewer rounds |
| [`queue_pct.nim`](examples/queue_pct.nim) | the PCT scheduler: the same seed gives the same history byte for byte |

## Troubleshooting

**Compilation**

| Symptom | Cause | Fix |
|---|---|---|
| `nimlinear/recorder requires --threads:on` (or `rounds`) | the recorder and the harness need threads | compile with `--threads:on`, or `skip()` the test when threads are off |
| `nimlinear/schedule requires -d:nimlinearPerturb (or -d:nimlinearStrict)` | the scheduler switches only at switch points | compile with `-d:nimlinearStrict` |
| error mentioning `raises` on `step` | the model's `step` can raise | make it `{.raises: [].}`; return an error result instead of raising |
| `'pureStep' can have side effects` | `step` touches a global | keep `step` pure; it is called many times in any order |
| error about `hash` or `==` | the state or result type lacks them | define both, covering every field |
| the model needs `step` or `outcomes` | neither is defined, or `outcomes` does not compile | add one; if `outcomes` exists, read its own compile error |

**Run time**

| Symptom | Cause | Fix |
|---|---|---|
| `ValueError` from `runRounds` | invalid `RoundsConfig`, `partitioned` without `partition`, `schedule` with `explore`, or `reduce` without `-d:nimlinearInterceptLoads` | fix the configuration as the message says |
| `ArgumentError` from `snapshot` or `newHistory` | an operation finished twice, `finish` without `begin`, two open operations on one thread, a bad thread index | `finish` must follow its `begin` on the same thread index |
| `vkInconclusive` | the search hit `budget` or `timeout` | make rounds smaller (fewer threads and operations) before raising `budget`; `timedOut` says which limit hit ([Budget](docs/API.md#budget)) |
| checks are very slow | too many overlapping operations | keep rounds at 2 to 4 threads with a few operations each; partition by key when you can |
| "round aborted by the scheduler: no end after N switch points" | a spin-wait loop: the spinning thread keeps the turn while the thread it waits for never runs | spin locks cannot run under `schedule` or `explore`; test them with `-d:nimlinearPerturb` and `schedule = false`, or raise `stepLimit` if the round is only long |
| "round aborted by the scheduler: deadlock" | every thread waits on a lock or condition | a real deadlock or lost wakeup in the code under test; read the trace |
| a scheduled round hangs | a thread blocks outside the switch points (I/O, a `std/locks` lock, a join) | use intercepted or `SchedLock` locks; set `roundTimeout` to get a report instead of a hang |
| process exits with code 124 | the watchdog (`roundTimeout`) saw a hung round | read the `.hung.txt` file it names |
| `replay` says the round is not deterministic | the round depends on the OS scheduler | use `replayShrink` together with `schedule` |
| `explore` reports "not deterministic" | the code takes a different path for the same schedule (time, randomness, I/O) | remove that source of nondeterminism from the round |
| `complete` is false after `explore` | `maxSchedules` cut a round | make the round smaller or raise `maxSchedules` |

**Results**

| Symptom | Cause | Fix |
|---|---|---|
| the test always passes, but the bug exists | the bug needs an interleaving that is never produced | read `warnings` first; intercept, compile with `-d:nimlinearStrict` and run under `schedule` or `explore`; use `Shared[T]` or `perturb()` for plain fields. Check that an injected bug fails ([Guide](docs/GUIDE.md)) |
| warning: "round 1 had no switch points" | the code under test does not use the intercepted import in this build (wrong define, or another atomics module) | check its import guard and the compile flags; for another atomics module use `interceptAtomics` |
| a failure that the spec allows (a `steal` or weak CAS that gives up, a spurious `false`) | the model allows fewer results than the specification | list every allowed result with `outcomes` |
| the shrunk history looks impossible | shrinking dropped context | `describe` prints the recorded history below a shrunk one of 3 operations or fewer; it is also in `original` (`.original.jsonl`) |
| the same seed gives different histories | no scheduler: the OS picks the interleaving | a seed fixes the operations; `schedule` or `explore` fix the interleaving too |
| a `timeout` verdict differs between machines | `timeout` is wall-clock time | prefer `budget` in regression tests |
| `parseJsonLines`: `unsupported format version` | the file was written by a newer nimlinear | use that version |
| `parseJsonLines` fails on your payload | the default hooks do not cover your type (variant objects) | write `toPayload` and `fromPayload` ([API](docs/API.md#json-tojsonlines-and-parsejsonlines)) |

## Limits

- **Worst-case cost.** The checker is exponential in the worst case (the problem is NP-complete). Long histories with bounded overlap are fast: 40 000 operations in about 20 ms ([benchmarks](docs/MEASUREMENTS.md#benchmarks)).
- **Coverage.** Without `explore`, a round observes one execution. PCT raises the odds of finding a bug but gives no guarantee. `explore` is exhaustive only up to its preemption bound and over the switch points ([PCT coverage](docs/COMPARISON.md#probabilistic-coverage-of-pct)).
- **Plain fields.** They are switch points only when declared `Shared[T]` or marked with `perturb()`. Atomic loads are switch points only with `-d:nimlinearInterceptLoads`.
- **Spin-wait loops.** They cannot run under `schedule` or `explore`. Use random perturbation for them.
- **Memory model.** Sequential consistency only. Relaxed orderings (acquire/release) are not explored: store-buffering outcomes on real hardware are invisible.
- **Safety, not liveness.** An operation that never returns shows up as pending, not as a violation. The scheduler's deadlock and livelock detection, `quiescent` and `roundTimeout` cover part of it.
- **Heuristics.** `shrink` uses a heuristic guard against artificial failures (D-24). `checkPartitioned` trusts the model's `partition`; validate a new one with `-d:nimlinearVerifyPartition`.

## Known issues

None open. In 0.1.0 (fixed in the next release, see the [Changelog](CHANGELOG.md)): an exception raised by `exec` was not reported as a failure; `runRounds` ignored `partition`, had no `timeout` and one fixed initial state; a scheduler created in `setup` got the same seed in every round; `shrink` had no time limit. An intermittent SIGSEGV on Windows seen once in CI has not been reproduced since ([notes](CONTRIBUTING.md#found-on-code-review), R2).

## Terms

| Term | Meaning |
|---|---|
| **operation** | one call to the object under test: an `invoke` and, if it finished, a `return` |
| **history** | the `invoke`/`return` events of one execution, ordered by `seq` |
| **linearization point** | the instant, between `invoke` and `return`, at which the operation takes effect |
| **linearizable** | a sequential order of the operations exists that respects real-time order and gives exactly the observed results |
| **model** | the sequential specification: `step(state, operation) -> (next state, result)` |
| **pending** | an operation with an `invoke` and no `return` |
| **switch point** | a place where the scheduler may run another thread: intercepted atomics and locks, `Shared[T]` accesses, `perturb()` |
| **budget** | the maximum number of configurations the search visits before returning `vkInconclusive` |
| **P-compositional** | a specification whose history splits by key, so each part can be checked alone ([D-12](docs/DECISIONS.md)) |

## Documentation

| Document | Contents | Read it when |
|---|---|---|
| [Usage guide](docs/GUIDE.md) | step-by-step adoption in a project | you add nimlinear to a project |
| [API](docs/API.md) | types, procedures, verdicts, budget, errors | you write code that calls the library |
| [Sequential models](docs/MODELS.md) | how to write a specification; shipped models | you write a new model |
| [History](docs/HISTORY.md) | recording, event order, time, JSON format | you record or save a history |
| [Async code](docs/ASYNC.md) | recording tasks under asyncdispatch or Chronos | your code uses `await` |
| [Decisions](docs/DECISIONS.md) | design decisions, with reason and consequence | you question a choice |
| [Comparison](docs/COMPARISON.md) | differences from Porcupine, Knossos, Lincheck | you choose between tools |
| [Measurements](docs/MEASUREMENTS.md) | time, memory and detection rates, measured | you size a test |
| [Contributing](CONTRIBUTING.md) | repository layout, tests, roadmap, releases | you work on the library itself |
| [Changelog](CHANGELOG.md) | what changed in each version | you upgrade |

## References

- Wing & Gong (1993), the base algorithm of the checker; Lowe (2017), *Testing for linearizability*, with the memoization used by Porcupine.
- Horn & Kroening (2015), *Faster linearizability checking via P-compositionality* (arXiv 1504.00204): partitioning.
- Burckhardt, Kothari, Musuvathi & Nagarakatte (2010), *A randomized scheduler with probabilistic guarantees of finding bugs* (PCT).
- [Porcupine](https://github.com/anishathalye/porcupine) (Go), [Knossos](https://github.com/jepsen-io/knossos) (Clojure), Lincheck (Kotlin): the tools nimlinear borrows from.
- [mratsim/weave#127](https://github.com/mratsim/weave/pull/127): Thread Collider, an interleaving explorer for Nim threads.

## License

[MIT](LICENSE).
