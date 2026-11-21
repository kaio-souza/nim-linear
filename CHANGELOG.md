# Changelog

Format: each finished milestone adds entries under `## Unreleased`. Changes to the public API or to the JSON format are marked as **breaking**. See [Release policy](README.md#release-policy).

## Unreleased

- M0: project layout (`nimlinear.nimble`, `src/`, `tests/`), `nimble test` task and minimal test `tests/tsmoke.nim`.
- M1: types `OpId`, `ThreadId`, `SeqNo`, `Event`, `History`; `newHistory` validates the invariants and sorts by `seq`; `toJsonLines`/`parseJsonLines` with `toPayload`/`fromPayload` hooks; byte-for-byte round trip tested. Additions not in the API draft: `ArgumentError` (defined by the library, `object of CatchableError`), `invokeEvent`/`returnEvent` and `==` for `Event`.
- M2: `checkLinearizable` as a graph search memoizing `(linearized, state)` (D-11), candidates in `invoke` `seq` order (D-20), `Witness` with prefix, stuck operation and alternatives; `Expected` type; `Register` model in `nimlinear/models/register` (with JSON hooks). Negative compilation test for a `step` that raises. Pending operations and the budget are already implemented in the same loop; the acceptance criteria of M3 (`EventFlag` fixture) and M4 (memory measurement) are still open.
- M3: `EventFlag` model in `nimlinear/models/eventflag` (with JSON hooks); lost-wakeup fixture `tests/fixtures/eventflag_lost_wakeup.jsonl` rejected by the checker; tests for both possibilities of pending operations (D-08).
- Documentation translated to English; files in `docs/` renamed (`API.md`, `DECISIONS.md`, `GUIDE.md`, `HISTORY.md`, `MODELS.md`).
