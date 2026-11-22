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

## Limits of these numbers

- One shape only. Histories where operations overlap more widely (long operations spanning many rounds of other threads) or models with larger state spaces (`BoundedQueue`) can visit far more configurations. The Budget table keeps its conservative estimates until such shapes are measured too.
- Not measured in CI, and not on macOS or Windows.
