# Changelog

Each release lists what changed for users. Changes to the public API or to the saved JSON format are marked **breaking**. Work in progress accumulates under `## Unreleased`; see the [Release policy](CONTRIBUTING.md#releasing). Milestone numbers (M0…M24) refer to the [Roadmap](CONTRIBUTING.md#roadmap).

## Unreleased

### Fixed

- An exception raised by `exec` now fails the round: `RoundsResult.error` names the thread, operation and exception; `ThreadHooks.leave` and `teardown` still run; `runRound` raises the new `ExecError`. Threads already started are joined if `createThread` fails (R1).
- `perturb()` and `SchedLock` from a thread that did not call `enter` (or already called `leave`) are ignored by the scheduler instead of acting as thread 0 (R11).
- A history is no longer overwritten when saved twice with the same seed: `-2`, `-3`... is appended (R9). A failed save is reported in `RoundsResult.saveError` and `describe` (R14).

### Added

- Models `Map` (get/put/delete, with `partition` by key), `Stack` (push/pop, optional capacity) and `Semaphore` (tryAcquire/release), with JSON hooks, tests and examples (P2).
- Default operation generators for the shipped models: `genRegisterOp`, `genEventOp`, `genQueueOp`, `genMapOp`, `genStackOp`, `genSemaphoreOp`, and tunable `randomRegisterOp`, `randomQueueOp`, `randomMapOp` (P3).
- Async usage guide, `docs/ASYNC.md`, and `examples/async_counter.nim` (P1).

- `tests/measure/rounds_cost.nim`: cost of a round and recorder overhead (R6, R7), results in `docs/MEASUREMENTS.md`.

- `RoundsConfig.partitioned` (check and shrink with `checkPartitioned`), `RoundsConfig.timeout` (per check) and `RoundsConfig.shrinkTimeout` (R3, R4, R12).
- `runRounds` accepts `init` as `proc (round: int): S` (R5) and a `setup` with a second `RoundInfo` argument carrying the round and a per-round seed for the scheduler (R10).
- `shrink` takes a `timeout` for the whole call (R12).
- `roundSeed(seed, round)`.

### Changed

- **Breaking** (models): a `step` or `outcomes` with side effects (reads or writes a global, does I/O) no longer compiles; the checker calls them through a `func` (R8). `-d:nimlinearImpureModel` turns the check off.
- `Recorder` buffers are padded to separate cache lines: recording overhead down by about a third (R7).
- Docs: the `order` of `checkPartitioned` is the concatenation of the parts' orders, not a global order; ticks appear once per part (R13).

- **Breaking** (operations generated per seed): the per-round generator seed is now `roundSeed(seed, round)` (a 64-bit mix) instead of `seed * 1_000_003 + round + 1`, which overflowed for large seeds and collided (R15). The same seed generates different operations than in 0.1.0; histories saved by 0.1.0 still load and replay.

### Notes

- The intermittent SIGSEGV on Windows listed as a known issue in 0.1.0 (R2) was seen once in CI and has not been reproduced since (88 repeated runs on Windows). Closed; notes for a recurrence are in the Roadmap.

## 0.1.0

First release. Everything below is new in 0.1.0; no earlier version was published, so no change is marked breaking.

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
- One runner for `nimble test`/`examples`/`bench` and CI (`tools/run.nims`); CI on Linux, macOS, Windows × Nim 2.2.4, 2.4.0 × orc/arc × threads on/off × debug/release, plus Nim 2.2.0 on Linux; no release workflow.
