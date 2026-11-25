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

## Limits of these numbers

- The memory table uses one shape only (`tests/measure/measure.nim`, an easy one; see shapes A and B for worst cases). Histories where operations overlap more widely (long operations spanning many rounds of other threads) or models with larger state spaces (`BoundedQueue`) can visit far more configurations. The Budget table keeps its conservative estimates until such shapes are measured too.
- Timing runs in CI only as a coarse regression check on Linux; no timings recorded for macOS or Windows.
