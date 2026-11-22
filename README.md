# nimlinear

> **Status: in development, not released.** Most of this documentation describes what the library **is meant** to do, not what it already does. The API is a draft and may change until the first release.
>
> **What exists today** (tested locally only, Linux, Nim 2.2.4; CI has not run yet):
> - history types, `newHistory` and JSON Lines (M1);
> - `checkLinearizable` with the `Register` model (M2);
> - pending operations and the `EventFlag` model, with a lost-wakeup fixture that the checker rejects (M3);
> - a search budget that returns `vkInconclusive`, plus optional `-d:nimlinearMeasure` sampling and preliminary measurements in [`docs/MEASUREMENTS.md`](docs/MEASUREMENTS.md) (M4);
> - stable `report` text and golden snapshots for verdicts (M5);
> - a brute-force oracle test comparing 10,000 random histories per model (`Register` and `BoundedQueue`) against the checker (M6);
> - a concurrent `Recorder` with `--threads:on`: per-thread buffers, no locks while recording, merged in `snapshot` (M7);
> - the `BoundedQueue` example model used by tests (part of M8 groundwork).
>
> **Does not exist yet:** the end-to-end example, the `CircuitBreaker` model, and full M4 memory-measurement acceptance in CI. No milestone is checked in the [Roadmap](#roadmap) until CI confirms it.

A Nim library, **stdlib only**, that checks whether a history of concurrent operations is **linearizable**: is there a valid sequential order of the operations that explains exactly the observed results?

## What it is for (in one sentence)

Stress tests catch crashes and some race conditions. They do not catch two concurrent operations that finish "normally" but with a result no sequential order would produce. The goal of nimlinear is to record the history of a concurrent execution and answer whether it can be explained.

An example of a bug it is meant to catch and a regular stress test does not, in a concurrent queue:

```
thread A: enqueue(7) -> ok
thread B: dequeue()  -> 7
thread C: dequeue()  -> 7      (the same element delivered twice)
```

No sequential order of a queue hands a single `7` to two `dequeue` calls. The checker is meant to return `vkNotLinearizable` pointing at the operation that does not fit (the `BoundedQueue` model exists; the end-to-end example with a real queue does not yet).

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

## Usage example (draft)

> Draft: `checkLinearizable`, `report`, `Recorder` (with `--threads:on`) and the `Register` model exist, but this snippet is abbreviated (the `...` stands for the thread code) and is not compiled by any test. A runnable end-to-end example is M8.

A shared register with `read`, `write` and `cas`. Full model in [Models](docs/MODELS.md#register).

```nim
import nimlinear

var rec = newRecorder[RegOp, RegRes](threads = 2)
# each thread records invoke/return around each call to the real register
# (see docs/HISTORY.md#concurrent-recording-recorder)
...
let verdict = checkLinearizable(rec.snapshot(), RegState(value: 0), RegisterModel,
                                budget = 100_000)
case verdict.kind
of vkLinearizable: discard
of vkNotLinearizable: echo verdict.report     # operation that does not fit + prefix + alternatives
of vkInconclusive: echo "budget exhausted after ", verdict.statesExplored, " states"
```

Details in [API](docs/API.md), [Models](docs/MODELS.md) and the [Usage guide](docs/GUIDE.md).

## Guarantees

These are design goals. Today they apply only to the code that already exists (history, JSON, checker, report and recorder) and have been verified only by local tests.

- **No external dependencies.** Only `std/*`: `atomics`, `locks`, `json`, `hashes`, `sets`, `tables`, `random`, `unittest` (and `monotimes`, for diagnostics only).
- **The core does not raise.** `checkLinearizable` is `{.raises: [].}`; the contract requires the model's `step` to be as well. Usage errors (invalid history) show up earlier, in `newHistory`/`parseJsonLines`.
- **Determinism.** No result depends on wall-clock time or on `HashSet` iteration order. Reports are ordered by `seq`.
- **Honest results.** `vkInconclusive` is never treated as success or as failure.

## Limits

- The checker is exponential in the worst case (the problem is NP-complete). In practice, with memoization: **2 to 4 threads, a few dozen operations per history**. Histories of a few hundred operations are possible, but not the default use case.
- It observes **one real execution**. It does not explore interleavings; bugs that only show up in another order are not detected. Exhaustive exploration is a different project (see [Decisions](docs/DECISIONS.md), D-07). Optional modules increase the variety of orders by sampling (M12, M13, D-18), without promising coverage.
- It only covers **sequential consistency** (linearizability). Relaxed orderings (acquire/release) are not modeled. A classic example nimlinear does not see (*store buffering*): thread 1 does `x = 1; r1 = y`, thread 2 does `y = 1; r2 = x`, with relaxed accesses; the result `r1 = 0` and `r2 = 0` is possible on hardware, but no sequential order produces it (see [Weave PR #127](https://github.com/mratsim/weave/pull/127)).
- **Linearizability is safety, not liveness.** An operation that never returns (deadlock, lost wakeup without a timeout) shows up as pending and is not a violation. To catch that class, the test needs a `wait` with a timeout whose result contradicts the model, or a watchdog (see [Models](docs/MODELS.md#eventflag-and-lost-wakeup)).

## Roadmap

Items in order. Each one has an acceptance criterion. A milestone (M0, M1…) is a **unit of work**, not a version: finishing a milestone does not produce a release. When to release is described in [Release policy](#release-policy).

**Core** (the first release happens when all of them are done)

- [ ] **M0. Project** (`nimlinear.nimble` with `license = "MIT"`, `CHANGELOG.md`, layout from [CONTRIBUTING](CONTRIBUTING.md); `LICENSE`, `.gitattributes` and `.github/workflows/ci.yml` already created). Acceptance: the CI matrix passes with a minimal test `tests/tsmoke.nim` (CI fails on purpose when there is no `tests/t*.nim`).
- [ ] **M1. History types and JSON** (`Event`, `History`, distinct ids, `newHistory`, `toJsonLines`/`parseJsonLines`). Acceptance: a JSON round trip preserves bytes; invalid histories raise `ArgumentError`.
- [ ] **M2. Checker** as a graph search, memoizing `(linearized, state)` for successes and failures (D-11), using the `Register` model. Acceptance: hand-written linearizable and non-linearizable fixtures; deterministic `order` (D-20); a negative compilation test shows that a `step` that can raise does not compile.
- [ ] **M3. Pending operations** (D-08). Acceptance: the checker accepts both possibilities; an `EventFlag` lost-wakeup fixture with a timed `wait` is rejected.
- [ ] **M4. Budget** and the `vkInconclusive` verdict. Acceptance: a low budget gives `vkInconclusive`; a sufficient budget gives a definitive verdict; peak memory measured and recorded in `docs/MEASUREMENTS.md` (method in [CONTRIBUTING](CONTRIBUTING.md#memory-measurement-m4)).
- [ ] **M5. Diagnostics** (D-14): `Witness` with alternatives and a stable `report`. Acceptance: snapshots in `tests/golden/` identical on Linux, macOS and Windows.
- [ ] **M6. Brute-force oracle** for up to ~8 operations, with a fixed seed (generator described in [CONTRIBUTING](CONTRIBUTING.md#brute-force-oracle-m6)). Acceptance: agrees with the checker on 10 thousand random histories.
- [ ] **M7. Concurrent recorder** with `Atomic[int]` and a final merge. Acceptance: N threads record; each operation has one `invoke` and one `return`; unique `seq`.
- [ ] **M8. End-to-end example** in `examples/`: a real concurrent queue with an injectable bug, and a test that fails with the bug and passes without it. Acceptance: runs in CI.
- [ ] **M9. Release** on the nimble index.

**Optional** (they go into later releases, following the policy below)

- [ ] **M10. Time as an event** (`tick`, see [History](docs/HISTORY.md#time)).
- [ ] **M11. `checkPartitioned`** (D-12), for P-compositional models (maps by key).
- [ ] **M12. Perturbation** (D-18): module `nimlinear/perturb` with a fixed-seed `perturb()`, empty without `-d:nimlinearPerturb`. Acceptance: in the M8 example, the injected bug fails in fewer rounds with perturbation than without; the core compiles and passes its tests without importing the module.
- [ ] **M13. PCT scheduler** (D-18), optional: module `nimlinear/schedule`. Acceptance: the same seed produces the same history, byte for byte, across repeated runs; the M8 bug is found within a documented round budget.

## Release policy

The work is done with AI agents: small milestones are ready in hours. Releasing at every milestone would produce several versions on the same day, and users would have to follow updates with no real gain. So **finishing work and releasing are separate things** (D-21).

- **Milestones go to `master`, not to the nimble index.** Each finished milestone adds entries under `## Unreleased` in `CHANGELOG.md`.
- **A release bundles a set of changes that makes sense to users**, not a milestone. The first one requires the whole core (M0–M9).
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
