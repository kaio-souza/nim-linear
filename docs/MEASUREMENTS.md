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

Time only, measured with `tests/measure/bench.nim` (no `-d:nimlinearMeasure`):

```sh
nim c -r -d:release --mm:orc tests/measure/bench.nim
```

### 2026-11-22

Same machine and flags as above. One run each.

| Shape | Size | Verdict | Time |
|---|---|---|---|
| A. register: n writes all overlapping, then a read of a value never written | n = 8 | not linearizable | 0.6 ms |
| | n = 12 | not linearizable | 19.5 ms |
| | n = 14 | not linearizable | 120 ms |
| | n = 16 | not linearizable | 886 ms |
| | n = 18 | not linearizable | 5.5 s |
| B. queue: n enqueues all overlapping, then n dequeues, the last one wrong | n = 6 | not linearizable | 2.0 ms |
| | n = 8 | not linearizable | 130 ms |
| | n = 9 | not linearizable | 1.45 s |
| | n = 10 | not linearizable | 15.7 s |
| C. register: 4 threads × k ops, overlap width 4, linearizable | k = 250 (1 000 ops) | linearizable | 5.9 ms |
| | k = 1 000 (4 000 ops) | linearizable | 57 ms |
| | k = 2 500 (10 000 ops) | linearizable | 305 ms |
| | k = 5 000 (20 000 ops) | linearizable | 1.26 s |

What they show:

- **A and B are inherent.** Linearizability checking is NP-complete; A visits about `2^n · n` configurations and B one per ordered prefix of the enqueues. Every WGL-based checker (Porcupine, Knossos) has the same exponential shape here; only constants and partitioning (M11) help. Practical limit today: about 16 fully overlapping register ops or 8 fully overlapping queue ops per second of checking. Real tests stay far below that by keeping rounds small.
- **C is a defect.** Doubling the history (10 000 → 20 000 ops) multiplies the time by 4: the search is **quadratic** on long histories whose overlap is bounded, where it should be linear. Causes in `checker.nim`: `minRetOf` scans every operation at each step (O(n)); each stored configuration copies the whole bitset (O(n/64) per step, O(n²/64) memory overall); the candidate scan restarts from operation 0; matching returns to invokes is O(n²) once. Porcupine avoids these with a linked list of pending entries and an undo stack. Tracked as M22.

### State of the benchmarks (review, 2026-11-22)

- `tests/measure/measure.nim` measures an easy shape: staggered distinct writes visit few states (593 for 4 × 8). Its comment calls it a worst case; it is not. Shapes A and B are the real worst cases.
- No comparison with another checker on the same histories. Claims of being "equivalent to Porcupine" cannot be made yet (M23).
- No benchmark for `checkPartitioned`, for histories with pending operations, or for ticks.
- Not run in CI, so a performance regression would go unnoticed (M23).
- One machine, one run per row; no variance reported.

## Limits of these numbers

- The memory table uses one shape only. Histories where operations overlap more widely (long operations spanning many rounds of other threads) or models with larger state spaces (`BoundedQueue`) can visit far more configurations. The Budget table keeps its conservative estimates until such shapes are measured too.
- Not measured in CI, and not on macOS or Windows.
