## M8 end-to-end example: a real lock-based bounded queue, recorded from
## several threads and checked against the `BoundedQueue` model.
##
## The queue (examples/common/queue.nim) has an injectable bug: `dequeue`
## reads the head under the lock, releases it, yields the CPU, and removes the
## head later under a second lock (check-then-act). Two threads can then
## dequeue the same value.
##
## Exits with 0 only if the correct queue is linearizable in every round and
## the buggy queue is rejected in some round (its report is printed).
##
## Run: nim c -r --threads:on examples/queue_race.nim

when not compileOption("threads"):
  {.error: "this example needs --threads:on".}

import nimlinear
import ./common/queue

const rounds = 300

proc main(): int =
  for r in 1 .. rounds:
    let h = runRound(buggy = false)
    let v = check(h)
    if v.kind != vkLinearizable:
      echo "correct queue rejected in round ", r, ":\n", v.report
      echo "history saved to ", h.save("queue_race_failure.jsonl")
      return 1
  echo "correct queue: linearizable in all ", rounds, " rounds"

  for r in 1 .. rounds:
    let h = runRound(buggy = true)
    let v = check(h)
    case v.kind
    of vkNotLinearizable:
      echo "buggy queue: rejected in round ", r
      echo v.report
      echo "history saved to ", h.save("queue_race_failure.jsonl")
      return 0
    of vkInconclusive:
      echo "buggy queue: round ", r, " inconclusive:\n", v.report
      return 1
    of vkLinearizable: discard
  echo "buggy queue: bug not found in ", rounds, " rounds"
  1

quit main()
