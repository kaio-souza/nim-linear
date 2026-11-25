# Async code

How to record and check code that runs under async (`std/asyncdispatch`, Chronos). Example: [`examples/async_counter.nim`](../examples/async_counter.nim).

Nothing here needs a new API. The `Recorder` (see [History](HISTORY.md#concurrent-recording-recorder)) already treats its index as a **logical** thread, not an OS thread.

## One index per task

The checker needs to know "who is sequential": which operations can never overlap because one caller issued them one after another. In async code that caller is a **task** (an async proc you `await`, or a future you started), not an OS thread.

- Give each concurrent task its own index in `0 ..< threads` and pass it as `thread` to `begin`/`finish`/`tick`.
- Each task is sequential: at most one open operation per index. A task that starts several operations without awaiting each one (for example `all(@[a(), b()])`) is several tasks; give each its own index.
- The recorder is only available with `--threads:on`. Compile with it even if everything runs on one OS thread.

```nim
proc task(c: AsyncCounter, rec: ptr Recorder[COp, CRes], index: int, ops: seq[COp]) {.async.} =
  for op in ops:
    let id = rec[].begin(index, op)                     # before the first step of the call
    let v = if op.inc: await c.increment() else: await c.read()
    rec[].finish(id, CRes(value: v))                    # after its last await
```

Use `begin`/`finish` explicitly, not `record`: they make the boundary visible next to the `await`.

## Operation boundaries

An operation is everything between the call and the moment its result is known, **including every `await` in between**. Another task can run at each `await`, so that is where interleavings happen.

- **`begin`** right before the call (before its first `await`), **`finish`** right after the awaited result is available. Recording only the synchronous part hides the interleaving and the checker will see no overlap.
- **The result is what the caller received**, not something read later. In the example, the first version of the correct `increment` returned `c.value` after an `await`; the checker rejected it, because another task's increment had already happened. Take the result before suspending, or return what the operation itself computed.
- **Deferred effects:** if a call returns before its effect happens (fire-and-forget, a write that is flushed later), the recorded operation is not the effect. Model the real effect, or record the operation that observes completion (see [Limits](../README.md#limits), "asynchronous APIs whose effect is deferred").
- **Cancellation and timeouts:** a cancelled future, or one abandoned after a timeout, has no `finish`: it stays **pending** (the checker considers it applied and not applied). If the implementation guarantees a cancelled call has no effect, record a result that says so (for example, a `cancelled` result the model accepts with no state change) instead of leaving it pending.
- **Exceptions:** an exception from an awaited call skips `finish` and leaves the operation pending, as with threads. Catch it and record an error result if the specification defines one.

## Tasks that move between OS threads

Some runtimes resume a task on another OS thread (a thread pool, Chronos with threads, a custom executor). This is allowed:

- `finish` may run on another OS thread than `begin`. The index, not the OS thread, says who is sequential.
- What must never happen is **two calls on the same index at the same time** (two tasks sharing an index, or one task with two open operations). The recorder detects it with a per-index busy flag and `snapshot` then raises `ArgumentError` ("recorder misuse") instead of returning a corrupted history.
- The memory written by `begin` on one thread must be visible to `finish` on another. Executors that move tasks already synchronize the hand-off; the recorder adds its own release/acquire on the busy flag.

`std/asyncdispatch` runs one dispatcher per OS thread and does not move tasks, so with it every task stays on its thread. If you run several dispatchers on several threads against one shared object, give the tasks of all threads distinct indices (for example `thread * tasksPerThread + task`).

## Rounds

`runRounds` starts OS threads and calls `exec` synchronously, so it does not fit async code directly. Write the round loop yourself (the example does this in about 20 lines):

1. per round, a fresh object and `newRecorder(tasks)`;
2. operations drawn from a seeded `Rand` (the default generators of the shipped models work here too: `genMapOp(rng, task, index)`, see [Models](MODELS.md#default-operation-generators));
3. start one future per task, `waitFor all(futures)`;
4. `rec.snapshot()`, `checkLinearizable`, and on failure `shrink` and `report`.

With `std/asyncdispatch` on one thread, `sleepAsync(0)` and other ready callbacks run in a fixed order, so a round is usually reproducible from its seed. Timers with real delays and I/O are not; avoid them in the object under test, or replace them with a fake clock and record `tick` events (see [Models](MODELS.md#time)).

The controlled scheduler (`nimlinear/schedule`) and `perturb()` work on OS threads, not tasks. In async code the `await` points already are the switch points; to widen a race window, add an `await sleepAsync(0)` where `perturb()` would go.
