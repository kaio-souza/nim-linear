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
- [ ] **P4. Shrink with replay** (needs a Decisions entry first). After the current shrink, re-run the real code on the reduced scenario, under the scheduler when one is used, and keep a removal only if the failure reproduces. Deterministic for a given seed. Optional flag; the history-only shrink stays the default.
- [ ] **P5. Specifications with unbounded results.** Decide how to model results drawn from an open set (for example, any free id), such as a predicate on the observed result. Requires a Decisions entry and, if it changes `outcomes`, a **breaking** note.
- [ ] **P6. Interception of `Lock` and atomics** (large, after real use). Switch points for the primitives under test without manual `perturb()`, keeping determinism under the scheduler. Not started until P4 and real use show the need.

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
- **Before releasing:** full CI matrix green on `master`, and no change to the public API or to the JSON format in the last **7 days** (stabilization period, so real use can find problems first).
- **At least 7 days between releases** (not applicable to the first one, which only needs the stabilization period above). Single exception: a fix for a bug that makes the checker return a **wrong verdict** (false `vkLinearizable` or false `vkNotLinearizable`). That fix ships alone, as soon as CI passes.
- **Numbering:** SemVer `0.x.y` while the API may change. The number is chosen at release time, based on what changed (API or format break: `x`; anything else: `y`). The roadmap does not reserve version numbers for milestones.
- **Documentation language:** English until v1. Translations come before v1.

Steps:

1. Pick the number `X.Y.Z` (SemVer `0.x.y`: an API or format break bumps `x`).
2. Set it in `nimlinear.nimble` (`version`) and `src/nimlinear.nim` (`nimlinearVersion`); `tests/tsmoke.nim` checks they match.
3. In `CHANGELOG.md`, rename `## Unreleased` to `## X.Y.Z` and add a new empty `## Unreleased` above it.
4. Commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`. The tag must point at the commit that has the version set in step 2.
5. Publish the GitHub release by hand with the changelog section as notes.
6. First release only: open a pull request to [nim-lang/packages](https://github.com/nim-lang/packages) adding `nimlinear` (later versions are picked up from the tags).
