# Contributing

How the repository is organized and how the library itself is tested. To **use** the library in a project, see the [Usage guide](docs/GUIDE.md).

Documentation (every `.md` file and doc comments in code) is written in English until v1. Translations come later.

## Repository layout

```
nimlinear.nimble            # license = "MIT"; no requires besides nim >= 2.2
src/
  nimlinear.nim             # re-exports the core: history, model, checker, report, json
  nimlinear/
    history.nim             # Event, History, newHistory (M1)
    json.nim                # toJsonLines, parseJsonLines, toPayload/fromPayload (M1)
    model.nim               # Expected (M2)
    checker.nim             # checkLinearizable, checkPartitioned (M2–M4, M11, M14, M20–M22)
    report.nim              # report, timeline, timelineHtml (M5, M18)
    shrink.nim              # shrink (M16)
    recorder.nim            # Recorder, record; only with --threads:on (M7)
    rounds.nim              # runRounds; only with --threads:on (M17)
    models/                 # Register, EventFlag, BoundedQueue, CircuitBreaker, Map, Stack, Semaphore
    perturb.nim             # optional, M12; not imported by the core
    schedule.nim            # optional, M13; not imported by the core
    intercept.nim           # optional, P6; drop-in std/atomics + std/locks with switch points
tests/
  t*.nim                    # each file is a test executable (std/unittest)
  tsmoke.nim                # minimal M0 test
  tcompile_raises.nim       # negative compilation test (a step that raises does not compile)
  fixtures/                 # .jsonl histories
  golden/                   # expected report output for each fixture
  oracle/                   # brute-force oracle and history generator (M6)
  measure/                  # memory harness (M4); bench.nim (M23, --check runs in CI);
                            #   rounds_cost.nim (R6, R7); porcupine/ (Go, comparison only, not in CI)
examples/                   # programs that run in CI (M8)
docs/
  MEASUREMENTS.md           # measured memory and states (M4)
```

## Running the tests

CI (`.github/workflows/ci.yml`) and `nimble test` use the same runner, `tools/run.nims`: it compiles and runs each `tests/t*.nim` and **fails if there are none**. Extra flags go in `NIMFLAGS`; per-file options go in `<file>.nims` next to the file (`tests/tschedule.nims`, `tests/trounds.nims`). Locally:

```sh
nimble test                                      # every tests/t*.nim
NIMFLAGS="--mm:arc --threads:off -d:release" nimble test   # one CI combination
nimble examples                                  # every examples/*.nim
nimble bench                                     # benchmark suite with --check
nim c -r --threads:on tests/tsmoke.nim           # a single file
```

The CI matrix covers Linux/macOS/Windows × Nim 2.2.4/2.4.0 × `orc`/`arc` × `threads on/off` × debug/release, plus Nim 2.2.0 (the minimum in the `.nimble`) on Linux.

Rules:

- Recorder tests start with `when not compileOption("threads"): skip()`.
- `report` snapshots live in `tests/golden/<fixture>.txt`. To update them, run the test with `-d:nimlinearUpdateGolden` and review the diff before committing.
- No test depends on wall-clock time or on `HashSet`/`Table` order. Tests that need a specific interleaving run under `nimlinear/schedule` (see `tests/trounds.nim`); the timeout test uses an already-expired timeout. The examples and the benchmark measure behavior under the real OS scheduler, so they keep wide margins.

## Brute-force oracle (M6)

The oracle tries every permutation of the operations that respects real-time order, without memoization, and compares its verdict with the one from `checkLinearizable`.

History generator (`tests/oracle/`), always with `initRand(seed)` and the seed printed on failure:

| Parameter | Range |
|---|---|
| threads | 1 to 3 |
| total operations | 1 to 8 |
| model | `Register` (values in `0..2`, to force collisions) and `BoundedQueue` (capacity `1..2`) |
| pending | each operation has a 10% chance of having no `return` |
| results | 50% computed from a valid sequential execution (linearizable), 50% with one result swapped for another possible value (non-linearizable) |

Interleaving: the generator simulates threads with a random scheduler that, at each step, picks a thread and emits its next `invoke` or `return`. That gives histories with varied overlaps.

M6 criterion: 10 000 histories with no disagreement. A disagreement becomes a fixture in `tests/fixtures/` with the seed in its name.

## Memory measurement (M4)

