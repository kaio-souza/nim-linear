# Usage guide

> Describes the planned workflow. The recorder, `report` and the `BoundedQueue` model used below are not implemented yet; see the status at the top of the [README](../README.md).

How to adopt nimlinear in any project. Each step has an acceptance criterion. The example uses a bounded queue (`BoundedQueue`, see [Models](MODELS.md#boundedqueue)), but the steps apply to any object.

## Expected outcome

A new test in your project (for example, `tests/t_linearizable.nim`) that:

1. runs a few threads with a few operations, many times (rounds);
2. records the history of each round;
3. checks each history against the sequential model;
4. fails, saving the history, when a result has no sequential explanation.

This test does not replace the stress and invariant tests you may already have: it covers a different gap (results no order explains).

## Step 1: test dependency

In your project's `.nimble`, as a test-only dependency:

```nim
taskRequires "test", "nimlinear >= 0.1.0"
```

Acceptance: `nimble test` resolves the dependency; the published package (`requires`) gains nothing new.

## Step 2: model

Write the model following [Models](MODELS.md#writing-a-model-step-by-step):

1. hand-written cases for each operation, including edges (empty, full, closed);
2. comparison against the real object in sequence, without threads;
3. only then the concurrent test.

If the sequential comparison fails, the bug is in the model or in the code. Investigate before moving on.

## Step 3: small rounds

Do not record a long stress run: thousands of operations are far beyond what the checker handles. Use many small rounds.

| Parameter | Initial value | Reason |
|---|---|---|
| threads | 2 to 3 | enough for most races |
| operations per thread | 3 to 5 | keeps the history at ~10–15 operations |
| rounds | 1 000 to 5 000 | makes up for the lack of exhaustive exploration (D-07) |
| budget | see [Budget](API.md#budget) | |

Each round starts with a fresh object in a known initial state. If the bug you care about only shows up from a specific state (queue almost full, expired timeout), prepare that state **before** the threads, without recording, and pass the matching state as `init`. Vary the initial states across rounds, with a fixed seed.

```nim
# compile with --threads:on
import std/[random, sequtils, options, unittest]
import nimlinear
import myqueue              # real BoundedQueue: tryEnqueue(v): bool; tryDequeue(): Option[int]
import models/queue         # QueueOp, QueueRes, QueueState, QueueModel (see MODELS.md)

const Threads = 3
const OpsPerThread = 4

type Ctx = object
  rec: ptr Recorder[QueueOp, QueueRes]
  q: ptr BoundedQueue[int]
  tid: int
  seed: int64

proc worker(c: Ctx) {.thread.} =
  var rng = initRand(c.seed)
  for i in 0 ..< OpsPerThread:
    if rng.rand(1) == 0:
      let v = c.tid * 100 + i                     # distinct values per thread
      let id = c.rec[].begin(c.tid, QueueOp(kind: qEnqueue, value: v))  # invoke BEFORE
      let ok = c.q[].tryEnqueue(v)
      c.rec[].finish(id, QueueRes(kind: if ok: qrOk else: qrFull))      # return AFTER
    else:
      let id = c.rec[].begin(c.tid, QueueOp(kind: qDequeue))
      let got = c.q[].tryDequeue()
      c.rec[].finish(id, if got.isSome: QueueRes(kind: qrValue, value: got.get)
                         else: QueueRes(kind: qrEmpty))

suite "linearizable queue":
  test "small rounds":
    var rng = initRand(42)                        # fixed seed: reproducible failures
    for round in 0 ..< 2000:
      var q = newBoundedQueue[int](capacity = 4)
      let prefill = rng.rand(0..4)                # varied initial state, not recorded
      for i in 0 ..< prefill: discard q.tryEnqueue(1000 + i)
      let init = QueueState(items: toSeq(1000 ..< 1000 + prefill), capacity: 4)

      var rec = newRecorder[QueueOp, QueueRes](threads = Threads)
      var ths: array[Threads, Thread[Ctx]]
      for t in 0 ..< Threads:
        createThread(ths[t], worker, Ctx(rec: addr rec, q: addr q, tid: t,
                                         seed: rng.next().int64))
      joinThreads(ths)                            # snapshot only after the join

      let h = rec.snapshot()
      let v = checkLinearizable(h, init, QueueModel, budget = 500_000)
      if v.kind != vkLinearizable:
        writeFile("tests/fixtures/failure-" & $round & ".jsonl", h.toJsonLines())
        echo v.report
      check v.kind == vkLinearizable              # vkInconclusive also fails (D-06)
```

Rules:

- `vkInconclusive` **fails** the test. If it shows up, shrink the round before raising the budget.
- On failure, save the history (see [History](HISTORY.md#saving-a-failed-history)).

### Shortcut: `runRounds`

Steps 3 and 5 can be written with the round harness (M17): give it `setup`, an operation generator and an executor, and it runs the rounds, checks each one, shrinks and saves the first failing history, and `describe` prints it with a timeline. See [API](API.md#round-harness-m17) and [`examples/queue_race.nim`](../examples/queue_race.nim).

## Step 4: time

If the object depends on a clock, inject a fake clock and follow [Time](MODELS.md#time): advance it before the threads, never inside them.

## Step 5: validate the test with an injected bug

Inject a known bug on purpose (for example, remove the capacity check, or replace an atomic operation with a separate read and write) and confirm the test fails. If it does not, the test is worthless: increase the rounds, change the initial state or review the model.

A complete example of this step is [`examples/queue_race.nim`](../examples/queue_race.nim): it runs the same test against a correct queue and against one with a check-then-act bug in `dequeue`, and fails unless the first passes and the second is rejected.

## Step 5b (optional): perturbation

If the bug you care about has a narrow window (between reading and changing shared state), put `perturb()` at those points in the object under test and compile the test with `-d:nimlinearPerturb` (M12, D-18). Without the flag, `perturb()` generates no code. Confirm step 5 again: the injected bug should fail in fewer rounds. Example: [`examples/queue_perturb.nim`](../examples/queue_perturb.nim).

To reproduce a failing interleaving exactly, register the threads in a `Scheduler` from `nimlinear/schedule` (M13): with the same seed, the round produces the same history. Do not put `perturb()` inside a critical section when using it (see [API](API.md#nimlinearschedule-m13)). Example: [`examples/queue_pct.nim`](../examples/queue_pct.nim).

## Step 6: CI

- Run the test only with `--threads:on`; with `off`, use `skip()`.
- Keep the test time under a few minutes per matrix combination; tune the number of rounds.
- Saved failing histories become fixtures in `tests/fixtures/`, with the expected verdict in `tests/golden/`.

## Checklist

- [ ] The model passed the hand-written cases and the sequential comparison.
- [ ] `invoke` recorded before and `return` after each call (see [History](HISTORY.md#event-order)).
- [ ] Compound operations recorded as a single one.
- [ ] Fixed seed; failures saved as JSON Lines.
- [ ] The injected bug is detected.
