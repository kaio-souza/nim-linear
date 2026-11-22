# Changelog

Each release lists what changed for users. Changes to the public API or to the saved JSON format are marked **breaking**. Work in progress accumulates under `## Unreleased`; see [Release policy](README.md#release-policy). Milestone numbers (M0…M24) refer to the [Roadmap](README.md#roadmap).

## Unreleased

Nothing has been released yet. The first release will contain everything below. Intermediate API changes made before it are not listed as breaking, since no version had them.

### History and format

- `Event`, `History`, `OpId`/`ThreadId`/`SeqNo`; `newHistory` validates and sorts; `History` fields are private (`events` accessor) and `subHistory` takes whole operations out of a valid history (M1, M24).
- Pending operations (invoke without return), considered both applied and not applied (M3, D-08).
- Time as an event: `ekTick`, `tickEvent`, `Recorder.tick` (M10, D-22).
- JSON Lines with `toPayload`/`fromPayload` hooks, byte-for-byte round trip, and a first line `{"nimlinear":1}`; files without it still parse; unknown versions are rejected (M1, M15, D-23).

### Checking

- `checkLinearizable`: graph search memoizing `(linearized, state)` (D-11), deterministic order (D-20), `budget` and `vkInconclusive` (M2, M4), optional wall-clock `timeout` with `timedOut` (M20). `budget < 1` counts as 1.
- Linear time on long histories with bounded overlap: memo key `(f, window)`, incremental `minRet` (M22, D-25). 40 000 operations in about 20 ms.
- Nondeterministic specifications through `outcomes` (M14, D-23); `hasOutcomes`.
- `checkPartitioned` for P-compositional models (M11, D-12), with any key type that has `hash`, `==` and `<` (M21); ticks go into every part; `-d:nimlinearVerifyPartition` cross-checks a new `partition` against the unpartitioned search.
- Witness with longest prefix, stuck operation and alternatives; pending operations are never stuck.

### Diagnostics

- `report` (stable, golden-tested), `timeline`, `report(v, h)` and the standalone `timelineHtml` (M5, M18).
- `shrink`: deterministic minimization that keeps the stuck operation and its expected result (M16, D-24).

### Recording and running

- `Recorder` (`--threads:on`): per-index buffers, atomic `seq`, `record` template, `snapshot` (M7). An index may `begin` on one OS thread and `finish` on another (async tasks that migrate); two calls using one index at the same time are reported as misuse instead of racing.
- `runRounds`/`runRound`/`describe`: seeded rounds against a real object, check, shrink, save (M17); `RoundsConfig` is validated.
- Optional modules, not imported by the core: `nimlinear/perturb` (`perturb()` points, empty without `-d:nimlinearPerturb`, M12) and `nimlinear/schedule` (PCT `Scheduler`, `SchedLock`, one active scheduler at a time, M13, M19, D-18).

### Models

- `Register`, `EventFlag`, `BoundedQueue`, `CircuitBreaker` (with the cool-down as `tick`) in `nimlinear/models/*`, each with JSON hooks.

### Examples, tests and tooling

- `examples/quickstart.nim` (the README quickstart, checked by `tests/treadme.nim`), `examples/queue_race.nim` (M8), `examples/queue_perturb.nim`, `examples/queue_pct.nim`.
- Brute-force oracle with random histories (pending operations, ticks, `outcomes`), 10 000 histories per model (M6).
- Benchmark suite with a Porcupine comparison and a regression `--check` (M23); results in `docs/MEASUREMENTS.md`.
- One runner for `nimble test`/`examples`/`bench` and CI (`tools/run.nims`); CI on Linux, macOS, Windows × Nim 2.2.4, 2.4.0 × orc/arc × threads on/off × debug/release, plus Nim 2.2.0 on Linux; release workflow on `vX.Y.Z` tags.