- Measured with `getOccupiedMem()` before the call and sampled by the checker every 1 024 configurations, in builds with `-d:nimlinearMeasure` (without the flag, sampling generates no code). The peak minus the initial value is recorded.
- Measure with `--mm:orc -d:release`, on Linux, for the three sizes in the [Budget](docs/API.md#budget) table.
- Results go in `docs/MEASUREMENTS.md`: date, Nim version, machine, history (threads × operations), visited states, peak memory and time. The API budget table is updated from those numbers.

## Decisions and changelog

- Design change: a new entry in [Decisions](docs/DECISIONS.md) before the code.
- Every finished milestone adds entries under `## Unreleased` in `CHANGELOG.md`. Changes to the public API or to the JSON format are marked as **breaking**, because they restart the stabilization period.
- Releasing follows the [Releasing](#releasing) policy: finishing a milestone is not a reason to release.

## Commits

Short messages in the imperative mood. A change to the saved format (D-05) never goes in the same commit as another change.

## Roadmap

A milestone (M0, M1…) is a unit of work, not a version (see [Releasing](#releasing)). A box is checked only after the CI matrix confirms it. What each milestone delivered is in [`CHANGELOG.md`](CHANGELOG.md).

- [x] **M0–M8. Core**: project and CI, history types and JSON Lines, checker with memoized graph search, pending operations, budget, diagnostics, brute-force oracle, concurrent recorder, end-to-end example.
- [x] **M9. First release** (0.1.0): tagged. Not on the nimble index yet; that waits until the library is useful enough to the community (see [Releasing](#releasing)).
- [x] **M10–M13. Optional features**: time as an event (`tick`), `checkPartitioned`, perturbation points, PCT scheduler.
- [x] **M14–M24. Refinement** after comparing with Porcupine, Knossos and Lincheck ([`docs/COMPARISON.md`](docs/COMPARISON.md)): nondeterministic specifications (`outcomes`), format version line, `shrink`, `runRounds`, timeline (text and HTML), `SchedLock`, wall-clock timeout, generic partition key, linear-time search, benchmark suite with a CI check, private `History` fields.

### Planned (after 0.1.0), in priority order

Each item is a unit of work with the same rules as the milestones above. Items that change the public API or the JSON format are marked **breaking** and need an entry in [Decisions](docs/DECISIONS.md) before the code.

- [x] **P1. Async usage guide.** Document how to record and check code that runs under async (`asyncdispatch`, Chronos): tasks that migrate between OS threads, `begin` and `finish` on different threads, what counts as an operation boundary. Example in `examples/`. **Done:** [`docs/ASYNC.md`](docs/ASYNC.md), [`examples/async_counter.nim`](examples/async_counter.nim).
- [x] **P2. More shipped models**: `Map` (with `partition` by key), `Stack`, `Semaphore`, each with JSON hooks, a model test and an example. **Done:** `nimlinear/models/{map,stack,semaphore}`, tests in `tests/tmodels.nim`, examples `examples/{map,stack,semaphore}_race.nim`.
- [x] **P3. Default operation generator.** For each shipped model, a generator that draws operations from the model's own types, so simple tests need no `genOp`. Manual `genOp` stays the default for custom models. No new dependency (D-01). **Done:** `genRegisterOp`, `genEventOp`, `genQueueOp`, `genMapOp`, `genStackOp`, `genSemaphoreOp` (with tunable `random*Op` variants); none for `CircuitBreaker` (a `report` needs the permit of an earlier `acquire`).
- [x] **P4. Shrink with replay** ([D-27](docs/DECISIONS.md#d-27-shrink-with-replay-only-for-deterministic-rounds-p4)). **Done:** `runScenario`, opt-in `RoundsConfig.replayShrink`, determinism checked by running the failing scenario again; `RoundsResult.scenario` and `replay`.
- [x] **P5. Specifications with unbounded results.** Decide how to model results drawn from an open set (for example, any free id). **Done:** decided in [D-28](docs/DECISIONS.md#d-28-unbounded-results-stay-out-of-the-model-contract-p5): no new hook; a finite pool in the state with `outcomes`, documented in [Models](docs/MODELS.md#results-from-an-open-set). Not breaking.
- [x] **P6. Interception of `Lock` and atomics** ([D-26](docs/DECISIONS.md#d-26-switch-points-on-atomics-and-locks-through-a-drop-in-module-p6)). **Done:** `nimlinear/intercept` (drop-in for `std/atomics`/`std/locks`), `SchedLock.tryAcquire`; tests `tests/tintercept.nim`, `tests/tintercept_off.nim`; validated on the circuit breaker ([Measurements](docs/MEASUREMENTS.md#intercepted-atomics-and-locks-p6)).
- [x] **P7. Scheduler calibration and built-in scheduling** (found validating P6; [D-29](docs/DECISIONS.md#d-29-scheduler-built-into-the-round-harness-with-calibrated-steps)). **Done:** `RoundsConfig.schedule`/`depth`/`steps` with `steps = 0` calibrated on round 1, `Scheduler.stepsTaken`; replay shrink re-measured (no change); plain fields not intercepted, documented with the `perturb()` pattern.
- [x] **P8. Checker test coverage and structure.** **Done:** (1) `tests/twidewindow.nim`, up to 130 pending operations, so the window spans three words, under `-d:nimlinearDebug`; the debug invariants of (5) check `(f, window)` against the full bitset at every step, which replaces a separate `childKey` unit test; (2) the oracle tests also check `order` and `witness` (`verdictContentError` in `tests/oracle/oracle.nim`) and that a tampered order is caught; (3) `outcomes` models were already under the oracle (`tests/toutcomes.nim`); `checkPartitioned` vs `checkLinearizable` vs oracle on 10 000 Map histories; (4) same verdict field by field on a second check; (5) `-d:nimlinearDebug` invariants, on for `toracle`, `toutcomes`, `twidewindow`; (6) preprocessing split out of `checkCore` (`buildOps`); witness recording stays inline. A return with no invoke cannot reach the checker: `newHistory` rejects it. A safety net, done before P9 changes the memo key. Gaps in the current tests, most important first:
  1. **Multi-word window.** The [oracle](#brute-force-oracle-m6) generates 1–3 threads, so overlap rarely exceeds 64 operations and the cross-word shift in `childKey` (`src/nimlinear/checker.nim`) is barely exercised. A bug there is a false memo hit, which gives a wrong verdict with no warning. Add a directed test with 70–200 overlapping operations plus pending ones (they hold `f` back and widen the window), and a unit test of `childKey` against a naive full-bitset key.
  2. **Verdict content.** The oracle compares only the verdict kind. Also check that `order` replays through the model and respects real time, and that `witness.prefix` is a valid prefix whose `stuck` was a candidate.
  3. **`outcomes` models and `checkPartitioned` under the oracle.** Add a nondeterministic model (a bag) and compare `checkPartitioned` with `checkLinearizable` on the same random histories, not only behind `-d:nimlinearVerifyPartition`.
  4. **Determinism (D-20).** Check the same history twice and compare verdict, order and witness field by field.
  5. **Debug invariants.** Under `-d:nimlinearDebug`, assert at each step that `(f, window)` matches the global bitset and that `minRet` is the true minimum. No cost in release builds.
  6. **Split `checkCore`** (about 175 lines) into preprocessing, search and witness recording, so each can be tested alone. Example: a `return` with no `invoke` is silently ignored today; make it an explicit tested case.
- [x] **P9. Checker performance.** **Done** (each step an experiment, kept only with a clear gain on `bench` and `memory.nim`; numbers in [Measurements](docs/MEASUREMENTS.md#checker-performance-p9-2026-11-25)):
  1. **Kept: the window inline in the memo key.** Key of 24 bytes (`f` as 32 bits, word count, first word inline, copy-on-write `ref seq` beyond 64 operations of overlap), no allocation per configuration, one `containsOrIncl` per configuration. A n = 16: 1.44 s to 0.86 s; B n = 9: 1.81 s to 1.32 s; C 15 % faster; memory unchanged. A first version with two inline words and a cached hash was dropped: up to 1.8x more memory, because every key byte is paid in every `HashSet` slot. Found on the way: the private `hash`/`==` of `Config` were never called (the set resolves them at the instantiation site); they are now exported (the type stays private), which matters since `extra` is a `ref`.
  2. **Dropped: pending operations out of `(f, window)`.** Implemented and correct, but 6–25 % slower on A and B and no gain on E (the search linearizes pending writes as it meets them). The limit of D-25 stays; no decision entry, since the memo key did not change.
  3. **Not done: parallel `checkPartitioned`.** No measured case where it pays, and it would make thread safety a requirement of every model. Reopen with a real history whose parts are large.
  4. **Not planned:** building `alternatives` lazily (unchanged).
- [x] **P10. Model from the sequential implementation.** **Done:** `nimlinear/seqmodel`, `sequentialModel(name, S, Op, Res, apply)` defines `step` from `apply(var S, Op): Res`; not breaking (it generates the existing `step` contract); aliasing guard under `-d:nimlinearDebug`; documented in [Models](docs/MODELS.md#from-a-sequential-implementation-p10); test `tests/tseqmodel.nim`. Lincheck uses the data structure itself, run sequentially, as the specification; nimlinear asks the user to write `step` or `outcomes` plus `hash` and `==`, which is the main entry cost for someone who only wants to test their own structure. Direction: an adapter that builds a model from the implementation: the state is a copy of the structure, and `step` applies the operation to the copy and returns its result. Trade-offs: one copy per checker step, so slower and heavier than a hand-written model on large states; the structure must be copyable, hashable and comparable by value (a structure built on `ref` or `ptr` needs a deep copy and a value `==`, or the memo key is wrong); the sequential implementation must itself be correct, since a bug present in both the concurrent and sequential paths is invisible. Possibly **breaking** if it adds a new model contract; needs a decision first. The hand-written model stays the documented default.
- [x] **P11. Bounded exhaustive exploration next to PCT.** **Done** ([D-32](docs/DECISIONS.md#d-32-bounded-exhaustive-exploration-next-to-pct-amends-d-02-and-d-07)): `RoundsConfig.explore`/`preemptions`/`maxSchedules`, in this repository as an optional mode of the scheduler; no partial-order reduction yet (preemption bounding instead); `reset` is the same `setup`/`teardown` as `runRounds`. Test: `tests/texplore.nim`. Needs a decision that amends [D-02](docs/DECISIONS.md#d-02-checker-separate-from-the-explorer) and [D-07](docs/DECISIONS.md#d-07-exhaustive-exploration-out-of-scope) before any code. PCT gives a probability floor per round and no absence claim; Lincheck's model-checking mode enumerates every interleaving of a small scenario. Goal: **both strategies**, not one replacing the other. PCT stays as is for large scenarios and real code; the exhaustive mode covers small scenarios (few threads, few operations, few switch points) completely, over the switch points that already exist (`perturb()`, and atomics and locks under `nimlinear/intercept`). Constraints: an optional strategy of the scheduler, chosen in `RoundsConfig`, producing histories only, so the checker is unchanged ([D-30](docs/DECISIONS.md#d-30-the-checker-stays-independent-of-the-recorder-and-the-scheduler)); "exhaustive" means only over the controlled switch points, and plain fields and `Cond` stay outside, which the docs must say; a hard cap on explored interleavings, with an explicit "not complete" result when the cap is hit. Open questions: in this repository as an optional module, or a separate project as D-02 says; partial-order reduction to keep the count manageable; how the code under test is reset between interleavings (the same `reset` as `runRounds`).
- [x] **P12. Switch-point trace in the failure report.** **Done:** `SwitchPoint`, `Scheduler.trace`, `RoundsResult.trace`/`traceSavedTo`, `formatTrace`; locations come from templates (`perturb`, intercept wrappers, `acquire`, `withLock`, `wait`); test in `tests/tintercept.nim`. On failure, Lincheck shows which line each thread was at when it switched; nimlinear reports operations only, although the scheduler already knows every switch. Direction: the scheduler records the sequence of switch points of the failing round (thread, kind: `perturb`, atomic or lock, source location from `instantiationInfo`), and the round harness shows it next to the checker's report. Constraint: [D-30](docs/DECISIONS.md#d-30-the-checker-stays-independent-of-the-recorder-and-the-scheduler). The trace lives in `schedule` and `rounds`; the checker, `History` and the JSON Lines format do not import or carry it, and the verdict never depends on it. If saved, it goes in a separate file next to the history, not in it. Trade-offs: memory per round while recording (a bounded buffer, kept only for the failing round); the trace is exact only for controlled switch points, like replay (see [Comparison](docs/COMPARISON.md#probabilistic-coverage-of-pct)).
- [ ] **P19. Nimony (Nim 3) support.** Deferred until Nimony has a release; Nim 2 stays the primary target, and the history format (D-05) and the public API do not change. Expected friction, from Nimony's docs (not yet compiled):
  - exceptions: no `raises: [list]`, no `CatchableError`/`Defect`; one error type per proc or `ErrorCode`;
  - checked generics: the model contract (`step`, `hash`, `outcomes`) needs a concept or `{.untyped.}`; `mixin`/`compiles` checks reworked;
  - `typedesc` parameters written `typedesc[M]`, not inferred; `nil` on `ptr` needs `nil ptr T`;
  - `func` is `noSideEffect` by default (favorable to the pure-step rule, R8); no macros, plugins instead.
  Plan when it ships: (1) compile `history`, `model`, `checker` with `{.feature: "v2".}` and collect the real errors; (2) a portable checker layer behind `when defined(nimony)`; (3) a Nimony CI job, allowed to fail, for the checker; (4) the execution layer (`recorder`, `rounds`, `schedule`, `intercept`) only once Nimony documents threads; the `RoundAborted` Defect (P14) needs another mechanism there.
- [x] **P18. Interception of non-std atomics modules.** **Done:** `interceptAtomics(module, writes = [...], reads = [...], types = [...])` in `nimlinear/intercept`, used in a short shim the code under test imports instead of the original module; a plain `export` without `-d:nimlinearPerturb`. Test: `tests/tintercept_custom.nim` (a stand-in module in `tests/fixtures/`). Checked on `threading/atomics` of `nim-lang/threading` 653c8eb (load-then-store race found, CAS loop passing, `+=` then `load` found only with `-d:nimlinearInterceptLoads`). Found on the way: `export m except ...` hides the values of a `{.pure.}` enum (hence `types`); a `genSym`'d `let` in the generated template broke inside closures ("environment misses"). Limit: library files that import the original module directly are not intercepted. In that version of the library, `threading/atomics` is deprecated and `smartptrs`/`channels` import `std/atomics`.
- [x] **P17. Known limits, second pass.** **Done:** round watchdog (`RoundsConfig.roundTimeout`, `.hung.txt`, exit 124) for rounds blocked outside the switch points; sleep-set reduction for `explore` (`RoundsConfig.reduce`, step footprints, `noteAccess`), sound but with modest gains, full DPOR not done; `Shared[T]` for plain fields; witness recording split out of `checkCore` (`recordFailure`). Tests: `tests/tprogress.nim`, `tests/treduce.nim`, `tests/tshared.nim`.
- [x] **P16. `Cond` under the scheduler and atomic loads as switch points** (found testing `nim-lang/threading`, [D-31](docs/DECISIONS.md#d-31-atomic-loads-as-opt-in-switch-points-and-cond-under-the-scheduler)). **Done:** `SchedCond`, `Cond` mapped to it by `nimlinear/intercept`, opt-in `-d:nimlinearInterceptLoads`, `-d:nimlinearInterceptNoLocks`. Tests: `tests/tschedcond.nim`, `tests/tintercept_loads.nim`.
- [x] **P13. Crash-safe seed and sanitizer recipe.** **Done:** `RoundsConfig.trackProgress`, `progressPath`, `RoundsResult.previousRun`; a real crash test (`tests/tprogress.nim` runs itself as a child that exits inside round 3); ASan/TSan recipe in [Guide](docs/GUIDE.md#step-5c-optional-crashes-and-sanitizers), checked with an injected use after free, and with LeakSanitizer on `nim-lang/threading` #59 ([Measurements](docs/MEASUREMENTS.md#external-code-second-pass-known-bugs-of-nim-langthreading-2026-11-25)). Most concurrency issues found in Nim libraries are memory bugs (use after free, double free, refcount races), which no operation result shows. Today a round that crashes kills the process and its seed is lost. Direction: `runRounds` writes the seed and round number before each round (a small file or stderr, flushed), so a crash leaves a seed to replay; plus a documented recipe for running rounds under TSan and ASan (`--passC:-fsanitize=...`), where the controlled scheduler drives interleavings the sanitizer alone would rarely see. Constraint: [D-30](docs/DECISIONS.md#d-30-the-checker-stays-independent-of-the-recorder-and-the-scheduler), the checker is unchanged. Trade-offs: one small write per round; under a sanitizer, replay is still exact only at controlled switch points. Validation candidates: `nim-lang/threading` issues #45 and #59 (refcount races in `SharedPtr` and the `Chan` destructor).
- [x] **P14. Liveness detection in the scheduler.** **Done:** `abortOnStuck`/`stepLimit` in `initScheduler`, `RoundAborted`, `abortReason`; `runRounds` enables it under `schedule`/`explore` (`RoundsConfig.stepLimit`); a lost wakeup is found by exploration and reported as a deadlock, a livelock is stopped at `stepLimit` (`tests/tliveness.nim`). Validated on `nim-lang/threading` `WaitGroup` (lost wakeup as a deadlock, [Measurements](docs/MEASUREMENTS.md#external-code-second-pass-known-bugs-of-nim-langthreading-2026-11-25)); `nim-taskpools` #41 could not be used (no fix to compare with). Deadlocks and livelocks show no wrong result either; at most an operation stays pending, which is not a violation. Direction: generalize the `SchedLock` deadlock flag: when every registered thread waits at a controlled point, report a deadlock with the seed and the pending operations; and a progress limit (N switch points with no operation completing) that fails the round with its seed instead of hanging CI. Constraint: D-30, as above. Trade-offs: not complete; a wait outside the controlled points (I/O, `Cond`) only shows as a timeout; the progress limit needs a default that does not flag slow but correct code. Validation candidate: `status-im/nim-taskpools` issue #41 (workers spinning forever).
- [x] **P15. Invariants at the end of a round.** **Done:** a `quiescent: proc (obj: var Obj): string` parameter of `runRounds` (not in `RoundsConfig`, which is not generic), `RoundsResult.invariant`; test `tests/tquiescent.nim` (a leaked reference fails its round with a linearizable history). Validated on `nim-lang/threading` #45 and #59 (leaks of `SharedPtr` and of the `Chan` destructor, [Measurements](docs/MEASUREMENTS.md#external-code-second-pass-known-bugs-of-nim-langthreading-2026-11-25)). Many memory bugs leave a trace in the state before they crash. Direction: an optional hook in `RoundsConfig` (for example `quiescent: proc (): string`, empty meaning fine), called once all threads have finished, whose message fails the round with its seed. Examples: a reference count back to its expected value, no occupied memory left (`getOccupiedMem`), the structure's internal length matching what the history implies. Constraint: D-30; the hook belongs to the harness, never to the checker. Trade-offs: the user writes the invariant, so its value is only as good as the invariant; runs only at quiescence, so a transient violation is not seen. Validation candidates: the same as P13.

Out of scope, by existing decisions: exhaustive interleaving exploration (D-07, D-02) and property-based testing integration (D-10). Relaxed memory orderings are a structural limit of a sequential-consistency checker and are only documented.

### Found on code review

Gaps found by rereading the source, not yet measured unless stated. R2 was not reproduced after one occurrence and is closed; notes for a recurrence follow the list.

- [x] **R1. Exceptions in `exec` are not reported (known issue in 0.1.0; fixed: `RoundsResult.error`, `ExecError`).** In `src/nimlinear/rounds.nim`, the worker has no error handling: an exception kills the thread, the operation stays pending, and the round can pass. The harness must tell a pending operation apart from a crash: report the exception as a failure with its message, and guarantee `teardown` and the `ThreadHooks` `leave` run (try/finally), so a crash cannot hang a scheduled round. First verify what Nim does with an unhandled exception in a thread: it may abort the whole process rather than only kill the thread. Also free the shared thread array and join the started threads if `createThread` fails part-way.
- [x] **R2. Intermittent SIGSEGV on Windows (known issue in 0.1.0; not reproduced since, closed 2026-11-24).** Seen once, in CI run 44985979216 (commit `5100237`), job `windows-latest, nim 2.2.4, arc, threads=on, release`: `SIGSEGV: Illegal storage access. (Attempt to read from nil?)` in the first test of `tests/trounds.nim` (atomic counter, no scheduler), with no stack trace. Not reproduced afterwards: every later CI run passed, including 88 runs of `trounds` on Windows with threads on in run 45512338861 (8 jobs × 11, arc and orc). The CI step that repeats `trounds` with stack traces stays in `.github/workflows/ci.yml`. If it happens again, see the notes below.
- [x] **R3. `runRounds` ignores partitioning.** It always calls `checkLinearizable`; `shrink` accepts `partitioned` but the harness never passes it. Use `checkPartitioned` when the model defines `partition`, and expose the choice in `RoundsConfig`. The `shrink` call in `runRounds` must receive the same choice (`partitioned`).
- [x] **R4. Wall-clock timeout in the harness.** `RoundsConfig` exposes only `budget`. Add a `timeout` field passed to the checker, with the same caveat as in the API: it makes the verdict machine-dependent.
- [x] **R5. Initial state per round.** `runRounds` takes one fixed `init`. Allow the initial state to depend on the round (for example, a function of the round number), so a test can start from several states without writing its own loop.
- [x] **R6. Thread creation per round.** Each round creates and joins `threads` OS threads. Measure the cost with many rounds; if it dominates, reuse a pool of threads across rounds. Measure before changing. **Done:** measured (create + join is ~60–67% of a round, but ~50 µs); no pool, rounds stay isolated ([Measurements](docs/MEASUREMENTS.md#round-harness-cost)).
- [x] **R7. Recorder overhead is not measured.** Every event takes the shared atomic counter, which is a contention point and can change the interleaving being tested. Measure the overhead and its effect on the observed interleavings, and document the result in `docs/MEASUREMENTS.md`. **Done:** ~110–140 ns per operation after padding the per-thread buffers (was ~165); recording makes a tight race ~8× less frequent ([Measurements](docs/MEASUREMENTS.md#round-harness-cost)).
- [x] **R8. Model contract not enforced.** `step` must be pure, but a `ref` or a global inside `step` compiles without a warning, and the checker's assumptions and its determinism break silently. Document the rule with an example of what fails, and consider a compile-time check where Nim allows one. **Done:** `step`/`outcomes` are called through a `func`, so side effects (globals, I/O) do not compile; mutation through `ref`/`ptr` is documented as not caught ([Models](docs/MODELS.md#contract)); escape hatch `-d:nimlinearImpureModel`.
- [x] **R9. Saved histories go to a fixed name.** `runRounds` writes `<name>-seed<seed>-round<r>.jsonl` to `getTempDir()` by default, so a later run with the same seed overwrites an earlier file without warning. Document it, or add a unique suffix when the file exists.
- [x] **R10. No round or seed for the scheduler.** `setup(obj)` receives neither the round nor the seed, so a `Scheduler` created in `setup` (as the Guide says) gets the same PCT priorities and change points in every round; only the operations vary. `tests/trounds.nim` works around it with a global round counter. Pass the round (or a derived scheduler seed) to `setup`, or integrate the scheduler into `runRounds`, and fix the Guide.
- [x] **R11. `perturb()` from an unregistered thread under a scheduler.** `switchPoint` uses a thread-local id that defaults to 0, so the main thread (in `setup`/`teardown`) or any thread outside `ThreadHooks` acts as thread 0 and can hang the round or switch before every thread has reached `enter`. Ignore threads that did not call `enter` (and document it), or raise.
- [x] **R12. `shrink` has no `timeout`.** It runs up to O(n²) checks, each with the full `budget`, so a large failing history can take very long. Add a `timeout`/overall budget and document the cost.
- [x] **R13. `order` of `checkPartitioned` is not a global order.** It is the concatenation of the per-key orders, and ticks appear once per part. `docs/API.md` describes `order` only for `checkLinearizable`. Document it, or build a real merged order. **Done:** documented in [API](docs/API.md) and in the `checkPartitioned` doc comment; no merged order is built.
- [x] **R14. A failed save is silent.** In `runRounds`, an error while creating the directory or writing the file leaves `savedTo = ""` with no reason. Keep the error message in `RoundsResult` and show it in `describe`.
- [x] **R15. Seed arithmetic in `runRound`.** `cfg.seed * 1_000_003 + round + 1` overflows for very large seeds (`OverflowDefect` in debug, wraps in release), and `(seed, round + 1_000_003)` collides with `(seed + 1, round)`. Use a proper mixing function and document that `(seed, round)` is the only guaranteed identity.

- [x] **R16. Shrink guard misses a removed producer.** Found while testing `nim-lang/threading` `Chan`: a shrunk history kept `dequeue() -> value(3)` with no `enqueue(3)` left, stuck with the same expected result as the original, so the D-24 guard accepted it. The guard compares the stuck operation and its *expected* result, not whether its *observed* result can still be produced. The original history of that round was not saved, so whether it was the same bug is unknown. Directions to evaluate: also compare the stuck operation's other alternatives, or never remove an operation whose result or argument equals the stuck operation's observed result (model-agnostic only by payload equality). Also save the original history next to the shrunk one in `runRounds`. **Done:** `Witness.stuckEverFit` (the stuck operation's observed result matched the model in some explored configuration) is part of the shrink signature, so a removal that makes the result unexplainable in every order is rejected; `runRounds` saves the recorded history as `.original.jsonl` (`RoundsResult.originalSavedTo`). Tests: `tests/tshrink.nim`, `tests/trounds.nim`.

#### If the Windows SIGSEGV (R2) comes back

Facts: one occurrence, arc (not orc), Nim 2.2.4, release, first `trounds` test, before any `[OK]`. The `Thread` objects were already in `allocShared` memory (so not [nim#26726](https://github.com/nim-lang/Nim/issues/26726), a `Thread` moved after `createThread`). At that commit the `Recorder` kept a `{.threadvar.}` `seq` (`tUsed`) filled by every worker thread; it was removed in `4098f49`, and the crash has not been seen since.

Hypotheses, most likely first:

1. **Thread-local `seq` at thread exit.** A `{.threadvar.}` holding heap memory, on Windows, at thread exit. `joinThread` does not free thread-local resources ([forum](https://www.mail-archive.com/nim-general@lists.nim-lang.org/msg32231.html), [nim#19146](https://github.com/nim-lang/Nim/pull/19146)). Check: does new code add a `threadvar` with a `seq`, `string` or `ref`? Current threadvars (`schedule.nim`: `tTid`, `tRegistered`; `perturb.nim`: `tGen`, `tRng`) hold no heap memory.
2. **A Nim runtime bug with threads on Windows (TLS or thread exit).** Similar reports exist with no root cause ([forum: ~10% crashes, Windows only](https://www.mail-archive.com/nim-general@lists.nim-lang.org/msg32761.html)); a TLS issue was worked around with `--tlsEmulation:on` ([SO](https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/73525170/exe-has-stopped-working-when-use-thread-module)).
3. **A data race in nimlinear** that only the Windows scheduler exposes. None was found on rereading `rounds.nim`, `recorder.nim` and `schedule.nim`.

What to do:

- Get the trace from the "Repeat trounds with stack traces" CI step; note job, Nim version, `mm` and the test that crashed.
- Add a manual (`workflow_dispatch`) Windows stress workflow that runs `trounds` ~200 times per variant: the failing commit vs `5100237` vs `master`; `arc` vs `orc`; with and without `--tlsEmulation:on`; with `-d:useMalloc`. A variant that crashes at a measurable rate narrows the cause.
- If it reproduces with a minimal program using only `createThread`/`joinThread`, report it to Nim with that program.

## Releasing

A milestone is not a reason to release. A release bundles a set of changes that makes sense to users. Releases are marked by a `vX.Y.Z` tag. There is no automated release workflow.

Policy:

- **Milestones go to `master`.** Each finished milestone adds entries under `## Unreleased` in `CHANGELOG.md`.
- **Before releasing:** full CI matrix green on `master`.
- **At least 2 days between releases**, so that several changes bundle into one release instead of many on the same day. Single exception: a fix for a bug that makes the checker return a **wrong verdict** (false `vkLinearizable` or false `vkNotLinearizable`). That fix ships alone, as soon as CI passes.
- **After the package is published on Nimble** (while it has users): the stabilization period returns, with no change to the public API or to the JSON format in the last **7 days** before a release, and at least **7 days between releases**. The reason is that real use can then find problems before the next release. See [D-33](docs/DECISIONS.md#d-33-release-spacing-while-there-are-no-users-amends-d-21).
- **Numbering:** SemVer `0.x.y` while the API may change. The number is chosen at release time, based on what changed (API or format break: `x`; anything else: `y`). The roadmap does not reserve version numbers for milestones.
- **Documentation language:** English until v1. Translations come before v1.

Steps:

1. Pick the number `X.Y.Z` (SemVer `0.x.y`: an API or format break bumps `x`).
2. Set it in `nimlinear.nimble` (`version`) and `src/nimlinear.nim` (`nimlinearVersion`); `tests/tsmoke.nim` checks they match.
3. In `CHANGELOG.md`, rename `## Unreleased` to `## X.Y.Z` and add a new empty `## Unreleased` above it.
4. Commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`. The tag must point at the commit that has the version set in step 2.
5. Publish the GitHub release by hand with the changelog section as notes.
6. First release only: open a pull request to [nim-lang/packages](https://github.com/nim-lang/packages) adding `nimlinear` (later versions are picked up from the tags).
