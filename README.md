# nimlinear

[![CI](https://github.com/kaio-souza/nim-linear/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/kaio-souza/nim-linear/actions/workflows/ci.yml)

**nimlinear checks whether the results of concurrent operations on your object could have happened in some sequential order.** You run operations from several threads, record each call and its result, and the checker answers *linearizable* or *not linearizable*, pointing at the operation that does not fit.

Stdlib only. Nim 2.2.0 or newer. MIT license.

## What problem it solves

Stress tests catch crashes and some races. They do not catch two concurrent operations that both "succeed" but together produce a result no sequential execution could produce. For example, in a concurrent queue:

```
thread A: enqueue(7) -> ok
thread B: dequeue()  -> 7
thread C: dequeue()  -> 7      <- the same element delivered twice
```

No sequential order of a queue gives `7` to two `dequeue` calls. nimlinear returns `vkNotLinearizable` and names the operation that cannot be explained. [`examples/queue_race.nim`](examples/queue_race.nim) finds exactly this bug in a lock-based queue with a check-then-act mistake.

## When to use it

Use it for objects whose operations should look **atomic**: each call takes effect at one instant between its invocation and its return.

| Good fit | Not a fit |
|---|---|
| queues, stacks, maps, counters, registers, channels | eventual consistency, CRDTs (use convergence tests) |
| locks, semaphores, event flags | transactions over several keys (serializability, not this) |
| pools, rate limiters, circuit breakers, caches | a `get` followed by a `put` done by the caller (model it as one operation) |
| synchronous APIs with one effect on shared state | asynchronous APIs whose effect is deferred (model the real effect) |
| | network partitions and failures |

Before writing a test, you must be able to say, for each operation, what the sequential model is and why the operation can be treated as atomic. If you cannot, nimlinear is not the right tool.

## Install

nimlinear is not on the nimble index yet. Add it from the repository, as a test-only dependency:

```nim
# your-project.nimble
taskRequires "test", "https://github.com/kaio-souza/nim-linear"
```

Requires `--threads:on` for the recorder and the round harness (`runRounds`). The checker alone works with threads off.

## Quickstart

A register behind a lock, run from 3 threads for 100 short rounds, each round checked against the `Register` model. This is [`examples/quickstart.nim`](examples/quickstart.nim), compiled and run in CI; `tests/treadme.nim` checks that the block below is identical to the file.

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

What happens:

1. `setup` creates a fresh object for each round.
2. `genOp` draws the operations of each thread from a seeded generator, so the same seed gives the same operations.
3. `exec` runs each operation on the real object; `runRounds` records the call and the result of every operation.
4. Each round's history is checked against `RegisterModel`.
5. On the first round that is not linearizable, the history is shrunk, saved as JSON Lines, and `describe` prints the report with a timeline.

## Your own test, in four procedures

For any object, you write:

- `setup(obj)`: put the object in a known state for each round;
- `genOp(rng, thread, index)`: return one operation;
- `exec(ptr obj, op)`: run it on the real object and return the result;
- `teardown(obj)` (optional).

Then `runRounds(RoundsConfig(...), initState, MyModel, setup, genOp, exec, teardown)` does the rest. The step-by-step adoption, with acceptance criteria, is in the [Usage guide](docs/GUIDE.md).

To write the sequential specification of your object, see [Sequential models](docs/MODELS.md). Shipped models: `Register`, `EventFlag`, `BoundedQueue`, `CircuitBreaker` (in `nimlinear/models/*`).

## Examples

All in [`examples/`](examples/). They are compiled and run in CI.

| File | Shows |
|---|---|
| [`quickstart.nim`](examples/quickstart.nim) | a register behind a lock; the minimal `runRounds` test |
| [`queue_race.nim`](examples/queue_race.nim) | a correct queue passes 300 rounds; a buggy one fails and the shrunk report shows the double dequeue |
| [`queue_perturb.nim`](examples/queue_perturb.nim) | `perturb()` points find a narrow race in fewer rounds (`-d:nimlinearPerturb`) |
| [`queue_pct.nim`](examples/queue_pct.nim) | the PCT scheduler: the same seed gives the same history byte for byte |

Sample output of `queue_race.nim` against the buggy queue (trimmed):

```
buggy queue: failed in round 1 (seed 1), shrunk from 36 to 8 events
not linearizable
prefix: 1 4 7
stuck: op 5
call: dequeue()
result: value(100)
alternatives:
  - op 5: expected value(0), observed value(100)
timeline:
  thread 0  [][=][=]
  thread 1     [==]
```

Read it this way: operations `1`, `4` and `7` form the longest prefix that the model explains. The next dequeue (operation `5`, thread 1) must return `0`, the element enqueued in operation `1`. It returned `100` instead, which operation `4` had already taken. The timeline shows which operations overlapped.

## Use cases

- **Concurrent data structures**: a bounded queue or channel where `dequeue` can deliver the same element twice ([model](docs/MODELS.md#boundedqueue)).
- **Locks and signals**: an event flag where a `signal` can be lost while a `wait` sleeps ([model](docs/MODELS.md#eventflag-and-lost-wakeup)).
- **Compare-and-swap code**: a register with `read`, `write` and `cas` ([model](docs/MODELS.md)).
- **State machines with permits**: a circuit breaker or limiter that hands out more permits than its state allows ([model](docs/MODELS.md#circuitbreaker)).
- **Time-dependent objects**: caches and breakers with a cool-down, tested with a fake clock recorded as `tick` events ([Time](docs/MODELS.md#time)).
- **Regression of a known bug**: save the failing history as JSON Lines and replay it with `checkLinearizable`, without rerunning threads ([History](docs/HISTORY.md#saving-a-failed-history)).

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `nimlinear/recorder requires --threads:on` or `nimlinear/rounds requires --threads:on` | the recorder and the harness need threads | compile with `--threads:on`, or use `skip()` in the test when threads are off |
| `nimlinear/schedule requires -d:nimlinearPerturb` | the scheduler switches threads only at `perturb()` points | compile with `-d:nimlinearPerturb` |
| compile error mentioning `raises` on `step` | the model's `step` can raise | make `step` `{.raises: [].}`; return an error value in the result instead of raising |
| compile error about `hash` or `==` | the model state or result type lacks them | define `hash` and `==` for them (`Hash` from `std/hashes`) |
| the model needs `step` or `outcomes` | the model defines neither | add `step` (or `outcomes` for nondeterministic specs, see [Models](docs/MODELS.md)) |
| `ArgumentError` from `snapshot` or `newHistory` | the history breaks an invariant: an operation finished twice, `finish` without `begin`, a thread with two open operations, a bad thread index | fix the recording code; `finish` must follow its `begin` on the same thread index |
| `ValueError` from `runRounds` (`threads must be >= 1`, ...) | invalid `RoundsConfig` | fix the configuration |
| `vkInconclusive` in the test | the search reached `budget` (or `timeout`) before deciding | shrink the round first: fewer threads, fewer operations. Raise `budget` only after measuring ([Budget](docs/API.md#budget)). `timedOut` tells you which limit stopped it |
| the test always passes, but the bug is known to exist | the bug needs an interleaving the OS rarely produces | add `perturb()` points (see [`queue_perturb.nim`](examples/queue_perturb.nim)), run under the scheduler (see [`queue_pct.nim`](examples/queue_pct.nim)), or raise `rounds`. First confirm the test fails with an injected bug (step 5 of the [Guide](docs/GUIDE.md)) |
| a scheduler round hangs | a thread blocks in the OS between `enter` and `leave`, or uses a plain `Lock` while others wait for it | use `SchedLock` for the object's locks; never join or block inside a scheduled round ([rules](docs/API.md#nimlinearschedule-m13)) |
| the same seed gives different histories | the scheduler is not used: the OS picks the interleaving | a seed reproduces the operations, not the interleaving; use `nimlinear/schedule` for exact reproduction |
| a `timeout` verdict differs between machines | `timeout` is wall-clock time | prefer `budget` in regression tests |
| `parseJsonLines` raises `unsupported format version` | the file was written by a newer nimlinear | use the nimlinear version that wrote it |
| `parseJsonLines` fails on your model's payload | the default `toPayload`/`fromPayload` do not cover your type (for example, variant objects) | write both hooks ([API](docs/API.md#json-tojsonlines-and-parsejsonlines)) |
| checks are very slow | too many overlapping operations | about 16 fully overlapping register operations or 8 queue operations per second. Keep rounds small: 2 to 4 threads, a few operations each ([Limits](#limits)) |

## Limits

- The checker is exponential in the worst case (the problem is NP-complete). Long histories with bounded overlap are fast: 40 000 operations in about 20 ms ([benchmarks](docs/MEASUREMENTS.md#benchmarks)).
- It observes **one real execution per round**. It does not explore every interleaving: a bug that only shows up in another order can be missed. More rounds, `perturb()` points and the PCT scheduler increase the coverage, without a guarantee ([Decisions](docs/DECISIONS.md), D-07 and D-18).
- It checks **linearizability** (sequential consistency of one object). Relaxed memory orderings (acquire/release) are not modeled: store-buffering outcomes on real hardware are invisible to it.
- **Linearizability is safety, not liveness.** An operation that never returns shows up as pending, not as a violation. Catch hangs with a timeout in the result or a watchdog ([Models](docs/MODELS.md#eventflag-and-lost-wakeup)).
- `shrink` uses a heuristic guard against artificial failures (D-24). `checkPartitioned` trusts the model's `partition`; validate a new one with `-d:nimlinearVerifyPartition`.

Comparison with other tools (Porcupine, Knossos, Lincheck, Thread Collider): [`docs/COMPARISON.md`](docs/COMPARISON.md).

## Terms

| Term | Meaning |
|---|---|
| **operation** | one call to the object under test: an `invoke` and, if it finished, a `return` |
| **history** | the `invoke`/`return` events of one execution, ordered by `seq` |
| **linearization point** | the instant, between `invoke` and `return`, at which the operation takes effect |
| **linearizable** | a sequential order of the operations exists that respects real-time order and gives exactly the observed results |
| **model** | the sequential specification: `step(state, operation) -> (next state, result)` |
| **pending** | an operation with an `invoke` and no `return` |
| **budget** | the maximum number of configurations the search visits before returning `vkInconclusive` |
| **P-compositional** | a specification whose history splits by key, so each part can be checked alone ([D-12](docs/DECISIONS.md)) |

## Documentation

| Document | Contents | Read it when |
|---|---|---|
| [Usage guide](docs/GUIDE.md) | step-by-step adoption in a project | you add nimlinear to a project |
| [API](docs/API.md) | types, procedures, verdicts, budget, errors | you write code that calls the library |
| [Sequential models](docs/MODELS.md) | how to write a specification; shipped models | you write a new model |
| [History](docs/HISTORY.md) | recording, event order, time, JSON format | you record or save a history |
| [Decisions](docs/DECISIONS.md) | design decisions, with reason and consequence | you question a choice |
| [Comparison](docs/COMPARISON.md) | differences from Porcupine, Knossos, Lincheck | you choose between tools |
| [Measurements](docs/MEASUREMENTS.md) | memory, states and time on measured histories | you size a test |
| [Contributing](CONTRIBUTING.md) | repository layout, tests, roadmap, releases | you work on the library itself |
| [Changelog](CHANGELOG.md) | what changed in each version | you upgrade |

## References

- Wing & Gong (1993), the base algorithm of the checker; Lowe (2017), *Testing for linearizability*, with the memoization used by Porcupine.
- Horn & Kroening (2015), *Faster linearizability checking via P-compositionality* (arXiv 1504.00204): partitioning.
- [Porcupine](https://github.com/anishathalye/porcupine) (Go), [Knossos](https://github.com/jepsen-io/knossos) (Clojure): histories against sequential models.
- [mratsim/weave#127](https://github.com/mratsim/weave/pull/127): Thread Collider, an interleaving explorer for Nim threads.

## License

[MIT](LICENSE).
