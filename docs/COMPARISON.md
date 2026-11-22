# Comparison and known gaps

Review of 2026-11-22, after M0–M13. nimlinear compared with the tools it borrows from. The descriptions of other tools come from their public documentation and papers as known to the authors; check the current versions before relying on a detail.

- **Porcupine** (Go): WGL checker with P-compositionality, `Step(state, input, output) -> (ok, next)` models, timeouts, HTML visualization.
- **Knossos** (Clojure, Jepsen): WGL and other search strategies, models as state machines over operations with their results, failure analysis with final paths, SVG rendering.
- **Lincheck** (Kotlin): generates concurrent scenarios from annotated operations, stress and model-checking modes, uses the data structure itself as the sequential specification, minimizes failing scenarios.

## Where nimlinear stands

| Feature | nimlinear | Porcupine | Knossos | Lincheck |
|---|---|---|---|---|
| Graph search with memoized failures (WGL) | yes (D-11) | yes | yes | n/a (enumerates) |
| Partitioning (P-compositionality) | yes (M11), `int` key | yes | no | n/a |
| Pending (crashed) operations | yes (D-08) | yes | yes | n/a |
| Time as an event | yes (M10) | no (in the model) | no | no |
| Nondeterministic specifications | **no** (gap 1) | yes | yes | yes |
| Deterministic verdict and report | yes (D-20) | partial | partial | yes |
| Budget in states | yes | no | no | n/a |
| Wall-clock timeout | **no** (gap 6) | yes | yes | yes |
| Failure explanation | longest prefix + alternatives | partial linearizations | final paths | interleaving trace |
| Minimization of failing histories | **no** (gap 3) | no | no | yes |
| Visualization | **no** (gap 4) | HTML | SVG | trace text |
| Recorder for real threads | yes (M7) | user code | Jepsen | built in |
| Operation and scenario generation | **no** (gap 5) | no | Jepsen generators | yes |
| Controlled scheduling | PCT at manual points (M13) | no | no | model checking, intercepts locks |
| Linear-time on long histories | **no, quadratic** (gap 8) | yes | yes | n/a |
| Saved format with a version | **no** (gap 2) | n/a | EDN | n/a |

## Gaps

Each gap has a milestone in the [Roadmap](../README.md#roadmap). Gaps 1 and 2 change the public API or the saved format, so they should land before the first release (M9).

1. **Nondeterministic specifications (M14).** `step(state, op)` returns one expected result and the checker compares it with the observed one. Porcupine and Knossos give the model the observed result and ask whether it is acceptable. What cannot be modeled today: a bag or pool whose `take` may return any item; operations allowed to fail spuriously (weak CAS, `tryLock`, a `wait` that may time out early); results that decide the next state (`alloc()` returning an id). Direction: an alternative contract `accepts(state, op, res): Option[S]` next to `step`, keeping `step` for the deterministic case and for the explanation in `Alternative.expected`.
2. **Format version (M15).** JSON Lines has no version. M10 already added `"tick"`; an older reader cannot tell why it fails. Direction: an optional first line such as `{"nimlinear":1}`, written by `toJsonLines` and checked by `parseJsonLines`.
3. **Minimization (M16).** A failing history is reported whole. Direction: `shrink(h, init, model)` that removes operations (and then whole threads) while the verdict stays `vkNotLinearizable`, keeping the history valid (a removed `invoke` takes its `return`). Deterministic, so the shrunk history is a stable fixture.
4. **Visualization (M18).** `report` is text without the time axis. Direction: an ASCII timeline per thread in `report` (stable, golden-tested) and, optionally, a standalone HTML file with no external dependency.
5. **Round harness (M17).** Users write threads, the recorder, the round loop, saving the failing history and printing the seed by hand (`examples/common/queue.nim` shows how much). Direction: a `runRounds` helper that takes the thread count, rounds, an operation generator, an executor and the model, and saves the failing history with its seed. No scenario generation beyond what the user's generator does (D-10 stays).
6. **Wall-clock timeout (M20).** Only the state budget exists. It is deterministic but hard to size. Direction: an optional `timeout` next to `budget`, returning `vkInconclusive`; document that a timeout makes the verdict depend on the machine.
7. **Scheduler and locks (M19).** Under `nimlinear/schedule`, a `perturb()` inside a critical section can hang the round, so bugs inside critical sections are out of reach. Direction: a `SchedLock` that yields to the scheduler while waiting. Also document that switches happen only at points the user placed.
8. **Scalability on long histories (M22).** See [Measurements](MEASUREMENTS.md#benchmarks): quadratic where it should be linear. Direction: incremental `minRet`, a list of candidate operations instead of a scan from 0, a cheaper configuration key, an `invoke`→`return` table.
9. **Benchmarks (M23).** One easy shape, no comparison with Porcupine on the same histories, nothing in CI. Direction: shapes A–C plus partitioned and pending cases, exported as JSON Lines so Porcupine can run them, and a CI job that fails on a large regression.
10. **Generic partition key (M21).** `partition` returns `int`; string keys must be hashed by the user. A collision is not wrong, only slower. Direction: any key type with `hash`, `==` and `<` (for D-20 order).
11. **Smaller items (M24).** `History.events` is public, so a history can skip `newHistory` validation; async use (chronos, asyncdispatch) works with a logical thread index per task but is not documented; the macOS CI job installs Nim from `brew` without a pinned version.
