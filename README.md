# nimlinear

[![CI](https://github.com/kaio-souza/nim-linear/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/kaio-souza/nim-linear/actions/workflows/ci.yml)

A Nim library, **stdlib only**, that checks whether a history of concurrent operations is **linearizable**: is there a valid sequential order of the operations that explains exactly the observed results?

> **Status: not released yet** (M9 pending). Everything described here exists on `master` and runs in CI (Linux, macOS, Windows × Nim 2.2.0 on Linux, 2.2.4, 2.4.0). The API may still change before the first release; changes are listed in [`CHANGELOG.md`](CHANGELOG.md). Known limits are in [Limits](#limits) and [`docs/COMPARISON.md`](docs/COMPARISON.md).

## What it is for

Stress tests catch crashes and some race conditions. They do not catch two concurrent operations that finish "normally" but with a result no sequential order would produce. nimlinear records the history of a concurrent execution and answers whether it can be explained.

An example of a bug it catches and a regular stress test does not, in a concurrent queue:

```
thread A: enqueue(7) -> ok
thread B: dequeue()  -> 7
thread C: dequeue()  -> 7      (the same element delivered twice)
```

No sequential order of a queue hands a single `7` to two `dequeue` calls. The checker returns `vkNotLinearizable` and points at the operation that does not fit; [`examples/queue_race.nim`](examples/queue_race.nim) finds exactly this bug in a real lock-based queue.

## Documentation index

| Document | Contents | Read it when |
|---|---|---|
| [API](docs/API.md) | types, procedures, verdicts and budget | you write code that uses the library |
| [Sequential models](docs/MODELS.md) | how to describe the specification; example models | you write a new model |
| [History](docs/HISTORY.md) | recording, event order, time, JSON format | you record or save a history |
| [Usage guide](docs/GUIDE.md) | how to set up a linearizability test in any project | you adopt the library in a project |
| [Decisions](docs/DECISIONS.md) | design decisions, with reason and consequence | you question a choice |
| [Contributing](CONTRIBUTING.md) | repository layout, library tests, oracle, measurements | you work on the library code |

## Glossary

| Term | Meaning |
|---|---|
| **operation** | one call to the object under test: an `invoke` and, if it finished, a `return` |
| **history** | list of `invoke`/`return` events of one execution, ordered by `seq` |
| **linearization point** | instant, between `invoke` and `return`, at which the operation "happens" atomically |
| **linearizable** | there is a sequential order of the operations that respects real-time order (if A returned before B started, A comes first) and in which the model produces exactly the observed results |
| **model** | sequential specification: `step(state, operation) -> (next state, result)` |
| **configuration** | pair (set of operations already linearized, model state) visited by the search |
| **pending** | operation with an `invoke` and no `return` |
| **budget** | maximum number of configurations visited before giving up with `vkInconclusive` |
| **P-compositional** | specification whose history can be split by key and each part checked on its own (D-12) |

## When to use it

Use it for objects whose operations should look **atomic**: each call has a point at which it "happens", between invocation and return.

**Good fits:**
- queues, stacks, maps, counters, registers, channels;
- locks, semaphores, event flags;
- objects with a shared state machine (pools, limiters, breakers, caches);
- synchronous APIs in which each call has a single effect on shared state.

**Do not use it for:**

| Situation | Why | Alternative |
|---|---|---|
| Asynchronous API with a deferred effect (a `put` that queues work) | the linearization point does not show up in the history | model the real effect, or test eventual consistency |
| Eventual consistency, CRDTs | the criterion is convergence | convergence tests |
| Transactions touching several keys | the criterion is serializability, not linearizability of one object | Elle or similar, out of scope |
| Compound operation done by the caller (`get` followed by `put`) | the checker sees two independent events and accepts the race | model the compound operation as a single one |
| Network failures and partitions | they need a Jepsen-style failure model | out of scope |
| Code without a sequential specification | without the correct result of each operation there is nothing to compare against | write the specification first |

**User prerequisite:** before writing the test, state for each operation what the sequential model is and why it can be treated as atomic. If you cannot, this library is not the right tool.

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

If a round is not linearizable, `runRounds` stops, shrinks the history, saves it as JSON Lines and `describe` prints the report with a timeline. Lower-level pieces (the `Recorder`, `checkLinearizable`, `report`) are in [API](docs/API.md); writing your own model is in [Models](docs/MODELS.md); the step-by-step adoption is in the [Usage guide](docs/GUIDE.md).

## Guarantees

- **No external dependencies.** Only `std/*`: `atomics`, `locks`, `json`, `hashes`, `sets`, `tables`, `random`, `unittest` (and `monotimes`, for diagnostics only).
- **The core does not raise.** `checkLinearizable` is `{.raises: [].}`; the contract requires the model's `step`/`outcomes` to be as well. Usage errors (invalid history) show up earlier, in `newHistory`/`parseJsonLines`.
- **Determinism.** The verdict and the report depend only on the history, the model and `init`: not on wall-clock time (unless you pass a `timeout`) or on `HashSet` iteration order. Reports are ordered by `seq`.
- **Honest results.** `vkInconclusive` is never treated as success or as failure.

## Limits

- The checker is exponential in the worst case (the problem is NP-complete): about 16 fully overlapping register operations or 8 fully overlapping queue operations per second of checking (see [benchmarks](docs/MEASUREMENTS.md#benchmarks)). Long histories with bounded overlap are linear (40 000 operations in about 20 ms), except with many pending operations. Keep rounds small: 2 to 4 threads, a few operations each.
- `shrink` uses a heuristic guard against artificial failures (D-24); `checkPartitioned` trusts the model's `partition` (use `-d:nimlinearVerifyPartition` while validating a new one).
- It observes **one real execution**. It does not explore interleavings; bugs that only show up in another order are not detected. Exhaustive exploration is a different project (see [Decisions](docs/DECISIONS.md), D-07). Optional modules increase the variety of orders by sampling (`nimlinear/perturb`, `nimlinear/schedule`, D-18), without promising coverage; the scheduler switches threads only at points placed by hand.
- It only covers **sequential consistency** (linearizability). Relaxed orderings (acquire/release) are not modeled. A classic example nimlinear does not see (*store buffering*): thread 1 does `x = 1; r1 = y`, thread 2 does `y = 1; r2 = x`, with relaxed accesses; the result `r1 = 0` and `r2 = 0` is possible on hardware, but no sequential order produces it (see [Weave PR #127](https://github.com/mratsim/weave/pull/127)).
- **Linearizability is safety, not liveness.** An operation that never returns (deadlock, lost wakeup without a timeout) shows up as pending and is not a violation. To catch that class, the test needs a `wait` with a timeout whose result contradicts the model, or a watchdog (see [Models](docs/MODELS.md#eventflag-and-lost-wakeup)).

## Roadmap

A milestone (M0, M1…) is a unit of work, not a version (see [Release policy](#release-policy)). A box is checked only after the CI matrix confirms it. What each milestone delivered is in [`CHANGELOG.md`](CHANGELOG.md).

- [x] **M0–M8. Core**: project and CI, history types and JSON Lines, checker with memoized graph search, pending operations, budget, diagnostics, brute-force oracle, concurrent recorder, end-to-end example.
- [ ] **M9. First release** on the nimble index.
- [x] **M10–M13. Optional features**: time as an event (`tick`), `checkPartitioned`, perturbation points, PCT scheduler.
- [ ] **M14–M24. Refinement** after comparing with Porcupine, Knossos and Lincheck ([`docs/COMPARISON.md`](docs/COMPARISON.md)): nondeterministic specifications (`outcomes`), format version line, `shrink`, `runRounds`, timeline (text and HTML), `SchedLock`, wall-clock timeout, generic partition key, linear-time search, benchmark suite with a CI check, private `History` fields. Implemented on `master`; to be checked when CI is green.

## Release policy

The work is done with AI agents: small milestones are ready in hours. Releasing at every milestone would produce several versions on the same day, and users would have to follow updates with no real gain. So **finishing work and releasing are separate things** (D-21).

- **Milestones go to `master`, not to the nimble index.** Each finished milestone adds entries under `## Unreleased` in `CHANGELOG.md`.
- **A release bundles a set of changes that makes sense to users**, not a milestone. The first one requires the whole core (M0–M9). Releases are made by pushing a `vX.Y.Z` tag; `.github/workflows/release.yml` checks it and publishes the GitHub release (see [CONTRIBUTING](CONTRIBUTING.md#releasing)).
- **Before releasing:** full CI matrix green on `master`, and no change to the public API or to the JSON format in the last **7 days** (stabilization period, so real use can find problems first).
- **At least 7 days between releases.** Single exception: a fix for a bug that makes the checker return a **wrong verdict** (false `vkLinearizable` or false `vkNotLinearizable`). That fix ships alone, as soon as CI passes.
- **Numbering:** SemVer `0.x.y` while the API may change. The number is chosen at release time, based on what changed (API or format break: `x`; anything else: `y`). The roadmap does not reserve version numbers for milestones.
- **Documentation language:** English until v1. Translations come before v1.

## References

- Wing & Gong (1993), the base algorithm of the checker; Lowe (2017), *Testing for linearizability*, with the visited-state memoization used by Porcupine.
- Horn & Kroening (2015), *Faster linearizability checking via P-compositionality* (arXiv 1504.00204): WGL and partitioning.
- [Porcupine](https://github.com/anishathalye/porcupine) (Go): checker and history visualization.
- [Knossos](https://github.com/jepsen-io/knossos) (Clojure): histories against sequential models.
- [Elle](https://github.com/jepsen-io/elle) (Clojure): transactional isolation, out of scope here.
- [nim-lang/RFCs#222](https://github.com/nim-lang/RFCs/issues/222): "Correct-by-construction Nim programs", open since 2020. Its second part (threads) is the closest to this project.
- [mratsim/weave#127](https://github.com/mratsim/weave/pull/127): Thread Collider, WIP and open. An interleaving explorer with vector clocks and DPOR. Source of the comparison with ThreadSanitizer: TSan observes one execution; an explorer proves the absence of races over all paths.
- [mratsim/weave#56](https://github.com/mratsim/weave/issues/56): "[Glibc] Condition variable lost wakeups", closed. A real case of a lost wakeup on a condvar, used as the `EventFlag` fixture.

## License

[MIT](LICENSE).
