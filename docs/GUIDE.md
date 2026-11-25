# Usage guide

How to adopt nimlinear in any project. Each step has an acceptance criterion. The example uses a bounded queue (`BoundedQueue`, see [Models](MODELS.md#boundedqueue)), but the steps apply to any object. A complete, compiled version of everything below is [`examples/queue_race.nim`](../examples/queue_race.nim) with [`examples/common/queue.nim`](../examples/common/queue.nim).

## Expected outcome

A new test in your project (for example, `tests/t_linearizable.nim`) that:

1. runs a few threads with a few operations, many times (rounds);
2. records the history of each round;
3. checks each history against the sequential model;
4. fails, saving a shrunk history, when a result has no sequential explanation.

This test does not replace the stress and invariant tests you may already have: it covers a different gap (results no order explains).

## Step 1: test dependency

In your project's `.nimble`, as a test-only dependency. nimlinear is not on the nimble index yet, so use the repository URL:

```nim
taskRequires "test", "https://github.com/kaio-souza/nim-linear"
```

Once it is on the nimble index: `taskRequires "test", "nimlinear >= 0.1.0"`.

Acceptance: `nimble test` resolves the dependency; the published package (`requires`) gains nothing new.

## Step 2: model

Write the model following [Models](MODELS.md#writing-a-model-step-by-step), or use a shipped one (`Register`, `EventFlag`, `BoundedQueue`, `CircuitBreaker`):

1. hand-written cases for each operation, including edges (empty, full, closed);
2. comparison against the real object in sequence, without threads;
3. only then the concurrent test.

If the sequential comparison fails, the bug is in the model or in the code. Investigate before moving on.

## Step 3: small rounds with `runRounds`

Do not record a long stress run. Use many small rounds; `runRounds` (`--threads:on`) runs them for you.

| Parameter (`RoundsConfig`) | Initial value | Reason |
|---|---|---|
| `threads` | 2 to 3 | enough for most races |
| `opsPerThread` | 3 to 5 | keeps the history at ~10–15 operations |
| `rounds` | 1 000 to 5 000 | makes up for the lack of exhaustive exploration (D-07) |
| `budget` | see [Budget](API.md#budget) | |
| `seed` | fixed | the same seed gives the same operations |

For a shipped model, the default generator replaces `genOp` (for example `genMapOp`, see [Models](MODELS.md#default-operation-generators)). For async code, see [Async](ASYNC.md).

You write four procedures: `setup` (fresh object per round, in a known state), `genOp` (one operation, from the round's seeded generator), `exec` (runs one operation on the real object and returns the result), and optionally `teardown`.

```nim
# compile with --threads:on
import std/[options, random, unittest]
import nimlinear
import nimlinear/models/boundedqueue
import myqueue        # your real queue: MyQueue, initMyQueue(capacity),
                      # tryEnqueue(v): bool, tryDequeue(): Option[int]

proc setup(q: var MyQueue) = q = initMyQueue(4)   # fresh queue, same capacity as the model

proc genOp(rng: var Rand, thread, index: int): QueueOp =
  if rng.rand(1) == 0: enqueue(thread * 1000 + index)   # distinct values
  else: dequeue()                                        # genOp never produces close()

proc exec(q: ptr MyQueue, op: QueueOp): QueueRes {.gcsafe.} =
  case op.kind
  of qEnqueue: (if q[].tryEnqueue(op.value): okRes() else: fullRes())
  of qDequeue:
    let got = q[].tryDequeue()
    if got.isSome: valueRes(got.get) else: emptyRes()
  of qClose: okRes()

suite "linearizable queue":
  test "small rounds":
    let r = runRounds(RoundsConfig(threads: 3, rounds: 2000, opsPerThread: 4,
                                   budget: 500_000, saveDir: "tests/fixtures"),
                      QueueState(capacity: 4), QueueModel, setup, genOp, exec)
    if not r.passed: echo r.describe   # shrunk report + timeline + saved file
    check r.passed                     # vkInconclusive also fails (D-06)
```

Rules:

- `vkInconclusive` **fails** the test. If it shows up, shrink the round before raising the budget.
- On failure, `runRounds` saves the shrunk history as `<saveDir>/<name>-seed<seed>-round<r>.jsonl`; `r.original` keeps the recorded one. To replay it, see [History](HISTORY.md#saving-a-failed-history).
- To start rounds from a specific state (queue almost full), prepare it in `setup` and pass the matching state as `init`. To vary it per round, pass `init` as `proc (round: int): S` and take `RoundInfo` in `setup` to build the same state.
- If `exec` raises, the round fails and `r.error` says which thread and operation.
- Leave `steps` at 0 with `schedule: true`: a guessed `steps` larger than the real switch points of a round silently weakens the scheduler.
- Under the scheduler, `replayShrink: true` also reduces the failing scenario by running the real code again, and `r.scenario` with `runScenario` replays it exactly ([API](API.md#round-harness-m17)).
- Without the harness, record by hand with `Recorder` (`begin`/`finish` or `record`): see [History](HISTORY.md#concurrent-recording-recorder).

## Step 4: time

If the object depends on a clock, inject a fake clock and follow [Time](MODELS.md#time): advance it before the threads, or record each advance as a `tick` (M10).

## Step 5: validate the test with an injected bug

Inject a known bug on purpose (for example, remove the capacity check, or replace an atomic operation with a separate read and write) and confirm the test fails. If it does not, the test is worthless: increase the rounds, change the initial state or review the model.

[`examples/queue_race.nim`](../examples/queue_race.nim) does exactly this: the same rounds against a correct queue and against one with a check-then-act bug in `dequeue`; it fails unless the first passes and the second is rejected.

## Step 5b (optional): perturbation and controlled scheduling

If the bug you care about has a narrow window (between reading and changing shared state), put `perturb()` at those points in the object under test and compile the test with `-d:nimlinearPerturb` (D-18). Without the flag, `perturb()` generates no code. Confirm step 5 again: the injected bug should fail in fewer rounds. Example: [`examples/queue_perturb.nim`](../examples/queue_perturb.nim).

To make rounds reproducible, run them under the PCT scheduler: `RoundsConfig(schedule: true, depth: 3)` does it for you and calibrates `steps` (D-29). To wire it yourself, create a `Scheduler` from `nimlinear/schedule` in a `setup` that takes a `RoundInfo` (`proc setup(q: var MyQueue, info: RoundInfo)`) with `initScheduler(threads, info.seed)`, so each round gets its own interleaving, remove it in `teardown`, and register the threads through `ThreadHooks`. With the same seed, a round produces the same history byte for byte. Replace the object's locks with `SchedLock`, so that `perturb()` can also go inside critical sections. To avoid editing the object at all, import `nimlinear/intercept` instead of `std/atomics`/`std/locks` in a test build: every atomic write and lock acquire becomes a switch point ([API](API.md#nimlinearintercept-p6)) (see [API](API.md#nimlinearschedule-m13)). Examples: [`examples/queue_pct.nim`](../examples/queue_pct.nim), [`tests/trounds.nim`](../tests/trounds.nim).

## Step 6: CI

- Run the test only with `--threads:on`; with `off`, use `skip()`.
- Keep the test time under a few minutes per matrix combination; tune the number of rounds.
- Saved failing histories become fixtures in `tests/fixtures/`, with the expected verdict in `tests/golden/`.

## Checklist

- [ ] The model passed the hand-written cases and the sequential comparison.
- [ ] `invoke` recorded before and `return` after each call (`runRounds` and `record` do this for you; see [History](HISTORY.md#event-order)).
- [ ] Compound operations recorded as a single one.
- [ ] Fixed seed; failures saved as JSON Lines.
- [ ] The injected bug is detected.
