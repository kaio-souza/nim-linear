## M12 acceptance: perturbation finds a narrow-window bug in fewer rounds.
##
## Same queue as queue_race.nim, but the buggy `dequeue` has no `sleep(0)` in
## its window, only a `perturb()` point. Compiled with -d:nimlinearPerturb
## (see queue_perturb.nims). For each of `trials` seeds, counts the rounds
## until the bug is rejected (capped at `cap`), with perturbation off and on.
## Exits with 0 only if the total with perturbation is lower.
##
## Run: nim c -r --threads:on examples/queue_perturb.nim

when not compileOption("threads"):
  {.error: "this example needs --threads:on".}

import nimlinear
import nimlinear/perturb
import ./common/queue

const
  trials = 10
  cap = 200

proc roundsToFind(seed: int): int =
  mode = (buggy: true, window: wNarrow)
  var cfg = config(cap, seed, "queue_perturb")
  cfg.shrink = false
  let r = runRounds(cfg, initState, QueueModel, setup, genOp, exec, teardown)
  if r.passed: cap + 1 else: r.rounds

proc main(): int =
  var off, on: int
  var offRuns, onRuns: seq[int]
  for seed in 1 .. trials:
    setPerturbation(enabled = false, seed = seed)
    let a = roundsToFind(seed)
    setPerturbation(enabled = true, seed = seed)
    let b = roundsToFind(seed)
    offRuns.add a; onRuns.add b
    off += a; on += b
  echo "rounds to find the bug (", cap + 1, " = not found in ", cap, "), per seed:"
  echo "  without perturbation: ", offRuns, " total ", off
  echo "  with perturbation:    ", onRuns, " total ", on
  if on < off: 0 else: 1

quit main()
