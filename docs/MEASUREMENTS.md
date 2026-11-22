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
- Not compared: memory, `outcomes` models, ticks.

### 2026-11-22, before M22 (for reference)

| Shape | Size | Time |
|---|---|---|
| A | n = 16 / 18 | 0.89 s / 5.5 s |
| B | n = 9 / 10 | 1.45 s / 15.7 s |
| C | 10 000 / 20 000 ops | 305 ms / 1.26 s (quadratic) |

## Limits of these numbers

- The memory table uses one shape only (`tests/measure/measure.nim`, an easy one; see shapes A and B for worst cases). Histories where operations overlap more widely (long operations spanning many rounds of other threads) or models with larger state spaces (`BoundedQueue`) can visit far more configurations. The Budget table keeps its conservative estimates until such shapes are measured too.
- Timing runs in CI only as a coarse regression check on Linux; no timings recorded for macOS or Windows.
