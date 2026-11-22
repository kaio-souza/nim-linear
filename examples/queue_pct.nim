## M13 acceptance: the controlled PCT scheduler reproduces and finds the bug.
##
## Same narrow-window queue as queue_perturb.nim, with every worker
## registered in a `Scheduler` (only one thread runs at a time; switches
## happen only at perturb() points). Checks that:
## 1. the same seed gives the same history, byte for byte, on repeated runs;
## 2. the correct queue is linearizable for every seed tried;
## 3. the buggy queue is rejected within `budget` seeds (one round per seed).
##
## Run: nim c -r --threads:on examples/queue_pct.nim

when not compileOption("threads"):
  {.error: "this example needs --threads:on".}

import nimlinear
import nimlinear/schedule
import ./common/queue

const budget = 50          # documented round budget (README, M13)

var sched: Scheduler

proc enterHook(tid: int) {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}: sched.enter(tid)
proc leaveHook() {.nimcall, gcsafe, raises: [].} =
  {.cast(gcsafe).}: sched.leave()

proc scheduledRound(buggy: bool, seed: int): History[QueueOp, QueueRes] =
  sched.initScheduler(threads, seed, depth = 3, steps = 40)
  result = runRound(buggy, wNarrow, Hooks(enter: enterHook, leave: leaveHook))
  sched.deinitScheduler()

proc main(): int =
  for seed in [1, 7, 42]:
    let first = scheduledRound(buggy = true, seed).toJsonLines
    for _ in 1 .. 5:
      if scheduledRound(buggy = true, seed).toJsonLines != first:
        echo "seed ", seed, ": history differs between runs"
        return 1
  echo "same seed, same history: ok (seeds 1, 7, 42; 6 runs each)"

  for seed in 1 .. budget:
    let v = check(scheduledRound(buggy = false, seed))
    if v.kind != vkLinearizable:
      echo "correct queue rejected with seed ", seed, ":\n", v.report
      return 1
  echo "correct queue: linearizable for seeds 1..", budget

  for seed in 1 .. budget:
    let h = scheduledRound(buggy = true, seed)
    let v = check(h)
    if v.kind == vkNotLinearizable:
      echo "buggy queue: rejected with seed ", seed, " (budget ", budget, ")"
      echo v.report
      echo "history saved to ", h.save("queue_pct_failure.jsonl")
      return 0
  echo "buggy queue: bug not found within ", budget, " seeds"
  1

quit main()
