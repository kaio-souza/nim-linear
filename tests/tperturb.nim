## M12: perturb() is empty without -d:nimlinearPerturb, and setPerturbation is
## a no-op. The active modes (M12, M13) are exercised by
## examples/queue_perturb.nim and examples/queue_pct.nim.
import std/unittest
import nimlinear/perturb

suite "perturb without the flag":
  test "perturb() and setPerturbation compile and do nothing":
    check not defined(nimlinearPerturb)
    setPerturbation(enabled = true, seed = 1)
    var n = 0
    for _ in 0 ..< 10:
      perturb()
      inc n
    check n == 10
