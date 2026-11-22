# History

How to record, order, save and replay the history of a concurrent execution.

## What is recorded

For each call to the data structure, the test records two events:

- **`invoke`**: right before the call starts;
- **`return`**: right after the call hands back its result.

```
thread 1:  invoke(dequeue) ─────────────── return(some 7)
thread 2:        invoke(enqueue 7) ── return()
```

Every operation has an `invoke` and a `return`, including those that return no value (`enqueue`, `write`, `close`): their `return` carries an empty result. Without a `return`, the operation is treated as pending.

What matters is the order between events of different threads. Within one thread, the `invoke` and `return` of an operation always come in the right order.

## Event order

Each event gets a `seq` number from a **shared atomic counter** (`Atomic[int]`, `std/atomics`).

```nim
let s = SeqNo(counter.fetchAdd(1))   # unique and increasing
```

Rules:

1. **`seq` comes from the counter, not from the clock.** Two events on different threads can have the same clock instant; the counter breaks ties unambiguously.
2. **`invoke` takes its `seq` before the call; `return` takes it after.** This guarantees that, if operation A returned before B started, `A.return.seq < B.invoke.seq`. If the order is swapped, the check becomes wrong without any warning. This is the most important recording rule.
3. **`std/monotimes` timestamps are for diagnostics only.** They play no part in the check.

## Concurrent recording (recorder)

Implemented (M7). Options considered:

| Option | Advantage | Disadvantage | Decision |
|---|---|---|---|
| per-thread buffer, merged at the end under a `Lock` | little contention on the hot path | the merge must sort by `seq` | **chosen** |
| shared lock-free channel | order arrives ready | more code to validate | rejected for the core |

With the choice above, each thread writes only to its own buffer, and `seq` numbers come from one shared `Atomic[int]`. No lock is taken while recording: the recording thread is encoded in the `OpId` (`id = k * threads + thread + 1`), so `finish` finds the right buffer without a shared lookup. The merge in `snapshot` runs after all threads joined, so it needs no lock either. `--threads:on` is required for the recorder; the checker works without threads.

Typical use:

```nim
var rec = newRecorder[QueueOp, QueueRes](threads = 3)

# inside each thread, with the thread's id:
let id = rec.begin(thread = myId, call = QueueOp(kind: qDequeue))   # returns the OpId
let got = queue.tryDequeue()                                         # Option[int]
rec.finish(id, res = QueueRes(kind: qrValue, value: got))

let h = rec.snapshot()           # History sorted by seq; ArgumentError if the recorder was misused
let v = checkLinearizable(h, QueueState(capacity: 4), QueueModel, budget = 500_000)
```

Full signatures and rules in [API](API.md#recorder). `snapshot` goes through `newHistory`, so recorder misuse (for example, `finish` twice on the same id) shows up as `ArgumentError`.

A `record` template (planned) to cut test boilerplate:

```nim
let got = rec.record(myId, QueueOp(kind: qDequeue)):
  queue.tryDequeue()             # the result becomes the `return`
```

## Pending operations

An operation may have no `return`: the thread died, there was a timeout, or the test ended first. The history accepts that.

The checker considers **both possibilities** for each pending operation: it was applied or it was not (D-08, D-15). This can enlarge the search, so pending operations should be avoided in regression tests.

Typical example: a call cancelled or interrupted by the test's timeout. If the test does not need it, do not produce pending operations.

## Time

This applies to objects whose behavior depends on the clock (timeouts, cache TTL, rate limiters). The object under test must accept an injectable fake clock; the checker does not see a real clock. Two cases:

1. **Time fixed for the round.** The test advances the clock before the threads start and does not advance it during the round. No time event goes into the history. Recommended for first use.
2. **Time as an event (M10, planned).** Each clock advance records a `tick` event with a `seq`. The model treats `tick` as a transition. Needed only when the advance happens between concurrent operations.

Do not use `getMonoTime()` inside `step` or as an ordering criterion. It breaks determinism.

## Saved format (JSON)

One event per line (JSON Lines), for readable diffs and comparison in CI:

```json
{"kind":"invoke","op":3,"thread":1,"seq":17,"payload":{"kind":"enqueue","value":7}}
{"kind":"invoke","op":4,"thread":2,"seq":18,"payload":{"kind":"dequeue"}}
{"kind":"return","op":3,"thread":1,"seq":19,"payload":{"kind":"ok"}}
{"kind":"return","op":4,"thread":2,"seq":20,"payload":{"kind":"value","value":7}}
```

In the example, `enqueue` (op 3) and `dequeue` (op 4) overlap in time; the checker can order the `enqueue` before the `dequeue`, so the history is linearizable.

Fields:

| Field | Type | Required | Notes |
|---|---|---|---|
| `kind` | `"invoke"` or `"return"` | yes | |
| `op` | integer | yes | operation id; shared by `invoke` and `return` |
| `thread` | integer | yes | |
| `seq` | integer | yes | unique in the history, increasing; `seqNo` field in Nim (D-19) |
| `payload` | object | yes | operation (in `invoke`) or result (in `return`); converted by `toPayload`/`fromPayload` (see [API](API.md#json-tojsonlines-and-parsejsonlines)) |

Format rules:

- Keys in the order above, no extra spaces, one line per event, ending in `\n`.
- `LF` line endings, enforced by the repository's `.gitattributes` (`* text=auto eol=lf`).
- A round trip (read and rewrite) preserves the file byte for byte. This is tested (M1).
- A format change is a major version change (see [Decisions](DECISIONS.md), D-05).

## Saving a failed history

When the verdict is not `vkLinearizable` (`vkNotLinearizable` **or** `vkInconclusive`), save the history before failing. An inconclusive one also needs to be reproduced, to measure and shrink it. Use a name that identifies the round (for example, `failure-<round>.jsonl`):

```nim
if verdict.kind != vkLinearizable:
  writeFile("tests/fixtures/failure-" & $round & ".jsonl", h.toJsonLines())
  fail()
```

Then replay it without rerunning the test:

```nim
let h = parseJsonLines[QueueOp, QueueRes](readFile("tests/fixtures/failure-42.jsonl"))
echo checkLinearizable(h, QueueState(capacity: 4), QueueModel).report
```

A saved failing history becomes a fixture: it goes into `tests/fixtures/` with the expected verdict in `tests/golden/`.

## Common recording mistakes

General rule: widening an operation's interval (recording `invoke` earlier or `return` later) is safe; narrowing it creates real-time constraints that never existed.

| Mistake | Symptom | How to avoid |
|---|---|---|
| `invoke` recorded after the call | checker **rejects a correct history** (false `vkNotLinearizable`) | record `invoke` before calling |
| `return` recorded before the call finishes | checker **rejects a correct history** | record `return` after receiving the result |
| forgotten `return` for an operation with no result | the operation becomes pending; larger search | always call `finish`, even with an empty result |
| same `seq` on two threads | `ArgumentError` in `newHistory` | always use the atomic counter |
| compound operation recorded as two | the race bug becomes invisible (checker **accepts a wrong history**) | record the compound operation as a single one |
| wall-clock time as `seq` | wrong order for close events | use only the counter |
