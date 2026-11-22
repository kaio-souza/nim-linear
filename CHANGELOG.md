# Changelog

Format: each finished milestone adds entries under `## Unreleased`. Changes to the public API or to the JSON format are marked as **breaking**. See [Release policy](README.md#release-policy).

## Unreleased

- M0: project layout (`nimlinear.nimble`, `src/`, `tests/`), `nimble test` task and minimal test `tests/tsmoke.nim`.
- M1: types `OpId`, `ThreadId`, `SeqNo`, `Event`, `History`; `newHistory` validates the invariants and sorts by `seq`; `toJsonLines`/`parseJsonLines` with `toPayload`/`fromPayload` hooks; byte-for-byte round trip tested. Additions not in the API draft: `ArgumentError` (defined by the library, `object of CatchableError`), `invokeEvent`/`returnEvent` and `==` for `Event`.
- M2: `checkLinearizable` as a graph search memoizing `(linearized, state)` (D-11), candidates in `invoke` `seq` order (D-20), `Witness` with prefix, stuck operation and alternatives; `Expected` type; `Register` model in `nimlinear/models/register` (with JSON hooks). Negative compilation test for a `step` that raises. Pending operations and the budget are already implemented in the same loop; the acceptance criteria of M3 (`EventFlag` fixture) and M4 (memory measurement) are still open.
- M3: `EventFlag` model in `nimlinear/models/eventflag` (with JSON hooks); lost-wakeup fixture `tests/fixtures/eventflag_lost_wakeup.jsonl` rejected by the checker; tests for both possibilities of pending operations (D-08).
- M4: `checkLinearizable` already enforced budget/`vkInconclusive`; added optional `-d:nimlinearMeasure` sampling (`getOccupiedMem()` every 1024 visited configurations and at the end; prints peak minus start), the `tests/measure/measure.nim` harness and `docs/MEASUREMENTS.md` with preliminary local measurements.
- M5: `report` proc renders stable verdict text for `vkLinearizable`, `vkNotLinearizable`, and `vkInconclusive`; re-exported from `nimlinear`; golden snapshots in `tests/golden/` lock the format.
- M6: brute-force oracle and history generator in `tests/oracle/` (random scheduler over 1–3 threads, 1–8 ops, 10% pending, 50% with one swapped result); `tests/toracle.nim` checks agreement with `checkLinearizable` over 10,000 seeds for `Register` and for `BoundedQueue`.
- M7: concurrent `Recorder` (`nimlinear/recorder`, `--threads:on`) with a shared atomic `seq` counter, per-thread buffers, the thread encoded in the `OpId` (no locks while recording), and merge-by-seq `snapshot`; re-exported from `nimlinear` when threads are enabled. Tests cover multi-thread recording and misuse detection.
- M8 groundwork: `BoundedQueue` model in `nimlinear/models/boundedqueue` with tests; end-to-end example not yet added.
- Documentation translated to English; files in `docs/` renamed (`API.md`, `DECISIONS.md`, `GUIDE.md`, `HISTORY.md`, `MODELS.md`).
