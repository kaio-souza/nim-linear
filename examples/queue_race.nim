## M8 end-to-end example, written with `runRounds` (M17): a real lock-based
## bounded queue (examples/common/queue.nim), recorded from 3 threads and
## checked against the `BoundedQueue` model. The buggy `dequeue` reads the
## head under the lock, releases it, yields, and removes the head later
## (check-then-act), so two threads can dequeue the same value.
##
## Exits with 0 only if the correct queue passes every round and the buggy
## one is rejected (shrunk report printed). Run:
##   nim c -r --threads:on examples/queue_race.nim

when not compileOption("threads"):
  {.error: "this example needs --threads:on".}

import nimlinear
import ./common/queue

mode = (buggy: false, window: wSleep)
let good = runRounds(config(300), initState, QueueModel, setup, genOp, exec, teardown)
echo "correct queue: ", good.describe

mode = (buggy: true, window: wSleep)
let bad = runRounds(config(300), initState, QueueModel, setup, genOp, exec, teardown)
echo "buggy queue: ", bad.describe

quit(if good.passed and not bad.passed and bad.verdict.kind == vkNotLinearizable: 0 else: 1)
