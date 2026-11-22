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
    models/                 # Register, EventFlag, BoundedQueue, CircuitBreaker
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
                            #   porcupine/ (Go, comparison only, not in CI)
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
- Releasing follows the [Release policy](README.md#release-policy): finishing a milestone is not a reason to release.

## Commits

Short messages in the imperative mood. A change to the saved format (D-05) never goes in the same commit as another change.

## Releasing

Follow the [Release policy](README.md#release-policy) first (green CI on `master`, 7 days without API or format changes, at least 7 days since the previous release).

1. Pick the number `X.Y.Z` (SemVer `0.x.y`: an API or format break bumps `x`).
2. Set it in `nimlinear.nimble` (`version`) and `src/nimlinear.nim` (`nimlinearVersion`); `tests/tsmoke.nim` checks they match.
3. In `CHANGELOG.md`, rename `## Unreleased` to `## X.Y.Z` and add a new empty `## Unreleased` above it.
4. Commit, then `git tag vX.Y.Z && git push origin vX.Y.Z`.
5. `.github/workflows/release.yml` checks the tag against both versions and the changelog, runs the tests and examples, and publishes the GitHub release with the changelog section as notes.
6. First release only: open a pull request to [nim-lang/packages](https://github.com/nim-lang/packages) adding `nimlinear` (later versions are picked up from the tags).
