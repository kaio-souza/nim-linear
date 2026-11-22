# Comparison and known gaps

Review of 2026-11-22, after M0–M13; status updated after M14–M24 the same day. nimlinear compared with the tools it borrows from. The descriptions of other tools come from their public documentation and papers as known to the authors; check the current versions before relying on a detail.

- **Porcupine** (Go): WGL checker with P-compositionality, `Step(state, input, output) -> (ok, next)` models, timeouts, HTML visualization.
- **Knossos** (Clojure, Jepsen): WGL and other search strategies, models as state machines over operations with their results, failure analysis with final paths, SVG rendering.
- **Lincheck** (Kotlin): generates concurrent scenarios from annotated operations, stress and model-checking modes, uses the data structure itself as the sequential specification, minimizes failing scenarios.

## Where nimlinear stands

| Feature | nimlinear | Porcupine | Knossos | Lincheck |
|---|---|---|---|---|
| Graph search with memoized failures (WGL) | yes (D-11) | yes | yes | n/a (enumerates) |
| Partitioning (P-compositionality) | yes (M11), any ordered key (M21) | yes | no | n/a |
| Pending (crashed) operations | yes (D-08) | yes | yes | n/a |
| Time as an event | yes (M10) | no (in the model) | no | no |
| Nondeterministic specifications | yes, `outcomes` (M14) | yes | yes | yes |
| Deterministic verdict and report | yes (D-20) | partial | partial | yes |
| Budget in states | yes | no | no | n/a |
| Wall-clock timeout | yes (M20) | yes | yes | yes |
| Failure explanation | longest prefix + alternatives | partial linearizations | final paths | interleaving trace |
| Minimization of failing histories | yes, heuristic (M16, D-24) | no | no | yes (re-runs code) |
| Visualization | ASCII timeline + HTML (M18) | HTML | SVG | trace text |
| Recorder for real threads | yes (M7) | user code | Jepsen | built in |
| Operation and scenario generation | round harness with user generator (M17) | no | Jepsen generators | yes |
| Controlled scheduling | PCT at manual points + `SchedLock` (M13, M19) | no | no | model checking, intercepts locks |
| Linear-time on long histories | yes (M22), except many pending ops | measured superlinear (shape C) | not measured | n/a |
| Saved format with a version | yes (M15) | n/a | EDN | n/a |

## Gaps

Each gap has a milestone in the [Roadmap](../CONTRIBUTING.md#roadmap). All eleven were addressed in M14–M24; the **Status** line under each says what was done and what remains.

1. **Nondeterministic specifications (M14).** `step(state, op)` returns one expected result and the checker compares it with the observed one. Porcupine and Knossos give the model the observed result and ask whether it is acceptable. What cannot be modeled today: a bag or pool whose `take` may return any item; operations allowed to fail spuriously (weak CAS, `tryLock`, a `wait` that may time out early); results that decide the next state (`alloc()` returning an id). Direction: an alternative contract `accepts(state, op, res): Option[S]` next to `step`, keeping `step` for the deterministic case and for the explanation in `Alternative.expected`.
   **Status:** done with `outcomes` instead (D-23), which also covers pending operations. Remains: choices from infinite sets.
2. **Format version (M15).** JSON Lines has no version. M10 already added `"tick"`; an older reader cannot tell why it fails. Direction: an optional first line such as `{"nimlinear":1}`, written by `toJsonLines` and checked by `parseJsonLines`.
   **Status:** done.
3. **Minimization (M16).** A failing history is reported whole. Direction: `shrink(h, init, model)` that removes operations (and then whole threads) while the verdict stays `vkNotLinearizable`, keeping the history valid (a removed `invoke` takes its `return`). Deterministic, so the shrunk history is a stable fixture.
   **Status:** done, with a guard against artificial failures that is a heuristic (D-24). Remains: re-running the real code on the smaller scenario, as Lincheck does.
4. **Visualization (M18).** `report` is text without the time axis. Direction: an ASCII timeline per thread in `report` (stable, golden-tested) and, optionally, a standalone HTML file with no external dependency.
   **Status:** done (`timeline`, `report(v, h)`, `timelineHtml`).
5. **Round harness (M17).** Users write threads, the recorder, the round loop, saving the failing history and printing the seed by hand (`examples/common/queue.nim` shows how much). Direction: a `runRounds` helper that takes the thread count, rounds, an operation generator, an executor and the model, and saves the failing history with its seed. No scenario generation beyond what the user's generator does (D-10 stays).
   **Status:** done (`runRounds`). Remains: automatic operation generation from annotations, as Lincheck does (out of scope, D-10).
6. **Wall-clock timeout (M20).** Only the state budget exists. It is deterministic but hard to size. Direction: an optional `timeout` next to `budget`, returning `vkInconclusive`; document that a timeout makes the verdict depend on the machine.
   **Status:** done.
7. **Scheduler and locks (M19).** Under `nimlinear/schedule`, a `perturb()` inside a critical section can hang the round, so bugs inside critical sections are out of reach. Direction: a `SchedLock` that yields to the scheduler while waiting. Also document that switches happen only at points the user placed.
   **Status:** done (`SchedLock`, deadlock flag). Remains: switch points are still placed by hand; plain `Lock` and atomics are not intercepted.
8. **Scalability on long histories (M22).** See [Measurements](MEASUREMENTS.md#benchmarks): quadratic where it should be linear. Direction: incremental `minRet`, a list of candidate operations instead of a scan from 0, a cheaper configuration key, an `invoke`→`return` table.
   **Status:** done (D-25): 40 000 operations in about 20 ms. Remains: many pending operations in a long history still grow the cost (shape E).
9. **Benchmarks (M23).** One easy shape, no comparison with Porcupine on the same histories, nothing in CI. Direction: shapes A–C plus partitioned and pending cases, exported as JSON Lines so Porcupine can run them, and a CI job that fails on a large regression.
   **Status:** done: shapes A–E, Porcupine side by side in [Measurements](MEASUREMENTS.md#benchmarks), `--check` job in CI. Remains: memory comparison, several runs with variance.
10. **Generic partition key (M21).** `partition` returns `int`; string keys must be hashed by the user. A collision is not wrong, only slower. Direction: any key type with `hash`, `==` and `<` (for D-20 order).
   **Status:** done.
11. **Smaller items (M24).** `History.events` is public, so a history can skip `newHistory` validation; async use (chronos, asyncdispatch) works with a logical thread index per task but is not documented; the macOS CI job installs Nim from `brew` without a pinned version.
   **Status:** done: `History` fields private (`events` accessor, `subHistory`), async usage in [History](HISTORY.md#async-code), macOS CI builds the exact Nim version from source.
