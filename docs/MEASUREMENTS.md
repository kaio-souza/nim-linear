# Measurements

Peak memory and visited states of `checkLinearizable`, measured as described in [CONTRIBUTING](../CONTRIBUTING.md#memory-measurement-m4). These are **preliminary local numbers**, from one machine and one history shape. They do not yet replace the estimates in the [Budget](API.md#budget) table.

## How to reproduce

```sh
nim c -r -d:release --mm:orc -d:nimlinearMeasure tests/measure/measure.nim
```

`-d:nimlinearMeasure` makes the checker sample `getOccupiedMem()` every 1 024 visited configurations and once more at the end, and print the peak minus the value at the start of the call (`peakDelta`, in bytes). Without the flag the sampling generates no code.

History shape (`tests/measure/measure.nim`): `Register` model; every thread invokes its first operation, then each thread in turn returns operation `k` and invokes `k + 1`, so operations of different threads overlap across neighbouring rounds. Every operation is a write of a distinct value. A final read returns a value never written, so the history is not linearizable and the checker must exhaust every reachable configuration.

## 2026-11-21

- Nim 2.2.4, `--mm:orc -d:release`, Linux amd64
- Intel Core i5-10210U, 10 GB RAM
- Identical results over 3 runs.

| History (threads × ops, + 1 final read) | Verdict | Visited states | Peak memory (delta) | Time |
|---|---|---|---|---|
| 2 × 4 | not linearizable | 23 | 1 184 B | 0.05 ms |
| 3 × 5 | not linearizable | 109 | 6 784 B | 0.06 ms |
| 4 × 8 | not linearizable | 593 | 41 280 B | 0.31 ms |

## Benchmarks

Time only, measured with `tests/measure/bench.nim` (M23). It also runs in CI with `--check`, which fails on a large regression (see the file header for the thresholds).

```sh
nim c -r -d:release --mm:orc tests/measure/bench.nim                # table
nim c -r -d:release --mm:orc tests/measure/bench.nim --export:DIR   # + JSON Lines for Porcupine
cd tests/measure/porcupine && go run . DIR                          # Porcupine on the same files
```

Shapes:

- **A**: register, n writes all overlapping, then a read of a value never written. Worst case (~`2^n · n` configurations).
- **B**: queue, n enqueues all overlapping, then n dequeues, the last one wrong. Worst case (one configuration per ordered prefix of the enqueues).
- **C**: register, 4 threads × k ops, overlap 4, linearizable. Should be linear.
- **D**: map with 3 keys, 4 overlapping writes per key, then a read per key, the last one wrong; with and without partitioning.
- **E**: like C, every 10th operation pending (never returns).

### 2026-11-22, after M14–M24

Nim 2.2.4, `--mm:orc -d:release`, Linux amd64, Intel Core i5-10210U. Porcupine v0.1.6, Go 1.23.4, same machine, same files. One run each. **Run-to-run noise on this machine is up to 2x** for the slow rows (A n=16 measured 0.94 s and 1.65 s in consecutive runs).

| Shape | Size | nimlinear | Porcupine |
|---|---|---|---|
| A | n = 12 | 36 ms | 25 ms |
| A | n = 14 | 139 ms | 136 ms |
| A | n = 16 | 0.95 s | 0.84 s |
| B | n = 6 | 1.5 ms | 3.1 ms |
| B | n = 8 | 112 ms | 18.3 s |
| B | n = 9 | 1.29 s | timeout (60 s) |
| C | 10 000 ops | 5.6 ms | 17.7 ms |
| C | 20 000 ops | 9.0 ms | 52.4 ms |
| C | 40 000 ops | 18.1 ms | 202 ms |
| D | not partitioned / partitioned | 0.3 ms / < 0.1 ms | 0.5 ms / < 0.1 ms |
| E | 1 000 ops | 0.5 ms | 0.9 ms |
| E | 2 000 ops | 1.3 ms | 2.0 ms |
| E | 4 000 ops | 4.5 ms | 4.8 ms |

How to read it:

- **A**: same order of magnitude; the exponential shape is inherent.
- **B**: nimlinear is much faster here. Probable reason: its memo key includes the full model state with a hash, while the Go model in `tests/measure/porcupine/main.go` (written for this comparison) only provides `Equal`, so Porcupine compares states one by one. A Porcupine expert might write a faster model; treat this row with care.
- **C**: nimlinear grows linearly (2x per doubling) after M22; before M22 it took 1.26 s for 20 000 operations. Porcupine grows faster than linearly on this shape.
- **E**: both grow faster than linearly with many pending operations (nimlinear about 3x per doubling). Known limit, see D-25.
- Not compared in this table: `outcomes` models, ticks. Memory: see [the 2026-11-25 memory comparison](#memory-against-porcupine).

### 2026-11-22, before M22 (for reference)

| Shape | Size | Time |
|---|---|---|
| A | n = 16 / 18 | 0.89 s / 5.5 s |
| B | n = 9 / 10 | 1.45 s / 15.7 s |
| C | 10 000 / 20 000 ops | 305 ms / 1.26 s (quadratic) |

### 2026-11-25, 15 runs each (median and IQR)

Same machine and toolchains as above: Nim 2.2.4 `--mm:orc -d:release`, Go 1.23.4, Porcupine v0.1.6, Linux amd64, Intel Core i5-10210U. Each run is one pass of `bench` (nimlinear) or of the Porcupine harness over the same exported files, run in sequence, not in parallel. A Porcupine pass includes the 60 s timeout of `queue_B9`, so one pass takes about 90 s.

Conditions, so the numbers can be repeated:

- **Builds:** `nim c -d:release --mm:orc` for `bench` (threads off, the default); `go build` of `tests/measure/porcupine` with Go 1.23.4 (module `github.com/anishathalye/porcupine` v0.1.6).
- **Histories:** one `bench --export:DIR` run wrote the JSON Lines files; every pass read those same files. Porcupine's timing covers `CheckOperationsTimeout` only, as nimlinear's covers `checkLinearizable` only; parsing is outside both.
- **Runs:** 15 passes of nimlinear, then 15 of Porcupine, sequentially in one background script (not part of the repository). Nothing else of this project ran during them.
- **Machine:** 8 logical CPUs, load average about 1 at the start; no CPU pinning, no governor change, no other benchmark in parallel. The machine is a laptop-class CPU and was not isolated, so timings carry its normal variance.
- **Reading the table:** median and IQR over the 15 runs; `timeout` means the 60 s limit was hit in every run.

| Shape | Size | nimlinear, median [IQR] | Porcupine, median [IQR] |
|---|---|---|---|
| A | n = 8 | 0.7 ms [0.7–0.8] | 0.6 ms [0.5–0.6] |
| A | n = 12 | 26.6 ms [25.5–27.7] | 24.8 ms [23.1–25.6] |
| A | n = 14 | 162 ms [161–180] | 129 ms [124–140] |
| A | n = 16 | 1.06 s [1.02–1.09] | 0.85 s [0.83–0.92] |
| B | n = 6 | 1.5 ms [1.4–1.9] | 3.1 ms [2.9–3.3] |
| B | n = 8 | 113 ms [111–148] | 19.3 s [18.0–21.9] |
| B | n = 9 | 1.29 s [1.28–1.30] | timeout (60 s) in 15 of 15 runs |
| C | 10 000 ops | 5.6 ms [5.5–6.1] | 17.4 ms [16.5–18.6] |
| C | 20 000 ops | 10.3 ms [10.1–10.8] | 54.0 ms [52.4–59.1] |
| C | 40 000 ops | 20.2 ms [19.6–21.8] | 208 ms [200–210] |
| D | not partitioned | 0.3 ms [0.3–0.4] | 0.5 ms [0.5–0.5] |
| D | partitioned | < 0.1 ms | < 0.1 ms |
| E | 1 000 ops | 0.6 ms [0.6–0.6] | 1.0 ms [0.8–1.0] |
| E | 2 000 ops | 1.5 ms [1.4–1.6] | 2.2 ms [2.1–2.4] |
| E | 4 000 ops | 4.4 ms [4.1–4.6] | 5.8 ms [5.1–6.0] |

What the repeated runs change in the reading above:

- **A: Porcupine is faster** for n = 12 to 16, and the IQRs do not overlap from n = 14.
- **B: nimlinear is faster** by a wide margin at every size, with the caveat about the Go model from the 2026-11-22 table still applying.
- **C and E: nimlinear is faster**, and its growth is linear on C (2x per doubling) and about 2.5x on E.
- **D:** both are below a millisecond; the partitioned check is faster than the whole-history check on both tools.

The IQRs are narrow for most rows (within about 10 % of the median). The wide ones are nimlinear's B n = 8 (111–148 ms) and the sub-millisecond rows, where the timer resolution of `bench` (0.1 ms) dominates.

## Memory against Porcupine

Same shapes, same exported files, same method on both sides: a fresh process loads the history and checks it, and the process reports its peak resident set size (`VmHWM` from `/proc/self/status`, Linux only). `tests/measure/memory.nim` does it for nimlinear; `go run . -mem register|queue FILE load|check` in `tests/measure/porcupine` does it for Porcupine. Each point is the median of 5 processes.

Build and run: `nim c -d:release --mm:orc -o:DIR/mem tests/measure/memory.nim`, then `DIR/mem register|queue FILE load|check`; and `go build` in `tests/measure/porcupine`, then `DIR/porc -mem register|queue FILE load|check`. Same files and same 5-run median as the timing table, on the same machine and in the same session. Only `VmHWM` is read; the Go GC and the Nim allocator are left at their defaults.

Reported: the peak RSS of the **check** process, which is what a test process needs. The load-only baseline is shown in the run notes below; it differs between the two tools (the parser of nimlinear keeps the whole file text, and the Go loader builds its own operation slice), so subtracting it would mix parser memory into the checker's figure.

| History | nimlinear, check (peak RSS) | Porcupine, check (peak RSS) | Verdict |
|---|---|---|---|
| register A, n = 12 | 7.1 MB | 6.5 MB | not linearizable |
| register A, n = 14 | 22.3 MB | 14.5 MB | not linearizable |
| register A, n = 16 | 82.4 MB | 55.8 MB | not linearizable |
| queue B, n = 8 | 39.0 MB | 25.9 MB | not linearizable |
| register C, 40 000 ops | 44.4 MB | 231.5 MB | linearizable |
| register E, 4 000 ops | 5.8 MB | 8.7 MB | linearizable |

How to read it:

- **Exponential shapes (A, B):** nimlinear peaks at about 1.1 to 1.5 times Porcupine's memory. The reason for the larger peak on nimlinear's side has not been measured.
- **Long history with bounded overlap (C, E):** nimlinear is about 5 times lower on C (40 000 operations) and 1.5 times lower on E.
- **Load baseline (not the checker):** before the check, the process of nimlinear is at 2 MB for the small files and 33.7 MB for C's 40 000 operations; Porcupine's is 2.6 MB and 19.5 MB. The extra 14 MB on nimlinear's side is the JSON Lines parser, not the checker.

Caveats: RSS is what the OS reports, so allocator and GC behaviour count (Go's GC and nimlinear's `--mm:orc` free memory at different times); one machine; one shape per row; `queue_B9` was not measured, since Porcupine times out on it. `kv_D` (the map model) was not measured, because the memory harness does not include it.

## Checker performance (P9, 2026-11-25)

Each P9 step was an experiment, kept only with a clear gain on both `bench` and `memory.nim`. Before and after binaries were built from the same tree, differing only in `src/nimlinear/checker.nim`, and run alternately in one session on the machine above (Nim 2.2.4, `--mm:orc -d:release`). Time: median of 3 interleaved `bench` passes. Memory: median of 5 `memory.nim ... check` processes on the files of one `bench --export` run. This is fewer runs than the 15-run table above, and absolute times in this session were higher than in that table (A n = 16 before P9: 1.44 s here, 1.06 s there), so compare only the two columns with each other.

**P9.1, kept: the window inline in the memo key.** Before: each visited configuration held a heap `seq` for its window, and the search looked each new configuration up twice (`in`, then `incl`). After: the key is `f` (32 bits), the word count, the first window word inline, and a shared, copy-on-write `ref seq` for words 1 and up (nil until the overlap passes 64 operations), so a key is 24 bytes with no allocation; one `containsOrIncl` per configuration. A first version that stored two inline words and a cached hash was faster but used up to 1.8x more memory (A n = 16: 150 MB against 84 MB): every byte of a key is paid for in every slot of the `HashSet`, empty ones included, and the set already stores each key's hash.

| Shape | Size | before | after P9.1 |
|---|---|---|---|
| A | n = 12 | 36.0 ms | 23.4 ms |
| A | n = 14 | 224 ms | 135 ms |
| A | n = 16 | 1.44 s | 0.86 s |
| B | n = 8 | 165 ms | 112 ms |
| B | n = 9 | 1.81 s | 1.32 s |
| C | 40 000 ops | 28.3 ms | 24.2 ms |
| E | 4 000 ops | 5.4 ms | 4.6 ms |

| History | before, peak RSS | after P9.1, peak RSS |
|---|---|---|
| register A, n = 14 | 22.8 MB | 22.5 MB |
| register A, n = 16 | 84.5 MB | 84.0 MB |
| queue B, n = 8 | 39.9 MB | 39.9 MB |
| queue B, n = 9 | 316 MB | 305 MB |
| register C, 40 000 ops | 46.1 MB | 46.8 MB |
| register E, 4 000 ops | 6.3 MB | 6.0 MB |

So time drops by about 40 % on A and 27–32 % on B, and memory is unchanged (within 1.5 %, B n = 9 3 % lower). The memory gap to Porcupine on A and B (previous section) is therefore not the window's allocation, as the roadmap had assumed; it stays unexplained.

**P9.2, dropped: pending operations out of `(f, window)`.** Tried: `f` as the first *completed* unlinearized operation, the pending unlinearized operations below it kept as a sorted list in the key, and tried first as candidates. Correct (oracle and `-d:nimlinearDebug` invariants passed), but against P9.1 it made A and B 6–25 % slower (A n = 16: 0.86 s to 1.03 s) and did not help E (4.6 ms to 5.0 ms): in shape E the search linearizes pending writes as it meets them, so they rarely hold `f` back. The known limit of D-25 (pending operations that are never linearized) stays.

**P9.3, not done: parallel `checkPartitioned`.** No benchmark shape has parts large enough to gain (D partitioned is under 0.1 ms), and it would require thread-safe models for every user. Left until a real case needs it.

## Round harness cost

R6 and R7, measured with `tests/measure/rounds_cost.nim`:

```sh
nim c -r -d:release --mm:orc --threads:on tests/measure/rounds_cost.nim
```

### 2026-11-24

- Nim 2.2.4, `--mm:orc -d:release --threads:on`, Linux amd64, 8 logical CPUs (Intel Core i5-10210U)
- 3 runs; ranges below.

**Where a round's time goes (R6).** `runRound` with an atomic counter, then `checkLinearizable` on each history, then the same number of create/join of empty threads alone:

| Round | Record (per round) | Empty create + join | Check (per round) | Create + join share |
|---|---|---|---|---|
| 3 threads × 4 ops | 62–78 µs | 43–52 µs | 5–7 µs | 60–64% |
| 8 threads × 4 ops | 164 µs | 118 µs | 12.5 µs | 67% |

Creating and joining threads is most of a round, but a round is cheap: 5 000 rounds of 3 × 4 take about 0.4 s. **Decision: no thread pool for now.** Fresh threads per round keep rounds isolated (thread-local state, such as the scheduler's thread id and `perturb`'s generator, starts clean), and the saving would be well under a second per test. Revisit if a test needs far more rounds or an `exec` makes the rest of the round much cheaper than here.

**Recorder overhead and its effect on interleavings (R7).** 3 threads, each 2 000 increments of a read-then-write counter (lost updates on purpose), 50 trials; the final value is compared without the checker, with and without `Recorder.record` around each increment:

| | Time per increment | Lost updates |
|---|---|---|
| plain | 5–7 ns | 57–60% of increments |
| recorded, before padding | 162–171 ns | 7.7–9.3% |
| recorded, padded buffers (current) | 110–142 ns | 7.3–7.8% |

Recording costs ~100–140 ns per operation, mostly the shared atomic `seq` counter (two `fetchAdd` per operation on one contended cache line). Before, buffers of different threads also shared cache lines; they are now padded to separate lines, which cut the overhead by about a third. The counter itself cannot go: it defines the `seq` order the checker relies on.

The effect on interleavings is large: recording makes this race about **8× less frequent**, because the time spent recording is time outside the racy window, and the shared counter partly serializes the threads. Consequence: rely on `perturb()` points and the PCT scheduler (Guide, step 5b) to open narrow windows, not on raw thread overlap; and always confirm with an injected bug that the test fails (Guide, step 5). This measures the most contended case (back-to-back operations); with real operations that take longer than the recording, the relative effect is smaller.

## Intercepted atomics and locks (P6)

Validation of `nimlinear/intercept` (D-26) on a real library, `nim-circuit-breaker` (lock-free fast paths on `Atomic` fields plus one `Lock`), on a local copy: its two `std/atomics`/`std/locks` imports switched behind `-d:nimlinearIntercept`, rounds of 3 threads × 4 operations (its existing model, `setup` and generator) under the PCT scheduler, `steps = 200`.

### 2026-11-24

- Nim 2.2.4, `--mm:orc -d:release --threads:on`, Linux amd64, 8 logical CPUs

| Breaker | Rounds | OS scheduler, no interception | PCT + intercept, depth 2 | depth 3 | depth 4 |
|---|---|---|---|---|---|
| as released | 2 000 | 0 failures | | 0 | 0 |
| injected bug: HalfOpen probe check and increment in two critical sections | 2 000 | 0, 0, 1 (three runs) | 2 | 4 | 12 |

**`steps` matters more than `depth`.** The table above used `steps = 200`. Counting the switch points (`Scheduler.stepsTaken`) gave a median of **11 per round** (min 6, max 21), so almost every PCT change point fell after the round ended. Same injected bug, 2 000 rounds:

| `steps` | depth 3 | depth 4 |
|---|---|---|
| 200 | 4 | 12 |
| 30 | 65 | 100 |
| 12 (≈ measured) | **150** | **215** |

The breaker as released still passes with `steps = 12`, depth 4 (0 failures in 2 000 rounds). This led to D-29: `RoundsConfig(schedule: true)` calibrates `steps` on round 1.

**Replay shrink with calibrated steps** (racy counter, 3 × 12 operations, 200 rounds, seeds 1–10, all fail in round 1): `steps = 30` kept 20 (depth 3) and 18 (depth 4) of 36 operations on average; calibrated `steps` kept 19 and 18. No gain: removing operations moves the switch points whatever `steps` is (D-29, consequence).

With interception the failing rounds are the same on every run (reproducible from the seed); under the OS scheduler the bug showed up once in 6 000 rounds and cannot be replayed. 2 000 scheduled rounds took about 0.2 s of main-thread CPU. No code of the breaker was changed besides the two imports, and no `perturb()` was added.

## External code: `nim-lang/threading` `Chan` (2026-11-25)

First test of nimlinear on a library it was not written for. Target: `Chan[int]` of [`nim-lang/threading`](https://github.com/nim-lang/threading), non-blocking `trySend`/`tryRecv` only, checked against the `BoundedQueue` model (`trySend` false = `full`, `tryRecv` false = `empty`). Same machine and toolchain as the benchmarks above; `-d:release --mm:orc`; 4 threads × 6 operations, capacity 4, unless stated. Test program and patched copies were kept outside the repository.

**What was found.** In `channelSend`/`channelReceive`, the non-blocking path checks `isFull`/`isEmpty` before taking the lock. Each check reads `head` and `tail` with two separate loads, and other threads can move both between them, so the pair can describe a state the channel was never in: `tryRecv` returns `false` while the channel holds a message for the whole call, and `trySend` returns `false` while the channel is not full. Present in commits `629e175`, `9c74c61` and `653c8eb` (master at the time of the test). Confirmed without nimlinear by a deterministic program that pauses one thread between the two loads (the only change to the library: that pause point): `tryRecv` returned `false` with item 2 in the channel during the whole call, and `trySend` returned `false` on a 2-slot channel that never held more than 1 item, in 3 of 3 runs. Not reported upstream yet.

| Setup (master `653c8eb` unless stated) | Seeds | Result |
|---|---|---|
| Unmodified library, OS scheduler | 3 × 2000 rounds | passed: the window is a few instructions wide |
| `perturb()` placed by hand between the two loads, random perturbation | 3 × 2000 | failed in 3 of 3 (rounds 2, 26, 30); also on `629e175` and `9c74c61` |
| Only the import switched to `nimlinear/intercept`, writes intercepted (D-26), no scheduler (`-d:nimlinearInterceptNoLocks`) | 3 × 2000 | passed: no switch point inside the window |
| Same, plus `-d:nimlinearInterceptLoads` (D-31), random perturbation | 12 × 2000 | failed in 9 of 12 (rounds 33 to 1475), not repeatable by seed |
| Same, under PCT (`schedule = true`, `Cond` as `SchedCond`, D-31) | 12 × 2000 | **failed in 12 of 12** (rounds 10 to 583), the same round for the same seed in 3 of 3 reruns |
| Control: PCT as above, with the two unlocked pre-checks removed | 12 × 2000 | passed in 12 of 12 |
| Exploration (`explore = true`, `preemptions = 2`, D-32), 2 threads × 3 operations, capacity 2 | 20 rounds | failed in round 3 after 847 schedules; control: passed, complete, 4 402 schedules |
| Exploration, 3 threads × 2 operations, capacity 2 | 10 rounds | failed in round 1 after 3 861 schedules; control: passed, complete, 37 992 schedules |
| Exploration, 2 threads × 2 operations, capacity 1 | 20 rounds | passed, complete, 4 099 schedules (no failing scenario among those generated) |

How to read it:

- The bug was out of reach for the unmodified library under the OS scheduler, and for interception of writes only. It became reachable with switch points on loads, and repeatable with PCT once `Cond` could run under the scheduler.
- Under PCT the failing round depends on the seed (10 to 583); exploration finds it in a fixed number of schedules and, on the control, states that every schedule within the bound passes.
- One run before R16 produced a shrunk history that was not a real failure (`dequeue() -> 3` with no `enqueue(3)` left). That is what R16 fixed. The rows up to the PCT control were measured before the fix; from the `-d:nimlinearInterceptLoads` row on, the recorded (unshrunk) history of every failure was checked and failed with a spurious `empty` or `full` (the hand-placed `perturb()` row was not checked this way).
- The issue `#24` of that repository (two locks, fixed by `9c74c61`) did not show as a wrong result: both commits fail the same way, through the pre-check.

## External code, second pass: known bugs of `nim-lang/threading` (2026-11-25)

Goal: reproduce bugs already fixed upstream, each against its own fix as the control, to check that the features added after the `Chan` test (`SchedCond`, liveness, `quiescent`, `Shared[T]`, exploration, the watchdog) work on code nimlinear was not written for. Same machine and toolchain as above; `-d:release --mm:orc` unless stated. Test programs and patched copies were kept outside the repository. "Import swapped" means the library's `import std/locks` (and `std/atomics`) line was replaced by `nimlinear/intercept` behind `-d:nimlinearIntercept`, and nothing else.

| Case (buggy → fixed commit) | Change to the library | Buggy | Fixed (same change) |
|---|---|---|---|
| `WaitGroup`: `leave` uses `signal` instead of `broadcast`, so with two waiters one sleeps forever (`dfaefbe` → `ad7b416`) | import swapped | exploration: deadlock after 11 schedules (2 waiters) and 85 (3 waiters); PCT: failed in 10 of 10 seeds, rounds 1 to 11; OS scheduler, no interception: hung in round 3, reported by the watchdog (`roundTimeout`, exit 124) | exploration: passed, complete (680 and 23 970 schedules); PCT and OS scheduler: 2000 rounds passed |
| `SharedPtr` (#45): `=destroy` loads the count, then decrements it, so two owners can both decrement and nobody frees (`148b0da` → `c099fbd`) | one `perturb()` between the two operations | exploration: payload destroyed 0 times after 2 schedules (2 and 3 threads); PCT: failed in round 1 | exploration: passed, complete (18 and 180 schedules); PCT: 500 rounds passed |
| `SharedPtr` (#45), same | none (OS scheduler, `quiescent` only) | failed in 3 of 6 runs of 20 000 rounds: rounds 18 821 (3 threads), 828 and 5 828 (4 threads); none with 2 threads | 6 of 6 runs of 20 000 rounds passed (2, 3 and 4 threads) |
| `Chan` destructor (#59): same pattern as #45 (`2ce3d80` → `f9e3ec4`) | one `perturb()` in `=destroy`; ASan build | exploration: failed after 2 schedules (2 and 3 threads); PCT: failed in round 1. The leak is tied to the round by a `quiescent` hook that calls LeakSanitizer (`__lsan_do_recoverable_leak_check`) | exploration: passed, complete (12 and 120 schedules); PCT: 200 rounds passed |
| `Chan` with two locks (#24, `629e175` → `9c74c61`), pre-checks removed | import swapped; `head`/`tail` declared `Shared[int]` (58 lines, mechanical) | PCT, 4 threads × 6 operations: **a value delivered twice** in 6 of 6 seeds, rounds 18 to 985 | PCT: 6 of 6 seeds passed (2000 rounds each) |

How to read it:

- **#24 is new for nimlinear.** The first test of `Chan` could not show it: with `head`/`tail` as plain `int` (import swapped only), every configuration passed. Declared `Shared[int]`, the two-lock design delivers a value twice under PCT, and the single-lock fix passes under the same changes.
- **Leaks, not double frees.** #45 describes a double free; in these runs only the leak appeared. With the counter starting at owners − 1, two threads read 0 only after a lost decrement, so under sequential consistency the race loses a free rather than doing one twice.
- **#45 without any change to the library** was found only with 3 and 4 threads and late (rounds 828 to 18 821): the `quiescent` hook sees the leak whenever the OS happens to interleave the two operations.
- **Exploration did not reach #24** in small scenarios (2 threads × 3 operations, complete with 2 and 3 preemptions; 3 threads × 2 operations, cut at 10 000 schedules). PCT with 4 threads × 6 operations did.
- **The pre-check bug with `Shared`.** `9c74c61` with `Shared` fields and the pre-checks kept passed 6 × 2000 PCT rounds, while `master` with intercepted atomic loads fails in 12 of 12 seeds (first section). The probability of PCT reaching a window depends on how many switch points the code has.

Not reproduced:

- **`nim-taskpools` #41** (a worker spinning in work stealing with `chronos` `ThreadSignalPtr`): closed without a fix, so there is no control; it also depends on OS signals outside any switch point.
- **`Once` (#67)**: the fix is about memory ordering (synchronizes-with); under sequential consistency the old behavior looks correct, so it is outside nimlinear's model.

Limit found: `SharedPtr` and the `Chan` destructor import `threading/atomics`, the library's own atomics module (`Atomic[T]` as `distinct T`, orderings named `Acquire`), not `std/atomics`. `nimlinear/intercept` replaces only `std/atomics` and `std/locks`, so for those files the switch point was placed by hand.

## External code, third pass: four more libraries (2026-11-25)

Goal: run nimlinear on lock-free code it was not written for, beyond `nim-lang/threading`. The four targets were picked because their API maps onto an existing or a small model. Same machine as above, Nim 2.4.2, gcc 15.2, `-d:release --mm:orc` unless stated. In every library the only change is the import line: `std/atomics` becomes `nimlinear/intercept` behind `-d:nimlinearIntercept` (plus the loony compile fix below). "OS" = unmodified build, OS scheduler. "PCT" and "explore" = intercepted build with `-d:nimlinearInterceptLoads`, `schedule = true` or `explore = true` (`preemptions = 2`). Test programs and patched copies were kept outside the repository. Nothing was reported upstream.

| Target (commit) | Model | OS | PCT | Explore | Verdict |
|---|---|---|---|---|---|
| `codenimja/nimsync` `Channel`, SPSC (`ee99327`) | `BoundedQueue`, capacity 2; 1 producer, 1 consumer | 3 × 2000 passed | 6 × 2000 passed | 3 × 20 rounds passed, complete (3 080 schedules) | linearizable in what was run |
| same, MPSC | same; 2 producers, 1 consumer | 3 × 2000 passed | **failed in 6 of 6 seeds** (rounds 1 to 11) | **failed** in 3 of 3, round 1, 203 schedules | **two bugs**, below |
| `Araq/malebolgia` `TicketLock`, `TicketRWLock` (`561ae24`) | counter guarded by the lock (`Shared[int]` in the test, so the critical section has switch points) | 3 × 2000 passed | not usable: spin-wait (below) | not usable: spin-wait | passed 6 × 3000 rounds with random perturbation (intercepted build, no scheduler) |
| `status-im/nim-taskpools` `ChaseLevDeque` (`306cf82`) | deque: owner `push`/`pop`, other threads `steal`; `push` returns `wasEmpty` | 4 × 2000 passed (1 and 2 thieves) | 1 thief: 4 × 2000 passed. 2 thieves: passed with ABORT in the model (below) | 1 thief: complete, ~5 600 schedules per seed; 2 thieves with ABORT: complete, ~85 000 | linearizable, ABORT included; initial capacities 1, 2, 4, 8 (buffer growth) |
| `nim-works/loony` `LoonyQueue` (`b60da76`, `arc` `0728843`) | `BoundedQueue` with a capacity no round reaches (unbounded MPMC); `pop() = nil` = empty | 4 × 2000 passed | **failed in 12 of 12 seeds** (rounds 1 to 40) | **failed** in 3 of 3 (49 to 357 schedules) | **spurious empty**, below |

**nimsync MPSC, bug 1: spurious `full`.** `trySendMPSC` reserves a slot with `mpscCount.fetchAdd(1)` and, if the count was already at capacity, undoes it with `fetchSub(1)`. Between the two, another producer sees the inflated count and returns `false` on a channel that is not full. Recorded history (seed 1, round 9): the consumer drains the channel, `enqueue(0) -> ok` leaves 1 item of 2, then `enqueue(1) -> full`; the trace shows the concurrent, failing send of thread 1 between its `fetchAdd` (`channel_spsc.nim:82`) and `fetchSub` (`:85`).

**nimsync MPSC, bug 2: spurious `empty`.** `tryReceiveMPSC` returns `false` when the slot at `tail` is claimed but not yet published (code comment: "Producer in-flight, try again later"), even when the channel holds published items. When another operation fixes that the in-flight item already counts (here a `full` that needs it), the `empty` has no linearization. Control: a copy with bug 1 fixed (reservation by a CAS loop that never goes above capacity). Over 12 PCT seeds, the original failed 5 times with `full` and 7 with `empty`; the control failed 12 times, all `empty`. So the CAS fixes bug 1, and bug 2 stays. The comment suggests the behavior is intended, but the API does not say that `tryReceive` can fail on a non-empty channel. Not confirmed yet by a program without nimlinear.

**Chase-Lev ABORT, expected.** With 2 thieves and a model where `steal` only returns nothing on an empty deque, PCT failed in 4 of 4 seeds and exploration in 4 of 4. The shrunk history is a `steal` that lost its CAS on `top` to another thief and returned 0 while items remained. This is the ABORT outcome of the algorithm (Lê et al. 2013), which the library maps to the same `default(T)` as "empty". With ABORT as a second `outcomes` branch of `steal` (allowed only on a non-empty deque), every run passed. `wasEmpty` was checked as part of the result (true when the deque was empty at the push) and passed.

**loony: spurious empty in `pop`.** `popImpl` reads `tail`, then `head`, then calls `isEmptyImpl(head, tail)`. If other threads push and pop between the two loads, `head` can pass the stale `tail`, and `pop` returns `nil` on a queue that was never empty during the call. Recorded history (seed 1, round 22): `dequeue()` of thread 0 runs from seq 5 to 26, while the queue holds 2 to 4 items. The trace shows thread 0 loading `tail` (`loony.nim:71`) at step 5 and paused before its `head` load (`:75`) until step 35.

- **Confirmed without nimlinear:** a deterministic program on a copy whose only change is a pause point after `fetchTail` in `popImpl`. Thread A pops from `[1]` and pauses; the main thread pushes 2 and pops 1; A resumes and gets `nil` while 2 is still in the queue. Result: 3 of 3 runs.
- **Control:** the same copy with the two loads swapped (`head` first, then `tail`; both only grow, so a `head` at or past a later `tail` means the queue was empty at the second load). PCT: 4 × 2000 passed. Exploration: 3 × 20 rounds passed, complete (about 2 600 schedules each).

Open, not diagnosed:

- **Small nodes.** With `-d:loonySlotCount=4 -d:loonyNodeAlignment=6 -d:loonyRotate=false` (node changes in almost every round), a debug build of the control still fails under PCT with a spurious empty (3 of 3 seeds, rounds 57 to 459). So the node-change path (`advHead`) seems to have a second window. The release build of the same configuration ends in SIGSEGV under the scheduler (original and control), not under the OS scheduler. The cause, loony or the scheduler, is not known. `loonySlotCount=4` with rotation on is not a valid configuration (`rShiftBits` is negative; the library's static checks do not catch it), so it was not used.
- **Compile fix.** loony at `b60da76` does not compile with Nim 2.4.2 and gcc 15 (its own `tests/test.nim` neither): `template node(tag) = cast[ptr Node](nptr(tag))[]` becomes `&` of an rvalue in C. All loony rows use a copy where the cast goes through a one-line `proc` (`nodeAt`).

What this pass showed about nimlinear:

- **Spin-waits cannot run under the scheduler.** `TicketLock.acquire` spins on `nowServing.load`. Under PCT every round ends in the step limit ("no end after 100000 switch points"). Exploration aborts after 2 schedules too: its default choice keeps running the current thread, so a thread that spins while another holds the lock never gives way. Only random perturbation works for these locks. This matches what the [API](API.md) says for PCT. For exploration, the API says a spin-wait on a `Shared` field "needs `explore`". That case was not tested here, but an atomic spin-wait does not work under exploration.
- **Size of the report on a livelock.** The `describe` of an exploration that hit the step limit prints the whole failing schedule (one entry per switch point): about 290 KB for one round.
- **Cost.** A loony round under PCT takes about 30 ms (one 1 024-slot node per round), against about 0.15 ms for the other targets.

## Limits of these numbers

- The memory table uses one shape only (`tests/measure/measure.nim`, an easy one; see shapes A and B for worst cases). Histories where operations overlap more widely (long operations spanning many rounds of other threads) or models with larger state spaces (`BoundedQueue`) can visit far more configurations. The Budget table keeps its conservative estimates until such shapes are measured too.
- Timing runs in CI only as a coarse regression check on Linux; no timings recorded for macOS or Windows.
