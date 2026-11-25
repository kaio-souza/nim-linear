# Design decisions

Each decision has context, choice, reason and consequence. Accepted decisions do not change without a new entry here. Once the project has more code, each decision may become an ADR in `docs/decisions/NNNN-title.md` (directory to be created).

Status: **Proposed** (not implemented) or **Accepted**.

---

## D-01: stdlib only

- **Status:** Accepted
- **Context:** the library is used in other projects' tests. Each of its dependencies becomes a test dependency for its users.
- **Choice:** no external dependency. It uses `std/atomics`, `std/locks`, `std/json`, `std/hashes`, `std/sets`, `std/tables`, `std/random`, `std/unittest` (and `std/monotimes` for diagnostics only).
- **Reason:** fewer versions to align in the user's project, and no risk of the test library breaking because of third parties.
- **Consequence:** scripts are plain Nim, run with `nim r`. No external property generator; the oracle is brute force with a fixed seed.

## D-02: checker separate from the explorer

- **Status:** Accepted
- **Context:** nim-lang/RFCs#222 asks for two things: model checking of state machines, and checking concurrent data structures by exploring interleavings.
- **Choice:** nimlinear does **only** the observed-history checker. Exhaustive exploration, if it ever exists, is another project that uses nimlinear as its oracle.
- **Reason:** exploration and checking have different costs and risks. Mixing them makes the library large and hard to test.
- **Consequence:** nimlinear only detects bugs present in the observed execution. This is stated in the [README](../README.md#limits).

## D-03: event order from an atomic counter

- **Status:** Accepted (implemented in M7)
- **Context:** clock timestamps can tie or be noisy across threads.
- **Choice:** each `invoke` and `return` gets its `seq` from a shared `Atomic[int]` (`fetchAdd`); the type `SeqNo` is a `distinct int` (D-19). The `invoke` takes its `seq` before the call; the `return` takes it after.
- **Reason:** the counter gives a total order without depending on the clock. Taking the `seq` outside the call preserves real-time order.
- **Consequence:** any recording with the `seq` taken inside the call produces a wrong check without warning. This is the most likely mistake when using the library and is the first item in the [recording guide](HISTORY.md#event-order).

## D-04: model state with `hash` and `==`, memoization by `(linearized, state)`

- **Status:** Accepted (implemented in M2)
- **Context:** the search must recognize states it already visited.
- **Choice:** the model requires `hash` and `==` on the state. Memoization uses the pair `(linearized set, state)`; `hash` only picks the bucket, and `==` decides whether the configuration is the same.
- **Reason:** the contract is explicit and does not depend on serialization or on `$`. Serializing the state would be slower and more fragile.
- **Consequence:** a state field that is not covered by `hash` or `==` makes the checker give a wrong result. That is why the [models guide](MODELS.md#contract) says to cover every field, including constants.

## D-05: saved format in JSON Lines, stable

- **Status:** Accepted (implemented in M1)
- **Context:** concurrent test failures must be reproducible later, without rerunning.
- **Choice:** JSON Lines, one event per line, fixed fields (`kind`, `op`, `thread`, `seq`, `payload`), `LF`.
- **Reason:** readable, diffable, no extra library.
- **Consequence:** changing the format is a major version change, with an entry in `CHANGELOG.md`. The fixtures in `tests/golden/` lock the format.

## D-06: `vkInconclusive` is never success nor failure

- **Status:** Accepted (implemented in M4; `runRounds` treats it as a failure of the test)
- **Context:** the search has a budget. When it runs out, the checker does not know the answer.
- **Choice:** a verdict of its own, with the number of explored states and the budget.
- **Reason:** treating it as success hides bugs; treating it as failure raises false alarms. The library does not decide; the [usage guide](GUIDE.md#step-3-small-rounds-with-runrounds) recommends failing in regression tests, to force the history to be shrunk.
- **Consequence:** raising the budget without measuring is discouraged in regression tests (see [API](API.md#budget)).

## D-07: exhaustive exploration out of scope

- **Status:** Accepted
- **Context:** exploring every interleaving is model checking, with a cost exponential in the number of threads and operations.
- **Choice:** out of the library. It may exist later as a producer of histories that nimlinear checks.
- **Reason:** nimlinear needs to be useful on real code, where the scheduler cannot be controlled.
- **Consequence:** bugs that depend on a specific, rare order only show up if that order happens during the execution. Tests compensate with the number of rounds, not with a coverage promise. Generating interleavings by sampling, in an optional module, is allowed (D-18).

## D-08: pending operations are modeled, not errors

- **Status:** Accepted
- **Context:** threads can die or the test can time out before the `return`.
- **Choice:** the checker considers both possibilities (applied or not) for each pending operation.
- **Reason:** treating them as errors prevents checking real histories that contain partial failures.
- **Consequence:** pending operations enlarge the search. Regression tests should avoid them.

## D-09: time fixed for the round as the default path

- **Status:** Accepted (guidance; `tick` in M10 is the alternative)
- **Context:** objects with timeouts or TTLs depend on the clock. The checker does not see a clock advance that is not in the history.
- **Choice:** the recommended path is to advance a fake clock before the round's threads and keep it fixed during the round; the effect of time becomes a field of the model's initial state. Time as an event (`tick`) is the alternative, implemented in M10 (D-22).
- **Reason:** it is the simplest path that covers most races in time-dependent objects.
- **Consequence:** it does not cover time transitions that happen in the middle of concurrent operations; tests that need them use `tick` (D-22).

## D-10: no integration with property-based testing libraries

- **Status:** Accepted
- **Context:** projects may already use external property generators.
- **Choice:** nimlinear depends on none of them. The internal random history generator (oracle, M6) uses `std/random` with a fixed seed.
- **Reason:** keeps the library dependency-free (D-01).
- **Consequence:** anyone who wants to generate operations with another library does so in their own test and hands the recorded history to nimlinear.

## D-11: memoize failures, not only successes (graph, not tree)

- **Status:** Accepted (implemented in M2)
- **Context:** Lowe (2017, section 3.1) shows that Wing & Gong's tree search redoes the work of commuting orders that reach the same (linearized set, state) pair. Lowe's optimization (WGL) stores configurations already seen to be **non-linearizable** and skips those branches (Horn & Kroening, Algorithm 1).
- **Choice:** the search runs over a graph. The set of visited configurations keeps every one that already failed, as well as successful ones. The table uses the model's `hash` to index and `==` to confirm (D-04); never `hash` alone, because a collision would give a false verdict.
- **Reason:** commuting operations (reads, different keys) produce the same state along different paths; without failure memoization the cost grows exponentially with them.
- **Consequence:** memory grows with the number of configurations. That is why the budget (D-06) counts visited states, and memory is measured in the tests (M4).

## D-12: partitioning only when the specification is P-compositional

- **Status:** Accepted (implemented in M11)
- **Context:** Horn & Kroening (arXiv 1504.00204, Definition 6 and Theorem 1) show that a history can be split into independent sub-histories when the specification is P-compositional. With partitioning by key, WGL+P was about an order of magnitude faster and used an order of magnitude less memory than plain WGL. Porcupine exposes this as `Partition`.
- **Choice:** the API provides an optional `partition` in the model, with the obligation to document the validity condition. The library does not check the condition; whoever writes the model is responsible for it.
- **Reason:** it is the largest measured source of speedup in the literature. The contract has to be written down to avoid false verdicts.
- **Consequence:** it suits maps and other objects with independent keys. It does not suit objects with a single global state (a shared state machine, a queue): there, the gain must come from smaller rounds.

## D-13: serial oracle of the code itself as a check on the model

- **Status:** Proposed (optional)
- **Context:** Line-Up (PLDI 2010) does away with a hand-written specification for deterministic components: it runs the same operations in serial order on the code itself and compares with the concurrent orders. It is sound only for the inputs tested.
- **Choice:** besides step 5 of the [models guide](MODELS.md#writing-a-model-step-by-step), the test may use the serial execution of the object itself as a model (with a fake clock, if any). That makes the difference between the written model and the code explicit.
- **Reason:** it detects divergence between specification and code without relying on the model being right.
- **Consequence:** the serial oracle only sees errors that show up in sequence with the same input. Specification errors still depend on the written model. The two must be used together, never one instead of the other.

## D-14: verdict with diagnostics (operation, last prefix, alternatives)

- **Status:** Accepted (`Witness` filled by the checker since M2; `report` is M5)
- **Context:** Porcupine (`CheckResult` with `Unknown`, `Ok`, `Illegal`, and a visualization with "illegal linearization points") and Knossos (`:op`, `:previous-ok`, `:final-paths`) show that the failure report is what makes the error debuggable.
- **Choice:** `vkNotLinearizable` carries the `Witness` described in the [API](API.md#verdict), with the list of alternatives tried at the failure point and the reason for each refusal (for example, "queue full: 4 of 4"). The output is stable text for snapshots.
- **Reason:** without the refused alternatives, the developer only sees that the history failed, not why.
- **Consequence:** `step` returns `Expected` with the refusal reason (`why`) besides the result.

## D-15: pending operations, our choice and Horn & Kroening's

- **Status:** Accepted (complements D-08)
- **Context:** Horn & Kroening (Definition 5) handle pending operations by completing them with returns, and restrict the analysis to complete histories, justifying it by assuming the absence of deadlock. Porcupine and Knossos follow the same line.
- **Choice:** we keep D-08, which considers both possibilities (applied or not). Completing with returns is a special case of it.
- **Reason:** in concurrency tests, the absence of deadlock is precisely one of the things being tested, so we cannot assume it.
- **Consequence:** the cost is higher than Horn & Kroening's, so pending operations stay out of regression tests (see [History](HISTORY.md#pending-operations)).

## D-16: a core without exceptions requires a `step` without exceptions

- **Status:** Accepted
- **Context:** the README promises that the core does not raise, and `checkLinearizable` is `{.raises: [].}`. A `step` that raises would break both.
- **Choice:** the model contract requires `step` to be a `func` with `{.raises: [].}`. An invalid operation becomes an error result in `Res`, not an exception.
- **Reason:** the compiler guarantees the promise, instead of relying on catching at run time.
- **Consequence:** a model that calls code that can raise does not compile; whoever writes the model handles the error inside `step`.

## D-17: model as a type, initial state as a parameter

- **Status:** Accepted
- **Context:** the initial state could live in the model (`init()`) or be passed to the checker.
- **Choice:** the model is a `typedesc` with `step(M, S, Op)`; the initial state is just the `init` parameter of `checkLinearizable`.
- **Reason:** the initial state depends on the test setup (capacity, state prepared before the round); an `init()` with no arguments would have no way to receive it.
- **Consequence:** configuration constants live inside the state and go into `hash` and `==` (see D-04).

## D-18: sampled interleavings in optional modules; exhaustive exploration stays out

- **Status:** Accepted (implemented in M12 and M13)
- **Context:** D-07 leaves exhaustive exploration out, and the checker only sees the order the OS picked. Bugs with a narrow window (between reading and changing shared state) show up rarely, even with many rounds.
- **Choice:** two optional modules, separate from the core, that only **generate** more varied executions; the result of each one still goes to `checkLinearizable` unchanged:
  1. **Perturbation** (`nimlinear/perturb`, M12): `perturb()` points the user places inside the object under test. In test mode, each point draws, with a fixed seed, between doing nothing, `cpuRelax` or `sleep(0)`. Outside test mode (without `-d:nimlinearPerturb`), `perturb()` is an empty template, with no cost.
  2. **Controlled scheduler** (`nimlinear/schedule`, M13, optional): only one thread advances at a time; at each `perturb()`, a seeded PCT (Probabilistic Concurrency Testing) scheduler decides who continues. The same seed reproduces the same interleaving.
- **Reason:** sampling greatly increases the chance of hitting narrow windows at low cost and without changing the checker. Exhaustive exploration (DPOR, every path) remains a different project (D-02, D-07).
- **Consequence:** the core does not depend on these modules; whoever does not import them pays nothing. Perturbation does not give exact reproduction (the OS still decides); only M13 does. Neither promises coverage: they are ways to find bugs sooner, not to prove their absence. The `perturb()` points are generic: they work for any object, not for a specific type.

## D-19: sequence number as `SeqNo`, field `seqNo`

- **Status:** Accepted
- **Context:** the draft used the type `Seq` and the field `seq`. In Nim, `seq` is also the language's sequence type; `Seq` and `seq` differ only in the first letter, and `h.events[i].seq` next to `seq[Event]` hurts readability and error messages.
- **Choice:** type `SeqNo`, field `seqNo`. In the documentation prose and in the JSON key the name stays `seq`.
- **Reason:** removes the ambiguity in code without changing the saved format (D-05).
- **Consequence:** JSON uses `"seq"` and Nim uses `seqNo`; `toJsonLines`/`parseJsonLines` translate between them.

## D-20: deterministic verdict

- **Status:** Accepted
- **Context:** there may be several valid linearizations, and several longest prefixes on a failure. The README promises determinism.
- **Choice:** the search tries candidates in increasing `seq` of the `invoke`; `order`, `prefix` and `alternatives` follow that order (rules in [API](API.md#verdict)). In `checkPartitioned`, partitions are processed in increasing key order.
- **Reason:** the same history must produce the same verdict and the same `report` on every platform (snapshots in `tests/golden/`).
- **Consequence:** the exploration order is fixed; future ordering heuristics can only be added if they preserve the returned result.

## D-21: releasing separate from finishing milestones

- **Status:** Accepted
- **Context:** development uses AI agents, and small milestones are ready in hours. Organizing deliveries by version (one milestone per version) would lead to several releases on the same day.
- **Choice:** milestones are units of work on `master`. Releases bundle useful sets of changes, after 7 days without API or format changes, with at least 7 days between them. The exception is a fix for a wrong verdict. Rules in [CONTRIBUTING](../CONTRIBUTING.md#releasing).
- **Reason:** users should not have to follow versions that change nothing for them. The stabilization period balances the speed of writing with time in real use.
- **Consequence:** the roadmap does not reserve version numbers. `CHANGELOG.md` accumulates `## Unreleased` until the next release.

## D-22: a tick is its own event kind

- **Status:** Accepted (implemented in M10)
- **Context:** a clock advance could be recorded as an ordinary operation (an `invoke`/`return` pair with consecutive `seq`), with no format change. But then the test must supply a result for the tick, the tick occupies its thread like any operation, and nothing says it is instantaneous.
- **Choice:** a third event kind, `ekTick` (`"tick"` in JSON): one event, one `seq`, no `return`, result not compared, does not open its thread. Internally the checker places it in the interval `[2*seq, 2*seq + 1]` so it is ordered strictly against every other event. `checkPartitioned` copies ticks into every part.
- **Reason:** says what a tick is in the format itself; removes the meaningless result and the thread constraint.
- **Consequence:** the JSON format gained a value for `kind`. That is a format change (D-05); it lands before the first release, so no published file is affected. Readers that only know `"invoke"`/`"return"` reject files with ticks.

## D-23: nondeterministic specifications through `outcomes`, format version line

- **Status:** Accepted (implemented in M14 and M15)
- **Context:** `step` returns one expected result, so specifications with several allowed results (bag `take`, weak CAS, early timeout) could not be modeled. Porcupine and Knossos instead give the model the observed result. Separately, the saved format had no version, and M10 already changed it.
- **Choice:** an optional `outcomes(m, s, op): seq[Expected[S, Res]]` that lists every allowed `(next, res)`; the checker branches over those matching the observation (or all of them, for a pending operation). This was preferred over an "accepts the observed result" contract because a pending operation has no observed result: with `outcomes` the checker can still branch over its possible effects. The JSON Lines format gains a first line `{"nimlinear":1}`; files without it still parse.
- **Reason:** covers the nondeterministic cases without changing `step` models; makes format changes detectable before the first release.
- **Consequence:** each outcome is a branch, so long outcome lists make the search more expensive. Choices from an infinite set cannot be listed and must be restricted by the test.

## D-24: shrinking keeps the stuck operation and its expected result

- **Status:** Accepted (implemented in M16)
- **Context:** removing operations from a failing history can create a failure that was not there (remove the only `write(1)` and a `read() -> 1` becomes unexplainable), and the shrunk history would then point at the wrong bug. Lincheck avoids this by re-running the real code on the smaller scenario; nimlinear only has the history.
- **Choice:** greedy removal (threads, then operations) that keeps a candidate only if it is still `vkNotLinearizable`, stuck on the same operation, with the same expected result for it; the stuck operation is never removed.
- **Reason:** cheap, deterministic, and rejects the common artificial failures.
- **Consequence:** it is a heuristic: the shrunk history can still omit context that helps understand the bug. Reports should keep pointing at the original history (`runRounds` keeps both).

## D-25: search key `(f, window)` instead of the full bitset

- **Status:** Accepted (implemented in M22)
- **Context:** storing the full linearized bitset per visited configuration, recomputing `minRet` by a full scan and restarting the candidate scan from 0 made the search quadratic on long histories with bounded overlap (measured: 20 000 operations in 1.26 s, 4x the time of 10 000).
- **Choice:** the memo key is `(f, window, state)`: every operation below index `f` is linearized, `f` is not, and `window` is a bitset of the operations after `f`. `minRet` is kept incrementally over operations sorted by return, and the candidate scan starts at `f`.
- **Reason:** with bounded overlap the window is one or two words, so each step costs O(overlap).
- **Consequence:** linear on long histories (40 000 operations in about 20 ms). A pending operation that is never linearized keeps `f` from advancing, so many pending operations in a long history grow the window: cost about quadratic in their number (benchmark shape E). Fully overlapping histories (shapes A, B) stay exponential, as for every checker of this kind.

## D-26: switch points on atomics and locks through a drop-in module (P6)

- **Status:** Accepted (implemented: `nimlinear/intercept`; validated on the circuit breaker, see [Measurements](MEASUREMENTS.md#intercepted-atomics-and-locks-p6))
- **Context:** real use (a circuit breaker with lock-free fast paths on `Atomic` fields) showed that `perturb()` points must be written inside the library under test, at every racy window, to reach narrow interleavings. Without them, the breaker's test relies on 20 000 rounds under the OS scheduler. The roadmap made this wait for P4; real use is the stronger signal.
- **Options considered:**
  1. `patchFile` in a `.nims` to replace `std/atomics` and `std/locks` in the test build. Transparent, but it also replaces them for the standard library and for nimlinear itself (the Recorder's counter and the scheduler would switch inside themselves), and it depends on the internal layout of those modules across Nim versions.
  2. A drop-in module with the same names, imported by the code under test only in test builds.
  3. Keep manual `perturb()` only.
- **Choice:** option 2. A module `nimlinear/intercept` re-exports `std/atomics` and `std/locks`. With `-d:nimlinearPerturb`, it adds a `perturb()` before every atomic **write or read-modify-write** (`store`, `exchange`, `compareExchange`, `compareExchangeWeak`, `fetchAdd`, `fetchSub`, `fetchAnd`, `fetchOr`, `fetchXor`, `+=`, `-=`) and makes `Lock` behave as `SchedLock` under an active scheduler (`initLock`, `acquire`, `release`, `withLock` keep their names). Loads get no point: the window between a load and the write that depends on it is already opened by the point before the write, and fewer points keep PCT's depth effective. `Cond` is not intercepted (documented). The code under test switches its imports in one place:
  ```nim
  when defined(nimlinearIntercept): import nimlinear/intercept
  else: import std/[atomics, locks]
  ```
  `-d:nimlinearIntercept` is the user's own define, so the production build never imports nimlinear (D-01 for the user's users).
- **Reason:** keeps the D-18 shape (an optional module that only generates more varied executions; the checker is unchanged), costs nothing without the define, and does not touch the standard library or nimlinear's own synchronization. Determinism under the scheduler (D-20 for executions, M13) is preserved because every new point is a `perturb()`.
- **Consequence:** one import change in the library under test. More switch points per round: `steps` of `initScheduler` must be raised accordingly (documented with measurements). Still sequential consistency only: relaxed orderings stay invisible (README, Limits). Validated on the circuit breaker before release. P6 no longer waits for P4.

## D-27: shrink with replay only for deterministic rounds (P4)

- **Status:** Accepted (implemented: `runScenario`, `RoundsConfig.replayShrink`)
- **Context:** D-24 shrinks the history alone and can keep a failure that the real code would not produce, or drop context it needs. Lincheck re-runs the real code on each smaller scenario. Re-running is only meaningful if the same scenario gives the same execution; under the OS scheduler it does not (D-18: only the controlled scheduler reproduces).
- **Choice:**
  1. **Scenario as data.** The operations of a round are already drawn on the main thread; a new entry point runs a round from explicit per-thread operation lists (`runScenario`), and `runRound` is defined through it. Removing an operation never changes the others.
  2. **Determinism is checked, not assumed.** Before replay-shrinking, the failing scenario is run twice with the same round seed; if the two recorded histories differ (byte for byte in JSON), replay is skipped and the result says why. No probabilistic "N attempts" mode: a verdict that depends on luck contradicts D-20.
  3. **What counts as reproduced:** the replayed history is `vkNotLinearizable` and its stuck operation has the same thread, call and expected result as the original's (the D-24 signature, compared by content because `OpId`s shift when operations are removed).
  4. **Order and limits:** first the history-only shrink (D-24) to find candidate removals, then greedy replay of whole threads and single operations, bounded by `shrinkTimeout`. Opt-in through `RoundsConfig(replayShrink: true)`; the history-only shrink stays the default.
- **Reason:** keeps verdicts deterministic, reuses the D-24 signature, and gives the user a scenario the real code fails on, not only a smaller history.
- **Consequence:** useful only with the scheduler (or code that is deterministic by itself). Removing operations changes the schedule (PCT change points are counted in steps), so a removal can be rejected because the bug moved, not because it needs the operation: the result is a reproducible scenario, not a minimal one. Each replay is a full round: cost grows with the number of candidates. Measured on `tests/trounds.nim` (racy counter, 3 × 12 operations, PCT depth 3): 36 operations reduced to 23 by replay, where the history-only shrink reaches a smaller history; the gain is reproducibility, not size.

## D-28: unbounded results stay out of the model contract (P5)

- **Status:** Accepted
- **Context:** some operations return a value from an open set (any free id, any timestamp). `step` gives one result and `outcomes` (D-23) lists finitely many. A contract that receives the observed result ("accept this result and give the next state") was already rejected in D-23, because a pending operation has no observed result: its effect could not be explored, and treating it as "not applied" only can report a violation that did not happen (another operation may have observed its id).
- **Choice:** no new hook. Results from an open set are modeled by making the set finite in the state, which keeps pending operations sound: the state holds the candidate values (for example, a small pool of ids configured by the test), and `outcomes` lists one branch per candidate that is still free. The pattern is documented in [Models](MODELS.md#results-from-an-open-set) with an example.
- **Reason:** the checker stays sound for pending operations, the verdict stays deterministic (D-20) and the API stays as it is (no **breaking** change). Every case seen so far fits a finite pool; one that cannot would need a new entry here.
- **Consequence:** the test must restrict the generator to the pool (as the shipped generators already do with keys). The cost grows with the pool size, since each free candidate is a branch; keep pools small (3 to 8 values).

## D-29: scheduler built into the round harness, with calibrated `steps`

- **Status:** Accepted (implemented)
- **Context:** PCT draws its `depth - 1` priority change points among `steps` switch points. The user had to guess `steps`. On the circuit breaker (P6 validation) the guess was 200 while a round had a median of 11 switch points (6 to 21): almost every change point fell after the round ended, and an injected bug was found 4 times in 2 000 rounds instead of 150 (depth 3) with `steps = 12`. The same scheduler wiring (a global `Scheduler`, `initScheduler` in `setup`, `deinitScheduler` in `teardown`, `enter`/`leave` hooks) was repeated in five places.
- **Choice:**
  1. `Scheduler.stepsTaken` reports the switch points of a round.
  2. `RoundsConfig(schedule: true, depth, steps)` makes `runRounds`, `runRound` and `runScenario` install the scheduler themselves (seeded with the round's `RoundInfo.seed`), after `setup` and removed before `teardown`. User `ThreadHooks` are refused with `schedule` (one scheduler at a time).
  3. `steps = 0` (the default) **calibrates**: round 1's operations run once with change points out of reach, and the switch points counted become `steps` for every round. The value is returned in `RoundsResult.steps`; `runScenario` with the same `steps` replays a round exactly.
  4. The manual wiring stays supported.
- **Reason:** removes a parameter users cannot know and that silently weakens PCT, and the boilerplate around it. Calibrating once, on round 1, keeps `(seed, round)` (plus the config) the identity of a round (D-20, R15): no round depends on earlier ones.
- **Consequence:** one extra round of cost per `runRounds` call. Rounds whose switch-point count varies a lot are calibrated on one sample (round 1); a fixed `steps` remains available. Replay shrink (D-27) was measured again with calibrated steps: no change (about 18 to 20 of 36 operations kept, as with a fixed `steps`), because removing operations moves the switch points whatever `steps` is; replay is left as it is.
